# Updating the dashboard

How new app versions reach a Pi that lives on an office network you can't reach.

## Shipping an update

Once the board is provisioned and hanging on a wall somewhere else, **you never touch it
again.** One command from the repo root:

```bash
VERSION=1.4.1 \
BACKEND_URL=https://screendash.<your-subdomain>.workers.dev \
PUBLISH_CMD='npx wrangler@4 r2 object put screendash/{dst} --file {src} --remote --config worker/wrangler.toml' \
  ./deploy/deploy.sh publish
```

It builds the arm64 bundle, packs it, hashes it, and uploads `bundles/1.4.1.tar.gz` then
`version.json` to R2. Every device picks it up **within ~15 minutes** on its own. No SSH,
no VPN, no knowing what network the Pi is on. Then watch the origin, not the device:

```bash
curl -s https://screendash.<your-subdomain>.workers.dev/version.json
```

Three things to get right, all of which bite silently:

- **`BACKEND_URL` must match what the app was built with.** It is compiled into `app.so`
  via `--dart-define` *and* written to `/etc/default/dashboard-update` at provision time.
  If they diverge, the app and its own updater poll different origins.
- **`VERSION` must be new.** The updater compares it against the `current` symlink and
  no-ops when they match, so re-publishing the same version ships nothing.
- **Wrangler v3 and v4 differ.** v4 needs `--remote` or it writes to a *local* simulator
  and silently uploads nothing real; v3 rejects the flag outright. Pin `wrangler@4` rather
  than relying on whichever version `npx` resolves.

To roll back, re-publish an older `VERSION` whose tarball is still in `bundles/`. Devices
see a "new" target and move to it the same way — no device access needed.

## Why it's pull-based

The dev station is at home; the Pi is in an office on public WiFi that almost certainly
does client isolation and NAT with no inbound ports, so **nothing you do from home can
open a connection to the Pi.** Any push-based deploy works on a LAN and breaks the moment
the device is somewhere else. So updates invert the direction, exactly like every other
feature here: the app already GETs `manifest.json`, `events.json` and friends on a timer,
and updating the app is the same move applied to the bundle itself.

## The pieces

| File | Runs where | Job |
|------|-----------|-----|
| [../deploy/update.sh](../deploy/update.sh) | on the Pi | Poll `version.json`, verify, swap, restart, roll back |
| [../deploy/dashboard-update.timer](../deploy/dashboard-update.timer) | on the Pi | Fire the updater ~every 15 min (+ jitter) |
| [../deploy/dashboard-update.service](../deploy/dashboard-update.service) | on the Pi | oneshot that runs `update.sh` |
| [../deploy/dashboard-update.sudoers](../deploy/dashboard-update.sudoers) | on the Pi | Let the timer restart the app without a password |
| [../deploy/dashboard.service](../deploy/dashboard.service) | on the Pi | Runs the `current` symlink, not a fixed path |
| [../deploy/deploy.sh](../deploy/deploy.sh) | on your dev box | `provision` (once, SSH) / `publish` (routine, no Pi access) |

```
/home/pi/dashboard/
  current  -> versions/1.4.0     what dashboard.service actually runs
  previous -> versions/1.3.0     rollback target (last version known to boot)
  versions/1.4.0, 1.3.0, …       unpacked bundles (last KEEP_VERSIONS=3 retained)
  update.sh                      the self-updater
  state                          last version that started cleanly
```

`current` being a **symlink** is the whole trick: an update is an atomic symlink swap plus
a restart, and a rollback is swapping it back.

## Provision — once, needs SSH

Run while the Pi is on a network you can reach (home bench, or over Tailscale). Prep the
Pi per [../deploy/config.txt.snippet](../deploy/config.txt.snippet) first, then:

```bash
PI_HOST=pi@screendash.local \
BACKEND_URL=https://screendash.<your-subdomain>.workers.dev \nDEVICE_TOKEN=$(openssl rand -hex 32) \n  ./deploy/deploy.sh provision
```

Installs the first bundle, both systemd units, the udev rule, the scoped sudoers files and
`jq`; enables the app and the update timer; writes `/etc/default/dashboard-update`
(`0600 root:root` — it now holds `DEVICE_TOKEN`). It also does two things that are easy to
miss by hand and not optional:

- **Installs the runtime libraries `flutter-pi` links against.** Pi OS Lite ships no GL
  userspace at all — eleven packages were missing on a fresh install. The shipped
  `flutter-pi` is built with Vulkan and GStreamer enabled, so `libvulkan1` and the
  gstreamer runtimes are required even though this app uses neither.
- **Disables `getty@tty1`.** `dashboard.service` claims `/dev/tty1`; if `agetty` still owns
  it, systemd blocks acquiring the TTY and *never execs*. See Gotchas.

