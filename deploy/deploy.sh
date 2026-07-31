#!/usr/bin/env bash
# Build the arm64 release bundle and publish it for the Pi to pick up.
# See docs/dashboard-plan.md, Phase 4 (milestones M5-M7).
#
# Two modes, because the Pi lives on an office network we cannot reach:
#
#   ./deploy/deploy.sh provision    One-time (or after changing unit files).
#                                   Needs SSH -- run it while the Pi is on a
#                                   network you can reach, or over Tailscale.
#
#   ./deploy/deploy.sh publish      The routine path. Builds, packs, and uploads
#                                   to the backend origin. Needs NO access to the
#                                   Pi; the on-device timer polls version.json
#                                   and updates itself within ~15 minutes.
#
# Usage:
#   PI_HOST=pi@screendash.local BACKEND_URL=https://screendash.<your-subdomain>.workers.dev ./deploy/deploy.sh provision
#   VERSION=1.4.0 ./deploy/deploy.sh publish
#
# Optional during provision: set VNC_PASSWORD to also install the admin remote
# desktop (a second X session on :1, reachable over the tailnet only). Omit it
# and nothing VNC-related is installed. See docs/remote-desktop.md.
#   VNC_PASSWORD='8charpw' ./deploy/deploy.sh provision
set -euo pipefail

MODE="${1:-publish}"
# Hostname is set by custom.toml at first boot; .local resolves over mDNS.
# (The board is a Pi 3B now — the old zero2w default named hardware we replaced.)
PI_HOST="${PI_HOST:-pi@screendash.local}"
REMOTE_DIR="${REMOTE_DIR:-/home/pi/dashboard}"
# No default on purpose: the app and the on-device updater must poll the SAME
# origin, and a wrong-but-plausible default is the easiest way to break that
# silently. Set it explicitly, e.g. https://screendash.<you>.workers.dev
BACKEND_URL="${BACKEND_URL:?set BACKEND_URL to your backend origin}"

# Where flutterpi_tool 0.12.x puts a release bundle. The directory name encodes
# the --cpu/--arch pair: pi3 + arm64 -> "pi3-64" (a generic arm64 build would be
# "aarch64-generic"). This is NOT ./build/flutter_assets -- that was the old
# layout, and a release bundle has app.so, not kernel_blob.bin.
BUNDLE_DIR="${BUNDLE_DIR:-./build/flutter-pi/pi3-64}"

# How to push files to the backend origin. Override for your storage provider,
# e.g.  PUBLISH_CMD='aws s3 cp {src} s3://dash-bucket/{dst} --acl public-read'
# or    PUBLISH_CMD='rclone copyto {src} r2:dash/{dst}'
# {src} = local file, {dst} = path relative to the origin root.
PUBLISH_CMD="${PUBLISH_CMD:-}"

publish_file() {
  local src="$1" dst="$2"
  if [ -z "$PUBLISH_CMD" ]; then
    echo "!! PUBLISH_CMD is not set -- cannot upload $dst" >&2
    echo "   Set it to your storage CLI, e.g.:" >&2
    echo "   PUBLISH_CMD='aws s3 cp {src} s3://dash-bucket/{dst}'" >&2
    echo "   Built artifacts are left in ./build/publish/ for manual upload." >&2
    return 1
  fi
  local cmd="${PUBLISH_CMD//\{src\}/$src}"
  cmd="${cmd//\{dst\}/$dst}"
  echo ">> publishing $dst"
  eval "$cmd"
}

