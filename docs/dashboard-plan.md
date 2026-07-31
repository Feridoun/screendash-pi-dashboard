# Architecture — ambient office dashboard on a Pi 3B

Why the system is shaped the way it is. The build is done; this is the design record
and the set of traps worth not re-discovering. Operational runbooks live in
[updating.md](updating.md), [cloudflare-setup.md](cloudflare-setup.md) and
[captive-portal.md](captive-portal.md).

| | |
|---|---|
| **Board** | Raspberry Pi 3B v1.2 · 1 GB · 2.5 A supply |
| **OS** | Raspberry Pi OS Lite 64-bit |
| **Runtime** | flutter-pi (bare DRM/KMS — no X11, Wayland or WebView) |
| **Backend** | Cloudflare Worker + R2, on the free `*.workers.dev` URL (no domain) |
| **Input** | USB mouse via kernel `evdev` (no config needed) |

## The one decision everything else follows from

**The Pi is a dumb terminal for pre-computed state.** The backend produces a small
artifact at a stable URL; the Pi polls it on a timer. The device is stateless,
crash-tolerant (a reboot loses nothing), and holds **no secrets** — every credential
is a Worker secret, so rotating Google auth is a `wrangler secret put`, never a
re-flash.

```
/manifest.json    photo list + content hash
/photos/*.jpg     optimized images, <300 KB each
/events.json      events covering the next 14 days
/motd.json        banner text + optional accent color
/directory.json   grouped phone/email directory
```

All five are read anonymously over HTTPS. Adding a feature means adding an artifact,
not adding a capability to the device.

## Backend flow

One Gmail address handles photos *and* the banner; the **subject line** routes. Every
message is gated on sender domain first.

```
staff@yourteam.dev  --email-->  your-dashboard@gmail.com
                                   |
              Worker cron (*/5) polls the Gmail API
                                   |
   1. SELECT: messages without the "screendash-done" label, not spam/trash
   2. GATE:   skip unless From ends in "@yourteam.dev"
   3. ROUTE on subject: notice: / pinphoto: / delete: / else photos
   4. LABEL "screendash-done" — only after success
```

Cloudflare Email Routing would need a domain we don't own, so the Worker **pulls**
mail rather than receiving pushed mail. The cost is latency (~5 min instead of
instant) and a sender gate resting on the `From` header alone; Gmail's own
spam/DMARC filtering does the upstream work and the query skips `in:spam`. In
exchange the whole backend needs no domain and no DNS.

**Idempotency** comes from labelling *after* the message is fully applied, so a crash
mid-batch retries on the next tick rather than dropping mail silently. A label rather
than read/unread means a human opening the email in Gmail doesn't break the pipeline;
removing the label re-processes the message.

Photos are iterated per attachment (several per email), downscaled to 1920×1080,
re-encoded to progressive JPEG ~80% with EXIF stripped, and named
`<date>-<sender-slug>-<n>.jpg`. Cloudflare Image Resizing needs a zone, so with no
domain the Worker stores originals and logs a warning — a storage-size concern only,
since the app decodes with `cacheWidth`. Each write regenerates `manifest.json` with
a fresh `hash`, which is what the Pi diffs.

`directory.json` has no email flow: a scheduled job reads one flat tab of a Google
Sheet (`Group | Name | Role | Phone | Email`, matched by header name) on the same
15-minute tick as the calendar. An empty result is never published and an unchanged
result is never rewritten, so a cleared sheet leaves the last good directory on the
wall and idle syncs don't churn the R2 ETag.

Subject-line semantics and the full setup sequence are in
[cloudflare-setup.md](cloudflare-setup.md).

### Artifact contracts

```json
// manifest.json
{ "hash": "a1b2c3d4", "generated": "2026-07-23T09:00:00Z",
  "photos": [ { "file": "2026-07-21-jsmith-1.jpg", "w": 1920, "h": 1080, "bytes": 214003 } ] }

// motd.json
{ "text": "Coffee machine is fixed 🎉", "accent": "#E8A33D" }

// events.json
{ "updated": "2026-07-23T09:00:00Z", "range": { "from": "2026-07-23", "to": "2026-08-05" },
  "events": [ { "title": "Daily Standup", "start": "2026-07-23T13:30:00Z",
                "end": "2026-07-23T13:45:00Z", "room": "Zoom" } ] }

// directory.json
{ "updated": "2026-07-23T09:00:00Z",
  "groups": [ { "name": "Engineering", "people": [
    { "name": "Priya Shah", "role": "Eng Lead", "phone": "x4021", "email": "priya@yourteam.dev" } ] } ] }
```

## OS configuration and its traps

A current Raspberry Pi OS image already sets `dtoverlay=vc4-kms-v3d` and
`disable_overscan=1` — check before appending or you duplicate keys. What's missing:

```ini
gpu_mem=64        # V3D allocates from CMA/system memory; a big split just steals RAM
disable_splash=1
boot_delay=0
```