There is no `flutter-pi` to install: `flutterpi_tool` ships a prebuilt aarch64 binary and
`libflutter_engine.so` **inside the bundle**, so the runtime version-swaps and rolls back
together with the app.

## Publish — what it actually writes

`screendash` is the R2 bucket from [../worker/wrangler.toml](../worker/wrangler.toml). The
Worker serves R2 keys straight off the request path
([../worker/src/serve.js](../worker/src/serve.js)), so `{dst}` *is* the key — no path
translation to reason about. `version.json` is in that file's allow-list and the `bundles/`
prefix is permitted, which is exactly what `publish` writes:

```
bundles/<version>.tar.gz
version.json    { "version": "...", "bundle_url": "...", "sha256": "..." }
```

The bundle goes up **before** `version.json` on purpose: if the pointer went first, a Pi
polling in the gap would chase a bundle that doesn't exist yet.

`version.json` is public; **`bundles/` is not**. The bundle is the one artifact that can
carry a build-time secret — `TAILSCALE_AUTHKEY` bakes straight into it — and serving it
anonymously made the whole chain public: fetch `version.json`, follow `bundle_url`, untar,
grep. It now needs `Authorization: Bearer $DEVICE_TOKEN`, matching the Worker secret of the
same name. The Worker fails **closed** if that secret is missing (503, logged), so bundle
downloads pause rather than silently going public again. Rollout order and verification:
[tailnet-security.md](tailnet-security.md).

## What the on-device updater guarantees

The device is unattended — nobody can plug in a keyboard when it goes wrong — so the
updater is built so a bad artifact can't brick it:

1. **Fail-soft on a dead backend.** Can't fetch `version.json`? Leave the running version
   alone and exit 0.
2. **No-op when already current.** Compares `version.json` against the `current` symlink.
3. **Verify before touching anything running.** Download to a temp dir, check SHA-256, and
   sanity-check the unpacked bundle (must contain `kernel_blob.bin` or `app.so`). A
   mismatch is refused before the live version is touched.
4. **Atomic swap.** Stage into `versions/<version>/`, record the rollback target in
   `previous`, then swap `current` via `ln -sfn tmp && mv -Tf` — a bare `ln -sfn` over a
   symlink-to-directory nests inside it instead of replacing it.
5. **Verify it stays up.** After restart, watch for `SETTLE_SECONDS`. Reject if the service
   goes inactive **or** if `NRestarts` climbs during the window (`Restart=always` masks a
   crash loop as "active"). `NRestarts` is compared against a baseline taken just before
   the restart — it's cumulative, so an absolute threshold would falsely reject updates on
   a long-lived device.
6. **Auto-rollback.** On rejection, swap `current` back to `previous`, restart, and delete
   the bad version so the next tick doesn't retry it.
7. **Resume an interrupted swap.** Every run first compares `state` (last version observed
   healthy) against `current` (what actually runs). They diverge only when a previous run
   swapped a version in and then died before finishing its settle check — a power cut, a
   shutdown from the config modal, an OOM kill, `systemctl stop`. When they disagree the
   updater re-runs the health check on whatever is live: records it if healthy, rolls back
   if not.

Step 7 matters more than it looks. Without it that window was **permanent** and it defeated
step 6 entirely: step 2 compares the wanted version against `current`, so once a swap had
happened the next tick reported *"already on X; nothing to do"* and the rollback never got
a chance to run — an interrupted bad bundle stayed live and unverified forever. Found in
practice by pressing the modal's shutdown button during a settle window. The resume check
**observes without restarting** (`RESUME_WATCH_SECONDS`), because the version it finds is
usually fine and a wall display shouldn't blink to prove it.

## Tuning knobs

Environment overrides read by [../deploy/update.sh](../deploy/update.sh):

| Var | Default | Meaning |
|-----|---------|---------|
| `BACKEND_URL` | *(required)* | Origin to poll (set via `/etc/default/dashboard-update` by `provision`) |
| `ROOT` | `/home/pi/dashboard` | On-device install root |
| `SETTLE_SECONDS` | `45` | How long the new version must stay up to be accepted |
| `RESUME_WATCH_SECONDS` | `20` | How long to watch an already-running version when finishing an interrupted swap |
| `KEEP_VERSIONS` | `3` | Unpacked bundles to retain before pruning |

Timer cadence lives in [../deploy/dashboard-update.timer](../deploy/dashboard-update.timer)
(`OnUnitActiveSec`, `RandomizedDelaySec`).

`PUBLISH_CMD` is a template for your storage CLI where `{src}` is the local file and
`{dst}` is the path under the origin root — the wrangler form above, or e.g.
`rclone copyto {src} r2:screendash/{dst}`. Unset, the artifacts are left in
`./build/publish/` for manual upload, which is a perfectly good fallback: drag the two
files into the R2 bucket in the Cloudflare dashboard, **bundle first**.

