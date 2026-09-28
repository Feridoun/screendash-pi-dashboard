# screendash

An always-on office wall display, driven entirely by email, running on a
**£30 Raspberry Pi 3B** in **100% native Flutter** — no browser, no X11, no
Wayland, no kiosk-mode Chromium. Flutter renders straight to DRM/KMS via
[flutter-pi](https://github.com/ardera/flutter-pi), inside 1 GB of RAM.

```
┌──────────────┬──────────────────┬─────────────┐
│              │ CLOCK + WEATHER  │ DIRECTORY   │
│  PHOTO       │ CALENDAR         │  grouped    │
│  STAGE       │  14-day grid     ├─────────────┤
│  (dominant)  │ MESSAGES         │ ROTA        │
├──────────────┴──────────────────┴─────────────┤
│                  MOTD banner                   │
└────────────────────────────────────────────────┘
```

Staff who will never open a terminal, a CMS, or an app **send an email**. The
subject line decides what happens. That's the whole interface.

---

## Why you might want to copy this

Most "office dashboard" builds end up as a browser in kiosk mode pointed at a
web app. That works until it doesn't: Chromium on a Pi eats the RAM budget,
leaks it over weeks, shows a crash page at head height in reception, and needs a
CMS nobody logs into. This project takes three positions instead.

**1. The display is a dumb, read-only poller.**
The device holds no credentials, parses no email, resizes no images, and has no
inbound port open. It does exactly one kind of thing, on a timer:
`GET a small JSON artifact`. Everything hard lives in the backend.

```
Backend (holds all secrets)  →  object storage  →  device polls over HTTPS
  /manifest.json    photo list + content hash
  /photos/*.jpg     pre-optimized images (<300 KB each)
  /events.json      next N meetings, already flattened
  /motd.json        banner text + optional accent colour
  /messages.json    a capped chat feed
  /directory.json   grouped phone/email directory
  /rota.json        who is in each day for the next fortnight
  /weather.json     today + tomorrow, already flattened to whole degrees
```

This is what makes the rest tractable. The Pi can sit on a network you cannot
reach, behind NAT you don't control, and still be updatable and debuggable —
because nothing ever has to *reach* it.

**2. Email is the CMS.**
There is no admin UI, no login, no training. A scheduled job polls one mailbox
every 5 minutes. The subject line is the command and the body is what it acts
on: attachments become photos, `notice` sets the banner, `message` posts to
the feed, `pinphoto` holds one image on screen, `delete` (as a reply) removes
what that email added. Handled mail gets a label, so the
inbox itself is the audit log. Senders are gated by email domain.

**3. Even software updates are a poll.**
`deploy.sh publish` builds an arm64 bundle and uploads it next to the photos.
A systemd timer on the device notices a new `version.json` within ~15 minutes,
verifies the SHA-256, swaps a symlink atomically, restarts — and **rolls itself
back if the new build doesn't stay up**. Shipping to a device you cannot SSH
into is one command, from anywhere.

## What it does

| | |
|---|---|
| **Photo stage** | Rotating slideshow with a hard memory ceiling. Tap to pin. |
| **Clock + weather** | Time, weekday and a two-day outlook from [Open-Meteo](https://open-meteo.com/) — no account, no key. Shows nothing rather than a stale forecast. |
| **Calendar** | Rolling 14-day grid, synced from Google Calendar. |
| **Directory** | Grouped contacts, built from a Google Sheet. Tap for full screen. |
| **Rota** | Who is in today and the next two working days, from a Google Sheet plus a leave Form. See below. |
| **Banner** | Message of the day; long text scrolls; tap to step back through recent notices. |
| **Messages** | A short chat feed written by `message` emails. |
| **Celebrations** | A brief animated flourish when new photos or a new notice land. |
| **Dimming** | Two-layer, time-based: a software scrim plus real panel power-off — for burn-in, and for not glowing at an empty office all night. |
| **Admin panel** | Hidden recovery console — long-press the top-left corner. |

That last one is worth calling out. When a wall-mounted board lands on a network
you can't SSH into, the app itself becomes the way in: it can already reach the
backend and report its own network state. The panel shows live IPs, gateway,
SSID, and whether SSH / Tailscale / sudo / the clock are healthy; it can join a
Tailscale tailnet, switch Wi-Fi networks, and stop the kiosk to free the console.
Every privileged action goes through a narrowly-scoped `sudo -n` rule, one per
caller — see [deploy/dashboard-admin.sudoers](deploy/dashboard-admin.sudoers).

## What it costs

- **Raspberry Pi 3B** (or better) — an old one is fine; that's rather the point.
- **Any HDMI panel.** A cheap TV works.
- **Backend: £0.** Cloudflare Workers + R2 stay inside the free tier at this
  volume, and it runs on the free `*.workers.dev` URL — **no domain required**.
- **A Gmail account** for the display to read.

## Try it in five minutes, no hardware

The repo ships fake backend artifacts, so you can run the real UI on your
laptop before buying anything:

```bash
python sample_backend/gen_events.py               # date fixtures into today's window
cd sample_backend && python -m http.server 8080   # serve the fake artifacts
flutter run -d linux                              # or -d macos / -d windows
```

The default backend URL is `http://localhost:8080`, so that just works. The
desktop embedding matches the flutter-pi desktop path closely enough for real
development; the `vcgencmd` panel-power call fails harmlessly off-Pi while the
software scrim still dims.

While photos cycle, open Flutter DevTools and watch
`ImageCache.currentSizeBytes` **plateau**. That is the whole memory game on a
1 GB board, and it is the first thing to break if you extend the photo path.

## Then build the real thing

1. **Backend** — [docs/cloudflare-setup.md](docs/cloudflare-setup.md) walks the
   Worker, R2 bucket, Google OAuth (Calendar + Gmail + Sheets) and the cron
   triggers end to end. Set `ALLOWED_SENDER_DOMAINS` in
   [worker/wrangler.toml](worker/wrangler.toml) to your organisation's domain.
2. **Pi** — flash Pi OS Lite, apply
   [deploy/config.txt.snippet](deploy/config.txt.snippet), then:
   ```bash
   PI_HOST=pi@screendash.local \
   BACKEND_URL=https://screendash.<your-subdomain>.workers.dev \
   DEVICE_TOKEN=$(openssl rand -hex 32) \
     ./deploy/deploy.sh provision
   ```
   This installs the bundle, systemd units, udev rule, update timer, and the GL
   runtime libraries Pi OS Lite doesn't ship. It also disables `getty@tty1`,
   which otherwise silently prevents the app from ever starting.

   `DEVICE_TOKEN` is the bearer token the updater sends to download a bundle.
   The Worker serves `/bundles/*` to nobody else, because a bundle can carry
   build-time secrets. Set the **same value** as a Worker secret
   (`npx wrangler secret put DEVICE_TOKEN`) or the board never self-updates.
3. **Every update after that** needs no access to the device:
   ```bash
   VERSION=1.0.1 BACKEND_URL=... PUBLISH_CMD='...' ./deploy/deploy.sh publish
   ```

`BACKEND_URL` has **no default** anywhere, on purpose: the app and the on-device
updater must poll the same origin, and a plausible-but-wrong default is the
easiest way to break that silently.

## How staff drive it

One mailbox. The **subject line is the command** — `notice`, `message`,
`pinphoto`, `delete` — and the **body is what that command acts on**:

| To do this | Send an email that… |
|---|---|
| Add photos | has image attachments, and any subject that isn't a command word |
| Update the banner | has subject `notice`, banner text in the body |
| Set a banner colour | includes `#accent=#E8A33D` on a line in the body |
| Clear the banner | has subject `notice`, empty body |
| Post to the message feed | has subject `message`, the message in the body |
| Hold a photo on screen | has subject `pinphoto` with the photo attached |
| Pin a photo already up | has subject `pinphoto`, part of its filename in the body |
| Resume rotation | has subject `pinphoto`, no attachment, empty body |
| Remove photos | is a **reply** to the email that added them, subject `delete` |
| Remove one photo | has subject `delete`, part of its filename in the body |

A trailing colon is optional, and the older one-line form — `notice: Coffee
machine is fixed` — still works: text after the colon wins over the body, so no
signature block can overwrite a subject somebody typed deliberately.

A one-page version for non-technical staff, with none of the above plumbing, is
in [docs/user-guide.md](docs/user-guide.md) — hand it out as-is.

Deleted photos move to a `removed/` prefix rather than being destroyed, because
a `delete` reply on the wrong thread is a matter of when, not if.

### The rota

The rota card under the directory shows who is in today and the next two working
days, from a Google Sheet with two tabs. `Team` holds each person's usual weekdays
and hours, edited when the rotation changes; a weekday cell may hold a word
instead of hours (`WFH`, `Clinic`, `Study`) for a regular day off the ward.
`Leave` holds the exceptions — annual leave, study leave, sick, a meeting window,
working from home — one row each, usually submitted from a phone through a
Google Form whose name list the Worker keeps in step with the `Team` tab. The
Worker resolves the two into a fortnight of per-person statuses (`in`,
`partial`, `away`, `off`) and publishes that, so the board does no rota
arithmetic. A `Notify_list` tab names who gets an email for each booking.
[worker/create-rota-sheet.mjs](worker/create-rota-sheet.mjs) builds the Sheet
and Form for you; setup is in
[docs/cloudflare-setup.md](docs/cloudflare-setup.md#10b-set-up-the-rota-sheet-and-form).

## The traps, written down

The docs are unusually blunt about failure modes, because most of them cost real
time to find:

- [docs/dashboard-plan.md](docs/dashboard-plan.md) — the architecture and *why
  each choice is shaped that way*, including what the obvious alternative breaks.
- [docs/updating.md](docs/updating.md) — the self-update mechanism, rollback
  behaviour, and tuning knobs.
- [docs/captive-portal.md](docs/captive-portal.md) — the ugliest one. A guest
  Wi-Fi captive portal does not announce itself: HTTPS just fails, the
  controllers fail soft by design, and the board keeps showing **yesterday's
  photos as if nothing were wrong**. Ships with `deploy/portal-probe.sh`, which
  *measures* a portal (`snapshot`, `soak`, `report`, `request`) and never logs in
  to anything, so you can appraise a network before deciding what to automate.
- [docs/remote-desktop.md](docs/remote-desktop.md) — an optional browser-based
  admin desktop over Guacamole + Tailscale, and why you still **cannot see the
  kiosk itself** (the limitation is in the hardware).
- [docs/tailnet-security.md](docs/tailnet-security.md) — a board on a public
  wall is a board someone can take, and physical access to a Pi is root.
  Tailscale's default policy lets every node reach every other one;
  [deploy/tailscale-acl.json](deploy/tailscale-acl.json) makes the kiosk a
  destination only, and the doc has the rest of the threat model.

Two more worth knowing before you start:

- **No RTC on a Pi 3B.** After a power cut it boots believing it is 1970, and
  every TLS handshake fails — so the display goes stale for reasons that look
  nothing like a clock problem. Confirm outbound NTP is allowed, or add a ~£5
  DS3231.
- **Tailscale auth keys baked in with `--dart-define` end up inside the
  published bundle** — which is why bundle downloads are gated. Use tagged
  (`tag:kiosk`), ephemeral-off, reusable-off, short-expiry keys, and revoke them
  once the board has joined.
- **`/admin/*` needs a token.** The manual triggers (poll Gmail, rebuild the
  manifest, sync a feed) want `Authorization: Bearer $ADMIN_TOKEN`, set as a
  Worker secret. The board's own refresh button may run the three syncs
  anonymously, at most once a minute each.

## Layout

```
lib/
  config/app_config.dart      Backend URL, poll cadences, dim schedule, cache caps
  models/                     Immutable data classes + the 14-day grid maths
  services/                   HTTP polling (ETag conditional GETs + jitter),
                              network/Tailscale/Wi-Fi ops, power, storage
  controllers/                One poller per artifact; shared timer lifecycle
                              and a fail-soft convention in polling_controller
  ui/                         Kiosk layout, directory screen, admin panel, widgets

worker/                       Cloudflare backend (see worker/README.md)
  src/gmail.js                Cron: poll Gmail, decode attachments, label as done
  src/intake.js               Sender gate + subject-line routing
  src/photos.js               Resize, write to R2, rebuild manifest
  src/calendar.js             Cron: Google Calendar → events.json
  src/directory.js            Cron: Google Sheet → directory.json
  src/rota.js                 Cron: rota Sheet (pattern + leave) → rota.json
  src/rota_alerts.js          Emails the notify list about new bookings
  src/forms.js                Keeps the leave Form's names in step with the Sheet
  src/sheets.js               Shared Sheets fetch + header-name column matching
  src/weather.js              Cron: Open-Meteo → weather.json (no key)
  src/admin.js                Token gate for the manual /admin/* triggers
  src/serve.js                Serves the artifacts, with ETags; gates /bundles/*
  create-rota-sheet.mjs       One-off: build the rota Sheet and its leave Form

deploy/                       deploy.sh, on-device update.sh, systemd units,
                              narrow sudoers grants, captive-portal probe
sample_backend/               Fake artifacts for host development
docs/                         Architecture, runbooks, failure modes
```

Everything tunable is in one file:
[lib/config/app_config.dart](lib/config/app_config.dart).

```bash
flutter analyze   # clean
flutter test      # model parsing, grid maths, rota, weather, widgets
```

## Adapting it

The email pipeline is the most replaceable part. `intake.js` is the only place
that knows about subject-line grammar, and everything downstream just writes a
JSON artifact — so a Slack bot, a web form, or a watched folder can be swapped in
without the device knowing anything changed. Likewise `deploy.sh` takes a
`PUBLISH_CMD` template (`{src}`, `{dst}`), so R2, S3, or plain rsync-to-nginx all
work as the origin.

What is *not* easily replaceable is the memory discipline. On 1 GB, the photo
path is the constraint that shapes everything else: pre-resize on the backend,
cap the on-disk cache, cap the image cache, and never decode a full-resolution
image on the device. If you take one idea from this repo, take that one.

## Licence

MIT — see [LICENSE](LICENSE). No warranty; this drives a screen in an office,
not anything that matters.