build_bundle() {
  echo ">> Ensuring flutterpi_tool is installed..."
  dart pub global activate flutterpi_tool >/dev/null

  # `dart pub global activate` installs a bare shim on Linux/macOS but a .bat on
  # Windows, and Git Bash does not fall back to the .bat for a bare name. Resolve
  # it explicitly so this script works from Git Bash as well as a Unix shell.
  local fpt=""
  for c in flutterpi_tool flutterpi_tool.bat; do
    if command -v "$c" >/dev/null 2>&1; then fpt="$c"; break; fi
  done
  [ -n "$fpt" ] || {
    echo "!! flutterpi_tool not on PATH after activation." >&2
    echo "   Expected it in the pub cache bin dir, e.g. ~/.pub-cache/bin" >&2
    echo "   (Windows: %LOCALAPPDATA%\\Pub\\Cache\\bin)." >&2
    exit 1
  }

  # Optionally bake a single-use Tailscale auth key into the bundle so the hidden
  # admin panel can bring a stranded board onto the tailnet without anyone typing
  # a 60-char key on the touchscreen. SECURITY: this key ships inside the bundle
  # on your storage origin -- use an ephemeral-OFF, reusable-OFF, short-expiry key
  # and REVOKE it once the board has joined. Leave TAILSCALE_AUTHKEY unset to omit
  # it (the panel then offers a paste field instead).
  local defines=(--dart-define=BACKEND_BASE_URL="$BACKEND_URL")
  if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    echo ">> Baking in a Tailscale auth key (remember to revoke it after use)."
    defines+=(--dart-define=TAILSCALE_AUTHKEY="$TAILSCALE_AUTHKEY")
  fi

  # --cpu=pi3 selects a Cortex-A53-tuned engine. The board is a 3B; the tuned
  # engine is free performance on a part that has none to spare. It will NOT
  # run on a different CPU, so change this (and BUNDLE_DIR) if the hardware does.
  echo ">> Building arm64 release bundle (backend: $BACKEND_URL)..."
  "$fpt" build --arch=arm64 --cpu=pi3 --release "${defines[@]}"

  [ -f "$BUNDLE_DIR/app.so" ] || {
    echo "!! No app.so in $BUNDLE_DIR -- did the build actually succeed?" >&2
    exit 1
  }
  echo ">> Bundle ready: $BUNDLE_DIR"
}

# flutter-pi itself does NOT need building on the device: flutterpi_tool ships a
# prebuilt aarch64 `flutter-pi` binary and `libflutter_engine.so` inside the
# bundle, so the runtime version-swaps atomically with the app. All the Pi needs
# is the shared libraries those binaries link against.
ensure_runtime_deps() {
  echo ">> Ensuring flutter-pi runtime libraries on $PI_HOST ..."
  ssh "$PI_HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
# Runtime libs only (no -dev): we are not compiling anything here. Pi OS Lite
# already carries most of these for KMS, so this is usually a no-op.
# The list below is what the PREBUILT flutter-pi actually links against, which
# is more than flutter-pi's source-build docs list: the shipped binary is built
# with Vulkan and the GStreamer video player enabled, so libvulkan1 and the
# gstreamer runtimes are hard requirements even though we use neither. Verified
# with `ldd flutter-pi | grep 'not found'` on a fresh Pi OS Lite install --
# without them the unit dies with "error while loading shared libraries".
missing=""
for pkg in libdrm2 libgbm1 libegl1 libgles2 libinput10 libxkbcommon0 libsystemd0 \
           fontconfig libvulkan1 libgstreamer1.0-0 libgstreamer-plugins-base1.0-0; do
  dpkg -s "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
done
if [ -n "$missing" ]; then
  echo ">> installing:$missing"
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends $missing
else
  echo ">> all runtime libraries already present"
fi
# jq and curl drive the updater; a Pi without them silently never updates.
command -v jq >/dev/null || sudo apt-get install -y jq
# wireless-tools supplies iwgetid, which the admin panel's diagnostics card
# shells out to for the current SSID. Without it the card reports "no SSID"
# on a board that is in fact happily on Wi-Fi -- a misleading answer during
# exactly the outage you'd be using the panel to debug.
command -v iwgetid >/dev/null || sudo apt-get install -y --no-install-recommends wireless-tools
REMOTE
}

