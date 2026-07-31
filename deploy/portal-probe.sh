#!/usr/bin/env bash
# Captive-portal appraisal. Runs ON THE PI (or any Linux box sitting on the same
# guest SSID) to answer one question: what will it take to get this unattended
# display online and KEEP it online?
#
# Nothing here logs in to anything. It only measures, so it is safe to run on a
# network before you have permission to automate against it.
#
#   ./portal-probe.sh snapshot      One full pass (~90 s). Run it TWICE:
#                                   once before you touch the portal, once after
#                                   you log in by hand. LABEL=pre / LABEL=post
#
#   ./portal-probe.sh soak          Long-running. One line every $SOAK_INTERVAL
#                                   into $SOAK_LOG. Leave it for 48-72 h: this is
#                                   the only way to learn the session lifetime.
#
#   ./portal-probe.sh report        Summarise the soak log: how long a session
#                                   lasts, when it drops, how much data you used.
#
#   ./portal-probe.sh request       Emit a filled-in request to send to whoever
#                                   runs the Wi-Fi (the cheapest fix is usually
#                                   for them to exempt the device entirely).
#
# Env: IFACE BACKEND_URL LABEL OUT_DIR SOAK_LOG SOAK_INTERVAL
#
# Deliberately NOT `set -e`: probes are expected to fail, and a failed probe is a
# finding, not a crash.
set -uo pipefail

IFACE="${IFACE:-}"
BACKEND_URL="${BACKEND_URL:-}"
LABEL="${LABEL:-snapshot}"
OUT_DIR="${OUT_DIR:-$HOME/portal-appraisal}"
SOAK_LOG="${SOAK_LOG:-$OUT_DIR/soak.tsv}"
SOAK_INTERVAL="${SOAK_INTERVAL:-300}"
CURL_TIMEOUT="${CURL_TIMEOUT:-8}"

mkdir -p "$OUT_DIR"

# --- output helpers ---------------------------------------------------------
BOLD=""; DIM=""; RST=""
[ -t 1 ] && { BOLD=$'\033[1m'; DIM=$'\033[2m'; RST=$'\033[0m'; }

sec()  { printf '\n%s== %s %s\n' "$BOLD" "$1" "$RST"; }
kv()   { printf '  %-26s %s\n' "$1" "$2"; }
note() { printf '  %s%s%s\n' "$DIM" "$*" "$RST"; }
flag() { printf '  !! %s\n' "$*"; }

# Findings accumulate as JSON so `request` mode can quote them back at you.
# Escaping is done with parameter expansion rather than sed: probe output is
# arbitrary text off the network, and a portal page title with a quote in it
# should not be able to produce a broken report.
JSON_FILE="$OUT_DIR/$LABEL.json"
: > "$JSON_FILE.parts"

