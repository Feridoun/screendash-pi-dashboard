#!/usr/bin/env bash
# Self-updater. Runs ON THE PI from a systemd timer (see dashboard-update.timer).
#
# The Pi cannot be reached from outside the office network, so updates invert the
# direction: the device polls the same backend origin it already polls for photos.
# See docs/dashboard-plan.md, Phase 1 -- this is "GET a small artifact on a timer"
# applied to the bundle itself.
#
# Layout it maintains under $ROOT:
#   current -> versions/<version>    symlink; dashboard.service runs this
#   previous -> versions/<version>   symlink; the last version known to boot
#   versions/<version>/              unpacked bundles: app.so + the bundled
#                                    flutter-pi runtime + libflutter_engine.so
#   state                            last version we successfully started
#
# Update is atomic (symlink swap) and self-healing (rolls back if the new bundle
# fails to stay up).
set -euo pipefail

# Set by provision into /etc/default/dashboard-update. No default: polling the
# wrong origin would look like "no updates available" forever.
BACKEND_URL="${BACKEND_URL:?set BACKEND_URL to your backend origin}"
# Bearer token for GET /bundles/*. The Worker serves the bundle to nobody else
# (worker/src/serve.js) because the bundle can carry build-time secrets. Written
# by `deploy.sh provision` into /etc/default/dashboard-update, which systemd
# reads as root before dropping to `pi`. Empty here means "unauthenticated" --
# the download 404s against a gated backend, the update fails, and the version
# already running stays up.
DEVICE_TOKEN="${DEVICE_TOKEN:-}"
ROOT="${ROOT:-/home/pi/dashboard}"
SERVICE="${SERVICE:-dashboard.service}"
# How long the new version must stay running before we accept it.
SETTLE_SECONDS="${SETTLE_SECONDS:-45}"
# How long to watch an already-running version when finishing an interrupted
# swap. Shorter than SETTLE_SECONDS on purpose: it has usually been up since
# boot already, so this is a confirmation rather than a burn-in.
RESUME_WATCH_SECONDS="${RESUME_WATCH_SECONDS:-20}"
# Unpacked bundles to retain (current + previous + a little history).
KEEP_VERSIONS="${KEEP_VERSIONS:-3}"

VERSIONS_DIR="$ROOT/versions"
CURRENT_LINK="$ROOT/current"
PREVIOUS_LINK="$ROOT/previous"

log() { echo "[update] $*"; }
fail() { echo "[update] ERROR: $*" >&2; exit 1; }

mkdir -p "$VERSIONS_DIR"

swap_to() {
  # ln -sfn onto a temp name + mv is atomic; a bare `ln -sfn` over an existing
  # symlink-to-directory would nest inside it instead of replacing it.
  ln -sfn "$1" "$CURRENT_LINK.tmp"
  mv -Tf "$CURRENT_LINK.tmp" "$CURRENT_LINK"
}

# Is the service up and not respawning *right now*? Unlike the post-restart
# check in step 4 this observes without restarting: the resume path below may
# find a version that is running perfectly well, and must not blink a wall
# display to prove it.
healthy_now() {
  systemctl is-active --quiet "$SERVICE" || return 1
  local before after i=0
  before="$(systemctl show -p NRestarts --value "$SERVICE" 2>/dev/null || echo 0)"
  while [ "$i" -lt "$RESUME_WATCH_SECONDS" ]; do
    sleep 1
    systemctl is-active --quiet "$SERVICE" || return 1
    i=$((i + 1))
  done
  after="$(systemctl show -p NRestarts --value "$SERVICE" 2>/dev/null || echo 0)"
  [ $(( ${after:-0} - ${before:-0} )) -le 1 ]
}