# ---------------------------------------------------------------------------
# Optional: the admin remote desktop (docs/remote-desktop.md).
#
# A SECOND X session on display :1 -- deliberately NOT a view of the kiosk.
# flutter-pi holds DRM master on tty1 with no compositor under it, and its
# scanout buffer is VC4 T-tiled, so the wall's own pixels cannot be mirrored
# by anything off-the-shelf (/dev/fb0 is a stale fbdev buffer still holding
# the boot console). This gives a terminal and Chromium next to the kiosk.
#
# Skipped entirely unless VNC_PASSWORD is set, so no password is ever stored
# in this repo. Note VNC auth uses only the FIRST 8 CHARACTERS of a password:
# anything longer is silently truncated, which makes for baffling mismatches.
# ---------------------------------------------------------------------------
install_remote_desktop() {
  if [ -z "${VNC_PASSWORD:-}" ]; then
    echo ">> VNC_PASSWORD unset -- skipping admin remote desktop."
    return 0
  fi
  if [ "${#VNC_PASSWORD}" -gt 8 ]; then
    echo "!! VNC_PASSWORD is ${#VNC_PASSWORD} chars; VNC uses only the first 8." >&2
    echo "   Use an 8-character password so what you set is what you type." >&2
    exit 1
  fi

  echo ">> Installing admin remote desktop (VNC :1, tailnet-only)..."
  scp deploy/vnc-xstartup                 "$PI_HOST:/tmp/vnc-xstartup"
  scp deploy/vnc-tigervnc.conf            "$PI_HOST:/tmp/vnc-tigervnc.conf"
  scp deploy/dashboard-vnc-memory.conf    "$PI_HOST:/tmp/dashboard-vnc-memory.conf"
  scp deploy/dashboard-vnc-firewall.service "$PI_HOST:/tmp/dashboard-vnc-firewall.service"

  # Ship the password out-of-band rather than on the ssh command line, where it
  # would be visible in the Pi's process list to any local user for as long as
  # the command runs. The file is 0600 and the remote script deletes it.
  printf '%s' "$VNC_PASSWORD" | ssh "$PI_HOST" 'umask 077; cat > /tmp/.vncpw'

  ssh "$PI_HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
VNC_PASSWORD="$(cat /tmp/.vncpw)"; rm -f /tmp/.vncpw

sudo apt-get install -y --no-install-recommends \
  tigervnc-standalone-server matchbox-window-manager xterm chromium

mkdir -p "$HOME/.vnc"
install -m 0755 /tmp/vnc-xstartup      "$HOME/.vnc/xstartup"
install -m 0644 /tmp/vnc-tigervnc.conf "$HOME/.vnc/tigervnc.conf"

# vncpasswd writes the obfuscated (not encrypted) password file; 0600 matters.
printf '%s\n%s\nn\n' "$VNC_PASSWORD" "$VNC_PASSWORD" | vncpasswd "$HOME/.vnc/passwd" >/dev/null
chmod 0600 "$HOME/.vnc/passwd"

# Map display :1 to this user for the tigervncserver@ systemd template.
grep -q '^:1=' /etc/tigervnc/vncserver.users 2>/dev/null \
  || echo ":1=$USER" | sudo tee -a /etc/tigervnc/vncserver.users >/dev/null

sudo mkdir -p '/etc/systemd/system/tigervncserver@:1.service.d'
sudo install -m 0644 /tmp/dashboard-vnc-memory.conf \
  '/etc/systemd/system/tigervncserver@:1.service.d/override.conf'
sudo install -m 0644 /tmp/dashboard-vnc-firewall.service \
  /etc/systemd/system/dashboard-vnc-firewall.service

sudo systemctl daemon-reload
sudo systemctl enable --now dashboard-vnc-firewall.service
sudo systemctl enable --now 'tigervncserver@:1.service'
rm -f /tmp/vnc-xstartup /tmp/vnc-tigervnc.conf /tmp/dashboard-vnc-memory.conf
REMOTE
  echo ">> Remote desktop up on :1 (port 5901), reachable over the tailnet only."
}

case "$MODE" in