jesc() {
  local s="$1"
  s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
  s="${s//\\/\\\\}"   # backslashes first, or we escape our own escapes
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# Parts carry no trailing comma; jflush joins them. That keeps the last-element
# comma problem out of the hot path.
jput() { printf '  "%s": "%s"\n' "$(jesc "$1")" "$(jesc "$2")" >> "$JSON_FILE.parts"; }

jflush() {
  {
    echo "{"
    awk 'NR > 1 { printf ",\n" } { printf "%s", $0 } END { if (NR) printf "\n" }' \
      "$JSON_FILE.parts"
    echo "}"
  } > "$JSON_FILE"
  rm -f "$JSON_FILE.parts"
}

# Read one string value back out of a snapshot written by jput.
jget() {
  [ -f "$JSON_GET_FILE" ] || return 0
  awk -v key="$1" '
    index($0, "  \"" key "\": \"") == 1 {
      v = substr($0, index($0, "\": \"") + 4)
      sub(/",?$/, "", v)
      gsub(/\\"/, "\"", v)
      gsub(/\\\\/, "\\", v)
      print v
      exit
    }' "$JSON_GET_FILE"
}

have() { command -v "$1" >/dev/null 2>&1; }
now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

# TCP reachability without depending on nc being installed.
tcp_open() {
  local host="$1" port="$2" t="${3:-5}"
  timeout "$t" bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
}

# --- interface discovery ----------------------------------------------------
detect_iface() {
  [ -n "$IFACE" ] && { echo "$IFACE"; return; }
  # The interface holding the default route is the one that matters.
  local i
  i="$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
  [ -z "$i" ] && i="$(ls /sys/class/net 2>/dev/null | grep -E '^wl' | head -1)"
  echo "${i:-wlan0}"
}

# ---------------------------------------------------------------------------
# 1. The link itself
# ---------------------------------------------------------------------------
probe_link() {
  local dev="$1"
  sec "LINK"

  local mac_now mac_perm mtu ip4 gw dns ssid bssid signal
  mac_now="$(cat "/sys/class/net/$dev/address" 2>/dev/null)"
  mtu="$(cat "/sys/class/net/$dev/mtu" 2>/dev/null)"
  ip4="$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}' | head -1)"
  gw="$(ip -4 -o route show default dev "$dev" 2>/dev/null | awk '{print $3}' | head -1)"
  dns="$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)"

  if have iw; then
    ssid="$(iw dev "$dev" link 2>/dev/null | sed -n 's/^\tSSID: //p')"
    bssid="$(iw dev "$dev" link 2>/dev/null | sed -n 's/^Connected to \([0-9a-f:]*\).*/\1/p')"
    signal="$(iw dev "$dev" link 2>/dev/null | sed -n 's/^\tsignal: //p')"
  fi
  if have ethtool; then
    mac_perm="$(ethtool -P "$dev" 2>/dev/null | awk '{print $NF}')"
  fi

  kv "interface" "$dev"
  kv "ssid / bssid" "${ssid:-?} / ${bssid:-?}"
  kv "signal" "${signal:-?}"
  kv "ipv4 / gateway" "${ip4:-none} / ${gw:-none}"
  kv "dns servers" "${dns:-none}"
  kv "mtu" "${mtu:-?}"
  kv "mac (in use)" "${mac_now:-?}"

  jput iface "$dev"; jput ssid "${ssid:-}"; jput bssid "${bssid:-}"
  jput ipv4 "${ip4:-}"; jput gateway "${gw:-}"; jput dns "${dns:-}"
  jput mtu "${mtu:-}"; jput mac "${mac_now:-}"

  # MAC randomisation is the single most common reason a portal session, or an
  # IT MAC allowlist, silently stops applying after a reboot.
  if [ -n "${mac_perm:-}" ] && [ "$mac_perm" != "$mac_now" ]; then
    kv "mac (hardware)" "$mac_perm"
    flag "MAC IS RANDOMISED. Any MAC-bound portal session or allowlist entry"
    flag "   will break on reboot. Pin it -- see docs/captive-portal.md."
    jput mac_randomised yes
  else
    jput mac_randomised no
  fi

  if have nmcli; then
    local cloned
    cloned="$(nmcli -t -f 802-11-wireless.cloned-mac-address connection show \
              "$(nmcli -t -f NAME connection show --active 2>/dev/null | head -1)" \
              2>/dev/null | cut -d: -f2-)"
    [ -n "$cloned" ] && kv "NM cloned-mac" "$cloned"
    [ -n "$cloned" ] && jput nm_cloned_mac "$cloned"
  fi
}

# ---------------------------------------------------------------------------
# 2. Is there a portal, and where is it?
# ---------------------------------------------------------------------------
# Four vendors' probe URLs. Agreement between them is worth having: some portals
# whitelist one vendor's endpoint and not the others, which alone tells you the
# portal is doing per-URL filtering rather than a blanket redirect.
PROBES=(
  "http://connectivitycheck.gstatic.com/generate_204|204|"
  "http://www.msftconnecttest.com/connecttest.txt|200|Microsoft Connect Test"
  "http://detectportal.firefox.com/success.txt|200|success"
  "http://captive.apple.com/hotspot-detect.html|200|Success"
)

PORTAL_URL=""
NET_STATE="unknown"

probe_portal() {
  sec "PORTAL DETECTION"
  local open=0 redirected=0 blocked=0 tampered=0

  for spec in "${PROBES[@]}"; do
    IFS='|' read -r url want_code want_body <<< "$spec"
    local body code redir out
    body="$(mktemp)"
    # No -L: the redirect IS the signal we are looking for.
    out="$(curl -sS -m "$CURL_TIMEOUT" -o "$body" \
             -w '%{http_code}|%{redirect_url}' "$url" 2>/dev/null)"
    code="${out%%|*}"; redir="${out#*|}"

    if [ "$code" = "$want_code" ] && { [ -z "$want_body" ] || grep -qF "$want_body" "$body"; }; then
      kv "$(basename "$url")" "open"
      open=$((open + 1))
    elif [ "$code" = "000" ]; then
      kv "$(basename "$url")" "no answer (dropped/timeout)"
      blocked=$((blocked + 1))
    elif [ "${code:0:1}" = "3" ] && [ -n "$redir" ]; then
      kv "$(basename "$url")" "$code -> $redir"
      [ -z "$PORTAL_URL" ] && PORTAL_URL="$redir"
      redirected=$((redirected + 1))
    else
      # 200 with the wrong body means something answered in the server's place.
      kv "$(basename "$url")" "$code, unexpected body (intercepted)"
      tampered=$((tampered + 1))
      [ -z "$PORTAL_URL" ] && PORTAL_URL="$url"
    fi
    rm -f "$body"
  done

  if   [ "$open" -eq "${#PROBES[@]}" ]; then NET_STATE="online"
  elif [ $((redirected + tampered)) -gt 0 ]; then NET_STATE="portal"
  elif [ "$open" -gt 0 ]; then NET_STATE="partial"
  else NET_STATE="offline"
  fi

  kv "verdict" "$NET_STATE"
  [ -n "$PORTAL_URL" ] && kv "portal url" "$PORTAL_URL"
  jput net_state "$NET_STATE"; jput portal_url "${PORTAL_URL:-}"

  [ "$NET_STATE" = partial ] && \
    note "Mixed results = per-destination filtering, not a plain redirect portal."
}

# ---------------------------------------------------------------------------
# 3. RFC 8908 Captive Portal API -- the best possible outcome
# ---------------------------------------------------------------------------
# If the network publishes a capport API, it hands you `seconds-remaining` as a
# number. That turns "keep it renewed" from guesswork into a scheduled job.
probe_capport() {
  sec "CAPPORT API (RFC 8908)"
  local api=""

  # DHCP option 114. Where it lands depends on the DHCP client in use.
  if have dhcpcd; then
    api="$(dhcpcd -U "$1" 2>/dev/null | sed -n 's/^captive_portal_uri=//p' | tr -d "'\"")"
  fi
  if [ -z "$api" ]; then
    api="$(grep -rhoiE 'https?://[^ "'"'"']*captive[^ "'"'"']*' \
           /var/lib/dhcpcd/ /var/lib/dhcp/ /var/lib/NetworkManager/ 2>/dev/null | head -1)"
  fi
  if [ -z "$api" ] && have nmcli; then
    api="$(nmcli -t -f IP4.OPTION device show "$1" 2>/dev/null \
           | sed -n 's/.*captive[-_]portal[^=]*= *//p' | head -1)"
  fi

  if [ -z "$api" ]; then
    kv "advertised" "no (no DHCP option 114 found)"
    note "Most portals still do not implement this. Not a blocker, just means"
    note "you cannot ask the network how long you have left."
    jput capport "absent"
    return
  fi

  kv "api url" "$api"
  local resp
  resp="$(curl -sS -m "$CURL_TIMEOUT" -H 'Accept: application/captive+json' "$api" 2>/dev/null)"
  kv "api response" "${resp:-<empty>}"
  jput capport "present"; jput capport_url "$api"; jput capport_response "${resp:-}"

  if printf '%s' "$resp" | grep -q 'seconds-remaining'; then
    flag "capport reports seconds-remaining -- renew on a schedule derived from it."
  fi
}

# ---------------------------------------------------------------------------
# 4. What kind of portal is it? (decides whether it can be automated at all)
# ---------------------------------------------------------------------------
probe_portal_page() {
  [ -z "$PORTAL_URL" ] && return 0
  sec "PORTAL PAGE"

  local page hdrs final code
  page="$OUT_DIR/$LABEL-portal.html"
  hdrs="$OUT_DIR/$LABEL-portal.headers"
  final="$(curl -sSL -m 20 -o "$page" -D "$hdrs" -w '%{url_effective}' \
           "$PORTAL_URL" 2>/dev/null)"
  code="$(awk '/^HTTP\//{c=$2} END{print c}' "$hdrs" 2>/dev/null)"

  kv "final url" "${final:-?}"
  kv "status" "${code:-?}"
  kv "saved to" "$page"
  jput portal_final_url "${final:-}"

  local size; size="$(wc -c < "$page" 2>/dev/null)"
  kv "page size" "${size:-0} bytes"

  # Vendor fingerprint. Knowing the vendor tells you the login endpoint shape
  # before you reverse-engineer anything.
  local vendor="unknown"
  for v in meraki aruba clearpass ruckus unifi cisco fortinet fortigate sophos \
           mikrotik zyxel cloud4wi purplewifi wifi-portal pfsense opnsense \
           radius coova chilli; do
    if grep -qi "$v" "$page" "$hdrs" 2>/dev/null; then vendor="$v"; break; fi
  done
  kv "vendor fingerprint" "$vendor"
  jput portal_vendor "$vendor"

  # Auth shape. This is the fork in the road for automation.
  local shape="unknown" forms
  forms="$(grep -ciE '<form' "$page" 2>/dev/null)"
  if   grep -qiE 'type=["'"'"']?password' "$page"; then shape="credentials"
  elif grep -qiE 'sms|mobile number|phone number|verification code' "$page"; then shape="sms/one-time code"
  elif grep -qiE 'sign in with (google|facebook|microsoft)|oauth|saml' "$page"; then shape="social/SSO"
  elif grep -qiE 'voucher|access code|room number|surname' "$page"; then shape="voucher/code"
  elif grep -qiE 'accept|agree|terms|conditions|continue' "$page"; then shape="click-through (terms)"
  fi
  kv "forms on page" "${forms:-0}"
  kv "auth shape" "$shape"
  jput portal_auth_shape "$shape"

  # A page that renders its form in JS cannot be driven by curl.
  local scripts; scripts="$(grep -ciE '<script' "$page" 2>/dev/null)"
  kv "script tags" "${scripts:-0}"
  if [ "${forms:-0}" -eq 0 ] && [ "${scripts:-0}" -gt 3 ]; then
    flag "No <form> but heavy JS: the login is built client-side."
    flag "   curl cannot drive this; you need a headless browser or an exemption."
    jput portal_js_driven yes
  fi

  case "$shape" in
    sms/one-time*|social/SSO)
      flag "This auth shape CANNOT be automated by an unattended device."
      flag "   Go straight to the exemption request (./portal-probe.sh request)." ;;
  esac
}

# ---------------------------------------------------------------------------
# 5. What actually gets out? (run this AFTER logging in by hand)
# ---------------------------------------------------------------------------
probe_egress() {
  sec "EGRESS"

  # DNS: does it resolve, and is the answer honest?
  local a_pub a_local
  if have dig; then
    a_pub="$(dig +short +time=3 +tries=1 @1.1.1.1 example.com A 2>/dev/null | head -1)"
    a_local="$(dig +short +time=3 +tries=1 example.com A 2>/dev/null | head -1)"
    kv "dns via local resolver" "${a_local:-FAILED}"
    kv "dns via 1.1.1.1 direct" "${a_pub:-BLOCKED}"
    if [ -n "$a_local" ] && [ -n "$a_pub" ] && [ "$a_local" != "$a_pub" ]; then
      flag "DNS answers differ -- the network rewrites DNS."
      jput dns_rewritten yes
    fi
    [ -z "$a_pub" ] && note "Outbound 53 to public resolvers is blocked; you must use theirs."
    jput dns_local "${a_local:-}"; jput dns_public "${a_pub:-}"
  else
    kv "dns" "$(getent hosts example.com | head -1 || echo FAILED)"
  fi

  # Ports the dashboard and its support tooling actually need.
  local checks=(
    "1.1.1.1|443|https (generic)"
    "1.1.1.1|53|dns over tcp"
    "one.one.one.one|443|https by name"
    "github.com|22|ssh outbound"
  )
  for c in "${checks[@]}"; do
    IFS='|' read -r h p desc <<< "$c"
    if tcp_open "$h" "$p" 5; then kv "$desc ($p)" "open"
    else kv "$desc ($p)" "BLOCKED"; fi
  done

  # ICMP is often dropped even on a working network -- informational only.
  if ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then kv "icmp out" "ok"
  else kv "icmp out" "blocked (usually harmless)"; fi

  # The one that decides whether the dashboard works at all.
  if [ -n "$BACKEND_URL" ]; then
    local t code
    t="$(curl -sS -m 20 -o /dev/null -w '%{http_code}|%{time_total}|%{speed_download}' \
         "$BACKEND_URL/manifest.json" 2>/dev/null)"
    code="${t%%|*}"
    kv "backend manifest.json" "HTTP ${code:-000} in $(printf '%s' "$t" | cut -d'|' -f2)s"
    jput backend_status "${code:-000}"
    [ "$code" = "000" ] && flag "BACKEND UNREACHABLE. Nothing else matters until this is fixed."

    # TLS interception: an inspecting middlebox replaces the issuer, and will
    # break the moment its own root is not in the Pi's trust store.
    local host issuer
    host="$(printf '%s' "$BACKEND_URL" | sed -E 's#https?://([^/:]+).*#\1#')"
    if have openssl && [ -n "$host" ]; then
      issuer="$(echo | timeout 10 openssl s_client -connect "$host:443" \
                -servername "$host" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)"
      kv "backend cert issuer" "${issuer:-unavailable}"
      jput tls_issuer "${issuer:-}"
      if printf '%s' "$issuer" | grep -qiE 'fortinet|palo alto|zscaler|sophos|bluecoat|netskope|proxy|firewall'; then
        flag "TLS IS BEING INTERCEPTED. The Pi needs their root CA installed,"
        flag "   or the backend host exempted from inspection."
      fi
    fi
  else
    note "BACKEND_URL not set -- skipped the checks that matter most."
  fi

  # Path MTU. A portal behind a tunnel often clamps below 1500, which shows up
  # as large responses hanging rather than failing.
  local best=0
  for s in 1472 1464 1452 1400 1372; do
    if ping -c1 -W3 -M do -s "$s" 1.1.1.1 >/dev/null 2>&1; then best=$((s + 28)); break; fi
  done
  if [ "$best" -gt 0 ]; then
    kv "path mtu" "$best"
    [ "$best" -lt 1500 ] && note "Below 1500 -- clamp MSS if large downloads stall."
  else
    kv "path mtu" "not measurable (icmp filtered)"
  fi
  jput path_mtu "$best"

  # Tailscale is how you get a shell back if this goes wrong; it needs UDP out.
  if have tailscale; then
    kv "tailscale netcheck" "see below"
    timeout 30 tailscale netcheck 2>&1 | sed 's/^/    /'
  else
    note "tailscale not installed -- cannot verify UDP egress for remote access."
  fi
}

# ---------------------------------------------------------------------------
# 6. Clock. A Pi 3B has no RTC; TLS fails if it boots with the wrong time.
# ---------------------------------------------------------------------------
probe_clock() {
  sec "CLOCK"
  kv "system time (utc)" "$(now)"

  if have timedatectl; then
    kv "ntp synchronised" "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
  fi

  local ntp_ok="no"
  if have python3; then
    ntp_ok="$(python3 - <<'PY' 2>/dev/null || echo no
import socket, struct, sys
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(5)
    s.sendto(b'\x1b' + 47 * b'\0', ('pool.ntp.org', 123))
    d, _ = s.recvfrom(48)
    t = struct.unpack('!12I', d)[10] - 2208988800
    print('yes' if t > 1700000000 else 'no')
except Exception:
    print('no')
PY
)"
  fi
  kv "udp 123 (ntp) out" "$ntp_ok"
  jput ntp_reachable "$ntp_ok"

  if [ "$ntp_ok" != yes ]; then
    flag "NTP IS BLOCKED. The Pi 3B has no battery-backed clock: after a power"
    flag "   cut it boots in 1970, every TLS handshake fails, and it can neither"
    flag "   reach the backend NOR log in to the portal. Fix before deploying."
  fi

  # Drift between local time and a public HTTP Date header, when NTP is blocked.
  local hdr_date
  hdr_date="$(curl -sSI -m "$CURL_TIMEOUT" https://www.cloudflare.com/ 2>/dev/null \
              | sed -n 's/^[Dd]ate: //p' | tr -d '\r')"
  [ -n "$hdr_date" ] && kv "remote http date" "$hdr_date"
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
mode_snapshot() {
  local dev; dev="$(detect_iface)"
  printf '%s%s captive-portal appraisal -- %s (%s) %s\n' \
    "$BOLD" "$LABEL" "$(now)" "$(uname -n)" "$RST"

  jput label "$LABEL"; jput timestamp "$(now)"; jput host "$(uname -n)"

  probe_link "$dev"
  probe_portal
  probe_capport "$dev"
  probe_portal_page
  probe_egress
  probe_clock

  jflush
  sec "NEXT"
  case "$NET_STATE" in
    online)
      note "Online right now. Re-run with LABEL=pre from a cold association to"
      note "see the pre-auth state, then start the soak to learn the lifetime:"
      note "  ./portal-probe.sh soak" ;;
    portal)
      note "Behind a portal. Log in by hand in a browser on this same device or"
      note "another device with the same MAC treatment, then:"
      note "  LABEL=post ./portal-probe.sh snapshot" ;;
    *)
      note "Not usable as-is. Fix the link/egress findings above first." ;;
  esac
  note "Findings written to $JSON_FILE"
}