# --- 0. Finish a swap that never confirmed itself ----------------------------
# `state` records the last version observed healthy; `current` is what actually
# runs. They diverge only when a previous run swapped a version in and died
# before the settle check finished -- a power cut, a shutdown from the config
# modal, an OOM kill, `systemctl stop`.
#
# That window used to be permanent: step 1 compares the wanted version against
# `current`, so the very next tick reports "already on X; nothing to do" and the
# auto-rollback in step 4 never gets a chance to run. A bundle interrupted at
# exactly the wrong moment would stay live and unverified forever, which is the
# one outcome this updater is supposed to make impossible.
resume_interrupted_swap() {
  [ -L "$CURRENT_LINK" ] || return 0

  local cur recorded
  cur="$(basename "$(readlink -f "$CURRENT_LINK")")"
  recorded="$(cat "$ROOT/state" 2>/dev/null || true)"

  # No state file yet (freshly provisioned) is not an interrupted update.
  [ -n "$recorded" ] || return 0
  [ "$recorded" != "$cur" ] || return 0

  log "state ($recorded) != current ($cur) -- a previous update never confirmed health"

  if healthy_now; then
    log "$cur is healthy; recording it and carrying on"
    printf '%s\n' "$cur" > "$ROOT/state"
    return 0
  fi

  log "$cur is unhealthy after an interrupted update -- rolling back"
  local target
  target="$(readlink -f "$PREVIOUS_LINK" 2>/dev/null || true)"
  if [ -n "$target" ] && [ -d "$target" ]; then
    swap_to "$target"
    sudo systemctl restart "$SERVICE" || true
    printf '%s\n' "$(basename "$target")" > "$ROOT/state"
    log "rolled back to $(basename "$target")"
    # Don't let the next tick reinstall it.
    [ "$cur" != "$(basename "$target")" ] && rm -rf "$VERSIONS_DIR/$cur"
    exit 1
  fi
  fail "no previous version to roll back to -- leaving $cur in place"
}

resume_interrupted_swap

# --- 1. Ask the backend what version it wants us on -------------------------
# version.json:  {"version":"1.4.0","bundle_url":"...","sha256":"..."}
log "checking $BACKEND_URL/version.json"
meta="$(curl -fsS --max-time 30 --retry 3 --retry-delay 5 "$BACKEND_URL/version.json")" \
  || { log "backend unreachable; leaving current version in place"; exit 0; }

want_version="$(printf '%s' "$meta" | jq -re '.version')" || fail "version.json missing .version"
bundle_url="$(printf '%s' "$meta" | jq -re '.bundle_url')" || fail "version.json missing .bundle_url"
want_sha="$(printf '%s' "$meta" | jq -re '.sha256')" || fail "version.json missing .sha256"