**Don't pin the display mode.** `hdmi_group`/`hdmi_mode` are legacy firmware keys and
are **silently inert** under full KMS (the stock image also sets
`disable_fw_kms_setup=1`). KMS reads the panel's EDID, which is what you want for a
board that moves between displays. If a panel genuinely advertises a bad EDID, pin it
on the kernel command line instead — `video=HDMI-A-1:1920x1080M@60` in
`/boot/firmware/cmdline.txt` — and confirm with `modetest -c`.

**Keep `avahi-daemon`.** `deploy.sh` defaults to `PI_HOST=pi@screendash.local` and
that `.local` name is mDNS. Disabling it saves a few MB and costs you the ability to
find the board. Safe to disable: `bluetooth`, `triggerhappy`, `ModemManager`, `cups`.
A 512 MB swapfile is cheap insurance for a board that runs for months.

**Prefer the RJ45 port** over Wi-Fi for a wall-mounted board — it removes the single
most common cause of a display going stale, and sidesteps
[captive portals](captive-portal.md) entirely.

`dashboard.service` claims `/dev/tty1`, so `getty@tty1` must stay disabled — see the
deceptive failure mode in [updating.md](updating.md#gotchas).

### Display power

Two layers, because neither alone is right: an animated Flutter scrim for smooth
daytime dimming (no system calls, survives any panel), and real hardware control for
the overnight blank, which actually saves power and eliminates burn-in. Soft-dim by
day, hard-blank by night. Hardware control is `vcgencmd display_power 0/1` on HDMI,
or `/sys/class/backlight/*/brightness` on a DSI panel — the latter needs
[90-backlight.rules](../deploy/90-backlight.rules) plus `usermod -aG video pi`.

Drive the schedule from a periodic `Timer`, not `AnimationController` wall-clock
maths, so it survives DST and long uptimes.

## App architecture

Lightweight `ChangeNotifier` providers. Independent timers feed immutable state; a
shared `PollingController` base owns the timer lifecycle and the fail-soft rule — **a
failed poll keeps the last-good value**, so the wall never shows a spinner or a stack
trace. Timers jitter and honour ETags so N devices don't thundering-herd the backend.

> **The #1 pitfall: a 1920×1080 image decodes to ~8 MB regardless of JPEG size.**
> Cycling 20 photos on the default cache pins 100+ MB and grows with the manifest. The
> 3B's 1 GB makes that survivable rather than fatal — it is still unbounded, so the
> cache is capped explicitly (`maximumSize`, `maximumSizeBytes` in `main()`), images
> decode with `cacheWidth`, the outgoing image is `evict()`ed every transition, only
> the *next* image is precached, and files dropped from the manifest are deleted.
> Confirm `ImageCache.currentSizeBytes` **plateaus** in DevTools — that's the gate.

### Layout

Three columns across a pixel-stable 1080p layout, banner spanning the bottom. It does
not reflow.

```
+------------------+---------------------+----------------+
|                  |  CALENDAR (14-day)  |   DIRECTORY    |
|   PHOTO STAGE    |  Mon Tue Wed Thu…   |   Engineering  |
|   (dominant,     |   [rolling grid,    |     Priya Shah |
|    cross-fades)  |    today highlit]   |   Operations   |
|                  |  AGENDA             |     Front Desk |
+------------------+---------------------+----------------+
|                        MOTD banner                       |
+----------------------------------------------------------+
```

Readability at 3–5 m sets the type scale: ≥28–32 px for anything read across the
room, `FittedBox` so long strings scale instead of wrapping, and a ~4–5% safe-area
inset for overscan and glare. A discreet corner clock and a connectivity dot report
poll health without drawing attention.

### The calendar grid

14 day-cells starting at today, under a Mon-first weekday header. Because the window
doesn't start on a Monday, the first row is padded with blanks from the preceding
Monday up to today, and trailing blanks fill the last row. Each cell shows the day
number, `today` emphasized with an accent ring, and a marker or count when that day
has events. It is deliberately read-only — no scrolling, no month navigation. It's
ambient, not interactive.

The agenda beneath flattens and sorts the same `events.json` the grid buckets by day:
the "what's actually next" companion to the grid's "shape of the fortnight".

### Directory

A compact grouped column on the dashboard; clicking it opens a scrollable full-screen
version with job titles. Same models and widgets, more room to breathe.

## Build and deploy

```bash
dart pub global activate flutterpi_tool

# --cpu=pi3 = Cortex-A53-tuned engine. Output: build/flutter-pi/pi3-64/
# (app.so + prebuilt aarch64 flutter-pi + libflutter_engine.so), NOT flutter_assets.
flutterpi_tool build --arch=arm64 --cpu=pi3 --release \
  --dart-define=BACKEND_BASE_URL=https://screendash.<your-subdomain>.workers.dev
```

`deploy.sh` wraps this. Because the engine ships *inside* the bundle, the runtime
version-swaps and rolls back together with the app. Log to journald, not files, so
the SD card doesn't fill. Full mechanism: [updating.md](updating.md).