mode_soak() {
  local dev; dev="$(detect_iface)"
  [ -f "$SOAK_LOG" ] || printf 'timestamp\tstate\tportal_url\trx_bytes\ttx_bytes\n' > "$SOAK_LOG"
  echo "soaking every ${SOAK_INTERVAL}s into $SOAK_LOG (Ctrl-C or systemd-stop to end)"
  while true; do
    PORTAL_URL=""; NET_STATE="unknown"
    probe_portal > /dev/null
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$(now)" "$NET_STATE" "${PORTAL_URL:-–}" \
      "$(cat "/sys/class/net/$dev/statistics/rx_bytes" 2>/dev/null || echo 0)" \
      "$(cat "/sys/class/net/$dev/statistics/tx_bytes" 2>/dev/null || echo 0)" \
      >> "$SOAK_LOG"
    sleep "$SOAK_INTERVAL"
  done
}

mode_report() {
  [ -f "$SOAK_LOG" ] || { echo "no soak log at $SOAK_LOG -- run 'soak' first" >&2; exit 1; }
  sec "SOAK REPORT  ($SOAK_LOG)"

  awk -F'\t' -v interval="$SOAK_INTERVAL" '
    NR == 1 { next }
    {
      state = $2; ts = $1
      total++
      count[state]++
      if (first == "") { first = ts; rx0 = $4; tx0 = $5 }
      last = ts; rx1 = $4; tx1 = $5

      if (state == "online") {
        run++
        if (run > maxrun) maxrun = run
      } else {
        if (run > 0) { runs++; sum += run; if (minrun == 0 || run < minrun) minrun = run }
        run = 0
        if (state == "portal") { drops++; droptime[drops] = ts }
      }
    }
    END {
      printf "  %-26s %s -> %s\n", "window", first, last
      printf "  %-26s %d\n", "samples", total
      for (s in count)
        printf "  %-26s %d (%.1f%%)\n", "state: " s, count[s], 100 * count[s] / total
      if (runs > 0 || run > 0) {
        printf "\n  %-26s %.1f h\n", "longest unbroken session", maxrun * interval / 3600
        if (runs > 0)
          printf "  %-26s %.1f h\n", "shortest completed session", minrun * interval / 3600
        if (runs > 0)
          printf "  %-26s %.1f h\n", "mean session", (sum / runs) * interval / 3600
      }
      printf "  %-26s %d\n", "fell back to portal", drops
      if (drops > 0) {
        printf "\n  drops at:\n"
        for (i = 1; i <= drops && i <= 12; i++) printf "    %s\n", droptime[i]
      }
      printf "\n  %-26s %.1f MB down / %.1f MB up\n", "data over window", \
             (rx1 - rx0) / 1048576, (tx1 - tx0) / 1048576
    }
  ' "$SOAK_LOG"

  note ""
  note "Read the drop times: a fixed wall-clock hour means a nightly reset, a"
  note "fixed interval means a session timer, and drops only after quiet spells"
  note "mean an idle timeout (which polling traffic alone may already defeat)."
}