`BUNDLE_DIR` (in [../deploy/deploy.sh](../deploy/deploy.sh)) must match the `--cpu`/`--arch`
pair — `pi3` + `arm64` produces `build/flutter-pi/pi3-64`. Change one and you must change
the other, or `publish` packs a stale bundle or fails its `app.so` check.

## Diagnostics

```bash
ssh pi@screendash.local journalctl -u dashboard -f          # the app
ssh pi@screendash.local journalctl -u dashboard-update -f   # the updater
ssh pi@screendash.local systemctl list-timers dashboard-update.timer
cat /home/pi/dashboard/state                      # last version OBSERVED HEALTHY
readlink -f /home/pi/dashboard/current            # what is actually running
```

If those last two disagree, an update was interrupted mid-settle. That's self-healing —
the next tick re-checks and either records it or rolls back — but seeing it means something
killed `update.sh` partway, which is worth understanding.

The self-updater is **not** a recovery tool: it can't help with a wrong `BACKEND_URL`, a
dead WiFi link, or a captive-portal network. Those need a shell — see the Tailscale and
admin-panel sections in the [README](../README.md#getting-a-shell-on-a-remote-pi).

## Gotchas

- **`publish` works fine from Windows/Git Bash** — but only because this project carries no
  package with native-asset build hooks. Adding one back (`path_provider` was the original
  offender, via `path_provider_foundation` → `objective_c`) re-enables Flutter's code-assets
  pipeline, which demands a Linux CMake cache `flutterpi_tool` never generates. The build
  then dies with *"Could not read compiler configurations for build hooks"* and no flag
  fixes it. See [../lib/services/app_directories.dart](../lib/services/app_directories.dart)
  for the replacement that avoids it. If you must add such a dependency, build in WSL or CI.
- **NTFS has no execute bit.** A bundle tarred on Windows arrives mode 644, so the bundled
  `flutter-pi` won't run. `deploy.sh` and `update.sh` both `chmod +x` after unpacking — if
  you rework either, keep that, or the unit dies with EACCES *and the updater rolls back*,
  making a perfectly good build look faulty.
- **`getty@tty1` must stay disabled.** If anything re-enables it, `dashboard.service` reports
  `active (running)` with 0 restarts, logs nothing, and shows a MainPID whose
  `/proc/<pid>/exe` still points at `systemd` — because it blocked before exec. There is no
  error message anywhere. Diagnose with `fuser -v /dev/tty1`. (Consequence: no local console
  on tty1; use Ctrl+Alt+F2 or SSH.)
- **Don't pin a display mode.** `hdmi_group`/`hdmi_mode` are legacy firmware keys, inert
  under full KMS; mode comes from the panel's EDID. The bench Waveshare reports 1600x720 and
  a wall TV reports something else, so a hardcoded mode black-screens one of them.
- **Captive-portal WiFi breaks everything here.** The Pi silently loses connectivity and no
  update or photo lands. Confirm the network is open or PSK first, or work through
  [captive-portal.md](captive-portal.md).
- **A mismatched `DEVICE_TOKEN` looks exactly like a missing bundle.** The Worker answers
  `404` to an unauthorised bundle request on purpose — an anonymous caller shouldn't be able
  to confirm which versions exist — so `journalctl -u dashboard-update` shows
  `download failed` with nothing to distinguish "wrong token" from "never uploaded". Check
  `wrangler tail` (a `503` line means the Worker secret is missing entirely) and confirm
  `sudo grep DEVICE_TOKEN /etc/default/dashboard-update` matches it.
- **`wrangler tail` says `Ok` for a 404.** That label reports whether the Worker *executed*
  without throwing, not the HTTP status it returned. A gated bundle request that correctly
  answers `404` still logs as `Ok`, so a tail full of `GET /bundles/... - Ok` is NOT evidence
  that a device downloaded anything. The only trustworthy confirmation is on the device:
  `journalctl -u dashboard-update`, plus `cat state` and `readlink -f current`.
- **`publish` does not update `update.sh` on the device.** Only `provision` copies it, so a
  board can run a months-old updater indefinitely while `deploy.sh publish` succeeds every
  time. This bites hardest right after changing the updater itself: on 2026-09-03 the device
  still had the pre-`DEVICE_TOKEN` script from initial provisioning, so it never sent an
  `Authorization` header and *every* bundle download 404'd for hours while the origin looked
  perfectly healthy. If you change `deploy/update.sh`, push it:
  `scp deploy/update.sh $PI_HOST:/tmp/ && ssh $PI_HOST 'install -m0755 /tmp/update.sh /home/pi/dashboard/update.sh'`
  Confirm with `md5sum` on both ends.