# Refuse anything that would escape the versions directory.
case "$want_version" in
  */*|*..*|"") fail "refusing unsafe version string: '$want_version'" ;;
esac

# version.json is the one input that decides where we connect, and the next
# request carries DEVICE_TOKEN. curl has stripped Authorization across cross-host
# redirects since 7.58, but don't lean on that -- refuse an off-origin bundle_url
# outright, so the token can only ever reach the backend we were provisioned for.
case "$bundle_url" in
  "${BACKEND_URL%/}"/*) ;;
  *) fail "version.json points bundle_url off-origin: $bundle_url" ;;
esac

have_version=""
[ -L "$CURRENT_LINK" ] && have_version="$(basename "$(readlink -f "$CURRENT_LINK")")"

if [ "$want_version" = "$have_version" ]; then
  log "already on $want_version; nothing to do"
  exit 0
fi

log "update available: ${have_version:-<none>} -> $want_version"

# --- 2. Download and verify BEFORE touching anything running ----------------
tmp="$(mktemp -d "${TMPDIR:-/tmp}/dashboard-update.XXXXXX")"
# shellcheck disable=SC2064  # expand $tmp now, on purpose
trap "rm -rf '$tmp'" EXIT

log "downloading $bundle_url"
# The token goes in a 0600 file inside $tmp (mktemp -d already made it 0700)
# rather than on the curl command line: /proc/<pid>/cmdline is world-readable,
# so a -H flag would widen the token from "root and pi" to any local user.
curl_auth=()
if [ -n "$DEVICE_TOKEN" ]; then
  ( umask 077; printf 'Authorization: Bearer %s\n' "$DEVICE_TOKEN" > "$tmp/auth" )
  curl_auth=(-H "@$tmp/auth")
else
  log "no DEVICE_TOKEN -- this will fail if the backend gates bundle downloads"
fi
curl -fsSL --max-time 600 --retry 3 --retry-delay 10 \
  "${curl_auth[@]}" -o "$tmp/bundle.tar.gz" "$bundle_url" \
  || fail "download failed (a 404 here usually means a missing or wrong DEVICE_TOKEN)"

got_sha="$(sha256sum "$tmp/bundle.tar.gz" | cut -d' ' -f1)"
[ "$got_sha" = "$want_sha" ] \
  || fail "checksum mismatch (want $want_sha, got $got_sha) -- refusing to install"
log "checksum ok"

mkdir -p "$tmp/unpacked"
tar -xzf "$tmp/bundle.tar.gz" -C "$tmp/unpacked" || fail "unpack failed"

# Sanity-check the payload before it can replace a working install: a release
# bundle has app.so (AOT), a debug/JIT one has kernel_blob.bin. Neither means
# this is not a flutter-pi bundle, and installing it would produce a device that
# boots to a black screen.
[ -f "$tmp/unpacked/kernel_blob.bin" ] || [ -f "$tmp/unpacked/app.so" ] \
  || fail "bundle looks wrong (no kernel_blob.bin or app.so) -- refusing to install"

# The bundle carries its own flutter-pi runtime. NTFS has no execute bit, so a
# tarball packed on a Windows dev box arrives mode 644 and the unit would fail
# with EACCES on restart -- and then roll back, looking like a bad build.
if [ -f "$tmp/unpacked/flutter-pi" ]; then
  chmod +x "$tmp/unpacked/flutter-pi" \
    || fail "could not make flutter-pi executable -- refusing to install"
fi

# --- 3. Stage it, then swap --------------------------------------------------
target="$VERSIONS_DIR/$want_version"
rm -rf "$target"
mv "$tmp/unpacked" "$target"

# Remember what we're rolling back TO before we overwrite the current pointer.
rollback_to=""
if [ -L "$CURRENT_LINK" ]; then
  rollback_to="$(readlink -f "$CURRENT_LINK")"
  ln -sfn "$rollback_to" "$PREVIOUS_LINK"
fi

log "switching current -> $want_version"
swap_to "$target"

# --- 4. Restart and verify it actually stays up ------------------------------
# NRestarts is cumulative for the unit's lifetime, so compare against a baseline
# taken just before our restart -- otherwise a long-lived device with a few old
# restarts would reject every new version as a crash loop.
restarts_before="$(systemctl show -p NRestarts --value "$SERVICE" 2>/dev/null || echo 0)"

sudo systemctl restart "$SERVICE" || fail "restart command failed"

log "waiting ${SETTLE_SECONDS}s to confirm $want_version is stable"
settled=1
for _ in $(seq 1 "$SETTLE_SECONDS"); do
  sleep 1
  if ! systemctl is-active --quiet "$SERVICE"; then settled=0; break; fi
done

# Restart=always means a crash-looping bundle still reports "active" between
# respawns, so also require that it hasn't been restarting repeatedly since we
# swapped it in.
restarts_after="$(systemctl show -p NRestarts --value "$SERVICE" 2>/dev/null || echo 0)"
restarts=$(( ${restarts_after:-0} - ${restarts_before:-0} ))
[ "$restarts" -lt 0 ] && restarts=0   # counter resets on daemon-reexec

if [ "$settled" -eq 1 ] && [ "$restarts" -le 2 ]; then
  log "$want_version is healthy (restarts during settle: $restarts)"
  printf '%s\n' "$want_version" > "$ROOT/state"
else
  log "$want_version unhealthy (active=$settled restarts=$restarts) -- rolling back"
  if [ -n "$rollback_to" ] && [ -d "$rollback_to" ]; then
    swap_to "$rollback_to"
    sudo systemctl restart "$SERVICE" || true
    log "rolled back to $(basename "$rollback_to")"
    # Don't retry this version on the next tick.
    rm -rf "$target"
    exit 1
  fi
  fail "no previous version to roll back to -- leaving $want_version in place"
fi

# --- 5. Prune old unpacked bundles ------------------------------------------
keep_current="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
keep_previous="$(readlink -f "$PREVIOUS_LINK" 2>/dev/null || true)"
# shellcheck disable=SC2012  # ls -t is fine here; version dirs have no odd names
ls -1dt "$VERSIONS_DIR"/*/ 2>/dev/null | tail -n +"$((KEEP_VERSIONS + 1))" | while read -r old; do
  old="${old%/}"
  [ "$old" = "$keep_current" ] && continue
  [ "$old" = "$keep_previous" ] && continue
  log "pruning $(basename "$old")"
  rm -rf "$old"
done

log "done: running $want_version"