JSON_GET_FILE=""

# Average daily volume across the soak window, so the request quotes a real
# number rather than a guess.
soak_mb_per_day() {
  [ -f "$SOAK_LOG" ] || { echo "<50>"; return; }
  awk -F'\t' '
    NR == 2 { rx0 = $4; tx0 = $5; t0 = $1 }
    NR > 1  { rx1 = $4; tx1 = $5; t1 = $1; n++ }
    END {
      if (n < 2) { print "<50>"; exit }
      printf "%.0f", (rx1 - rx0 + tx1 - tx0) / 1048576
    }' "$SOAK_LOG"
}

mode_request() {
  JSON_GET_FILE="$OUT_DIR/post.json"
  [ -f "$JSON_GET_FILE" ] || JSON_GET_FILE="$OUT_DIR/snapshot.json"

  local mb sessions
  mb="$(soak_mb_per_day)"
  if [ -f "$SOAK_LOG" ]; then sessions="see the attached soak report"
  else sessions="<not yet measured>"; fi

  cat <<EOF
--- copy the following to whoever runs the Wi-Fi -------------------------------

Subject: Wi-Fi exemption for an unattended wall display

We are installing a small always-on information display (a Raspberry Pi) in
<location>. It shows team photos, a shared calendar and a notice banner on a
screen on the wall. It has no keyboard and nobody logs in to it.

What it does on the network:
  * Outbound HTTPS only, to a single host: ${BACKEND_URL:-<our backend URL>}
  * One small GET every few minutes -- about ${mb} MB over the measured window.
  * No inbound connections, no local services, no access to internal systems.
  * It stores no credentials and holds no personal data.

What we found on the guest SSID $(jget ssid):
  * A captive portal at $(jget portal_final_url)
  * Login type: $(jget portal_auth_shape)
  * Session length before re-authentication: ${sessions}.

The problem: the display has no user to click through the portal. Every time the
session expires or the device reboots, the screen goes stale until someone walks
over to it.

The ask, in order of preference:
  1. Put the device on a device/IoT SSID that has no portal, or on a wired port.
  2. Add its MAC address to the portal bypass / allowlist on the guest SSID:
         MAC: $(jget mac)
     (We will pin this MAC so it never changes.)
  3. Give us a long-lived device account or voucher we can script against, and
     confirm in writing that automated re-authentication is acceptable to you.

Option 1 or 2 costs you one config entry and removes us from your guest-session
reporting entirely. We are happy with whichever fits your policy.

Also worth confirming, whichever route we take:
  * Is outbound NTP (UDP 123) permitted? The device has no battery clock and
    cannot establish HTTPS at all if it cannot set its time after a power cut.
  * Is TLS inspection applied to this SSID? Currently we see the certificate
    issued by: $(jget tls_issuer)

-------------------------------------------------------------------------------
EOF
  [ -f "$JSON_GET_FILE" ] || \
    echo "(no snapshot in $OUT_DIR -- run 'snapshot' first to fill in the blanks)" >&2
}

case "${1:-snapshot}" in
  snapshot) mode_snapshot ;;
  soak)     mode_soak ;;
  report)   mode_report ;;
  request)  mode_request ;;
  *) echo "usage: $0 {snapshot|soak|report|request}" >&2; exit 1 ;;
esac