# ---------------------------------------------------------------------------
# provision: everything that needs a shell on the device. Run once.
# ---------------------------------------------------------------------------
provision)
  build_bundle
  ensure_runtime_deps

  VERSION="${VERSION:-$(date -u +%Y.%m.%d-%H%M)}"
  echo ">> Provisioning $PI_HOST with initial version $VERSION ..."

  # tar over ssh rather than rsync: rsync must exist on BOTH ends, and it is not
  # present on a stock Windows/Git-Bash dev box (nor on Pi OS Lite). tar and ssh
  # are everywhere. --delete is emulated by clearing the target dir first; it is
  # a fresh version directory, so there is nothing to preserve.
  ssh "$PI_HOST" "rm -rf '$REMOTE_DIR/versions/$VERSION' && mkdir -p '$REMOTE_DIR/versions/$VERSION'"
  tar -czf - -C "$BUNDLE_DIR" . \
    | ssh "$PI_HOST" "tar -xzf - -C '$REMOTE_DIR/versions/$VERSION' && \
        chmod +x '$REMOTE_DIR/versions/$VERSION/flutter-pi'"
  # ^ chmod is not belt-and-braces: NTFS has no execute bit, so a bundle tarred
  # on a Windows dev box arrives as mode 644 and the unit dies with EACCES.

  # Point `current` at it the same way the updater will.
  ssh "$PI_HOST" "ln -sfn '$REMOTE_DIR/versions/$VERSION' '$REMOTE_DIR/current.tmp' && \
    mv -Tf '$REMOTE_DIR/current.tmp' '$REMOTE_DIR/current' && \
    printf '%s\n' '$VERSION' > '$REMOTE_DIR/state'"

  echo ">> Installing updater, units, udev rule, sudoers (idempotent)..."
  scp deploy/update.sh                "$PI_HOST:/tmp/update.sh"
  scp deploy/dashboard.service        "$PI_HOST:/tmp/dashboard.service"
  scp deploy/dashboard-update.service "$PI_HOST:/tmp/dashboard-update.service"
  scp deploy/dashboard-update.timer   "$PI_HOST:/tmp/dashboard-update.timer"
  scp deploy/dashboard-update.sudoers "$PI_HOST:/tmp/dashboard-update.sudoers"
  scp deploy/dashboard-power.sudoers  "$PI_HOST:/tmp/dashboard-power.sudoers"
  scp deploy/dashboard-admin.sudoers  "$PI_HOST:/tmp/dashboard-admin.sudoers"
  scp deploy/90-backlight.rules       "$PI_HOST:/tmp/90-backlight.rules"

  ssh "$PI_HOST" "install -m 0755 /tmp/update.sh '$REMOTE_DIR/update.sh' && \
    printf 'BACKEND_URL=%s\nROOT=%s\n' '$BACKEND_URL' '$REMOTE_DIR' \
      | sudo tee /etc/default/dashboard-update >/dev/null && \
    sudo mv /tmp/dashboard.service /tmp/dashboard-update.service \
            /tmp/dashboard-update.timer /etc/systemd/system/ && \
    sudo install -m 0440 -o root -g root /tmp/dashboard-update.sudoers \
      /etc/sudoers.d/dashboard-update && \
    sudo visudo -cf /etc/sudoers.d/dashboard-update && \
    sudo install -m 0440 -o root -g root /tmp/dashboard-power.sudoers \
      /etc/sudoers.d/dashboard-power && \
    sudo visudo -cf /etc/sudoers.d/dashboard-power && \
    sudo install -m 0440 -o root -g root /tmp/dashboard-admin.sudoers \
      /etc/sudoers.d/dashboard-admin && \
    sudo visudo -cf /etc/sudoers.d/dashboard-admin && \
    sudo mv /tmp/90-backlight.rules /etc/udev/rules.d/ && \
    sudo usermod -aG video,render,input pi && \
    sudo systemctl disable --now getty@tty1.service && \
    sudo systemctl daemon-reload && \
    sudo systemctl enable --now dashboard.service && \
    sudo systemctl enable --now dashboard-update.timer && \
    sudo udevadm control --reload && sudo udevadm trigger"

  install_remote_desktop

  echo ">> Provisioned. From now on, ship updates with:  ./deploy/deploy.sh publish"
  echo ">> Tail logs:      ssh $PI_HOST journalctl -u dashboard -f"
  echo ">> Tail updates:   ssh $PI_HOST journalctl -u dashboard-update -f"
  ;;

# ---------------------------------------------------------------------------
# publish: the routine path. No access to the Pi required.
# ---------------------------------------------------------------------------
publish)
  build_bundle

  VERSION="${VERSION:-$(date -u +%Y.%m.%d-%H%M)}"
  case "$VERSION" in */*|*..*) echo "!! unsafe VERSION: $VERSION" >&2; exit 1 ;; esac

  OUT="./build/publish"
  rm -rf "$OUT" && mkdir -p "$OUT"
  TARBALL="$OUT/$VERSION.tar.gz"

  echo ">> Packing $VERSION ..."
  # Pack the CONTENTS of the bundle dir, so the tarball unpacks straight into
  # a version directory (update.sh expects app.so + flutter-pi at the top level).
  tar -czf "$TARBALL" -C "$BUNDLE_DIR" .

  SHA="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
  echo ">> sha256 $SHA"

  cat > "$OUT/version.json" <<EOF
{
  "version": "$VERSION",
  "bundle_url": "$BACKEND_URL/bundles/$VERSION.tar.gz",
  "sha256": "$SHA"
}
EOF

  # Order matters: upload the bundle FIRST. If version.json went up first, a Pi
  # could poll in the gap and try to download a bundle that isn't there yet.
  publish_file "$TARBALL" "bundles/$VERSION.tar.gz"
  publish_file "$OUT/version.json" "version.json"

  echo ">> Published $VERSION. Devices pick it up within ~15 min (timer + jitter)."
  echo ">> Roll back by re-publishing a previous version.json."
  ;;

*)
  echo "usage: $0 {provision|publish}" >&2
  exit 1
  ;;
esac
