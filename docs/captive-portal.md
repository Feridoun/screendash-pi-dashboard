# Running the dashboard behind a guest Wi-Fi captive portal

The Pi is a read-only poller with no keyboard and nobody sitting at it. A captive portal
breaks that model quietly, so before writing any automation, **measure the portal**. This
is the appraisal procedure; the renewal strategy falls out of what you find, and picking
one before you have the numbers is how you end up maintaining the wrong thing.

Tool: [deploy/portal-probe.sh](../deploy/portal-probe.sh). It only measures — it never logs
in to anything — so it is safe to run before you have permission to automate against the
network.

## Why this needs its own procedure

When the portal session lapses the dashboard does **not** go blank. Every poll is an HTTPS
GET, and a portal cannot intercept TLS without a certificate error, so the requests simply
fail and the controllers fail soft by design: the screen keeps showing the last photos, the
last calendar, the last notice. It looks completely fine and is silently hours stale.

So you cannot tell from the wall whether the network is working, and a one-off connectivity
test proves nothing — the failure is time-delayed and periodic. **Session lifetime is the
number that matters**, and it takes days to measure. (A portal that *does* MITM TLS is a
different and worse problem — see Q6.)

## Before you measure anything: pin the MAC

Do this first. Modern Raspberry Pi OS (NetworkManager) randomises the Wi-Fi MAC per
connection. Skip this and every measurement is of a *different device* as far as the portal
is concerned, making session-lifetime numbers meaningless — and any allowlist entry IT
grants you stops applying after a reboot.

```bash
sudo nmcli connection modify "<connection-name>" \
    802-11-wireless.cloned-mac-address permanent \
    802-11-wireless.mac-address-randomization 1
sudo nmcli connection down "<connection-name>" && sudo nmcli connection up "<connection-name>"
```

`portal-probe.sh snapshot` flags it if the in-use MAC still differs from the hardware MAC.
Record the pinned MAC — it is what you put in the request to IT.

## The appraisal, in order

Run it **from the Pi**. A laptop on the same SSID is a reasonable stand-in for the network
questions, but not for the clock and MAC questions, which are Pi-specific.

```bash
scp deploy/portal-probe.sh pi@dash:/home/pi/ && ssh pi@dash 'chmod +x portal-probe.sh'
```

**1 — Pre-auth snapshot**, from a freshly associated, un-authenticated state (`nmcli
connection down`/`up` first, so you aren't reusing a live session):

```bash
LABEL=pre BACKEND_URL=https://<your-backend> ./portal-probe.sh snapshot
```

**2 — Log in by hand, and capture how.** Open the portal URL the probe reported in a
desktop browser with devtools on the Network tab and *Preserve log* enabled. Click through
the login exactly as a user would, then right-click the request that performs the login →
**Copy → Copy as cURL**, and save it plus the final redirect chain next to your snapshots.

This capture is the single most valuable artifact of the whole appraisal — if the portal
turns out to be automatable, it is what you automate. Note whether the login was one POST
or a chain, and whether anything in it looks single-use (a nonce, a CSRF token, a session
id in a hidden field). Single-use values mean the automation must fetch the page and parse
them each time, not replay a fixed POST.

**3 — Post-auth snapshot**, immediately after logging in:

```bash
LABEL=post BACKEND_URL=https://<your-backend> ./portal-probe.sh snapshot
```

The `pre`/`post` diff tells you what the portal actually gates. Some gate everything; some
let DNS and NTP through pre-auth, which is good news for the clock problem below.

**4 — Soak for 48–72 hours.** The long pole, and the only way to learn session lifetime.
Start it detached so it survives your SSH session:

```bash
sudo systemd-run --unit=portal-soak --collect \
  --setenv=SOAK_INTERVAL=300 --setenv=OUT_DIR=/home/pi/portal-appraisal \
  /home/pi/portal-probe.sh soak
# ...two or three days later...
./portal-probe.sh report && sudo systemctl stop portal-soak
```

Run it **over a weekend if you can** — nightly and weekly controller resets are common and
you will miss them in a Tuesday-to-Wednesday window.

**5 — The two disruption tests**, once the soak has a baseline. They decide how the renewal
has to be triggered.

| Test | How | What it tells you |
|---|---|---|
| Re-associate | `nmcli con down` then `up` | Session survives → bound at the controller (MAC/device), not to the link |
| Full reboot | `sudo reboot` | Session survives → renewal only needs to handle timeouts, not restarts |

If the session dies on reboot, remember the Pi reboots on every power cut in the building,
unattended, possibly at 3am.

## The eight questions, and what each answer changes

**Q1 — Is there a portal, and is it a redirect or a DNS hijack?** (`PORTAL DETECTION`) A
redirect portal leaves DNS honest; a hijacking one returns the portal's address for every
name, making poll failures look like DNS failures in the logs. Affects how the renewer
detects the lapsed state.

**Q2 — Does it publish an RFC 8908 capport API?** (`CAPPORT API`) The best possible
outcome: the network hands you `seconds-remaining` as a number and renewal becomes a
scheduled job against a known deadline instead of a guess. Most portals don't implement it
— check anyway, it costs nothing.

**Q3 — What shape is the login?** (`PORTAL PAGE` → `auth shape`) Decides whether automation
is possible at all:

| Shape | Automatable unattended? |
|---|---|
| Click-through terms | Usually, with a scripted POST — but see the policy note below |
| Voucher / access code | Yes, if the code is long-lived |
| Username + password | Yes, with a device account |
| JS-built form, no `<form>` | Only with a headless browser — heavy for a Pi 3B, avoid |
| SMS / email one-time code | **No** |
| Social login / SSO | **No** |

The last two are hard stops. If you land there the appraisal's job is done: go straight to
the exemption request.

**Q4 — How long does a session last, and what kind of timeout is it?** (from `report`) Read
the drop timestamps: a fixed wall-clock hour means a nightly controller reset; a fixed
interval after each login means a hard session cap; drops only after quiet periods mean an
idle timeout, which the dashboard's own polling may already defeat for free.

**Q5 — Is the session bound to the MAC, a cookie, or the association?** (step-5 tests)
MAC-bound is easiest; cookie-bound means the renewer must persist a cookie jar across
reboots.

**Q6 — Is TLS being intercepted?** (`backend cert issuer` in `EGRESS`) If the issuer is a
firewall vendor rather than a public CA, the Pi needs their root CA installed or the backend
host exempted from inspection. Raise it early — it is a policy conversation, not a config
change.

**Q7 — Is outbound NTP permitted?** (`CLOCK`) A genuine deployment blocker specific to this
device. **The Pi 3B has no battery-backed clock.** After a power cut it boots believing it
is 1970, every TLS handshake fails certificate validation, and it can reach neither the
backend *nor* an HTTPS portal to fix itself. In order of preference: get UDP 123 allowed
(ask in the same request as the exemption); keep `fake-hwclock` enabled (it is by default)
so the clock resumes near the last known time rather than 1970; or add a DS3231 RTC (~£5),
the reliable fix for an unattended device in a building whose power you don't control.

**Q8 — What does it cost in data, and is there a cap?** (`data over window`) Guest networks
sometimes impose a per-device daily cap that silently throttles you. The number also goes
in the request to IT, where "about 40 MB a day" is a much easier ask than an unquantified one.

## Choosing the renewal strategy

Work down this list and stop at the first one available. The order is by long-term
maintenance cost, not by effort to build.

**A — Get the device off the portal entirely.** A device/IoT SSID, a wired port, or a MAC
bypass entry on the guest SSID. One config line for IT, nothing to maintain, nothing to
break at 3am, and no automated acceptance of terms on the organisation's behalf. This is
the right answer often enough that the appraisal's main output is the evidence to ask for
it — `./portal-probe.sh request` writes the ask, pre-filled from your snapshot.

**B — capport-driven renewal.** Only if Q2 said yes. Poll the API, re-auth when
`seconds-remaining` gets low.

**C — Scheduled re-auth against a known session length.** A systemd timer replaying the
captured login well inside the measured lifetime, plus a watchdog that re-auths on demand
when a probe says `portal`. The realistic fallback for a click-through or credentialed portal.

**D — Headless-browser re-auth.** For JS-built portals. On a Pi 3B with 1 GB, running
Chromium alongside the dashboard is a real memory risk. Last resort.

**E — Not automatable.** SMS/social portals. Escalate; there is no device-side fix.

Whichever you land on, **the renewer belongs in its own systemd unit, not in the Flutter
app.** The app's job is to poll and fail soft; the network's job is to be there. Keeping
them separate means a portal change can't take the display down, and you can restart one
without the other.

**One policy note:** strategies B, C and D involve a device accepting the network's terms of
use automatically, on the organisation's behalf, with nobody reading them. That is a
question for whoever owns the network, worth asking explicitly rather than assuming — the
request template raises it as point 3. It is also a good argument for strategy A.

## Reporting what you found

```bash
./portal-probe.sh report     # session lifetime, drop pattern, data volume
./portal-probe.sh request    # the ask, pre-filled from the post-auth snapshot
```

Fill in the `<location>` placeholder, check the backend URL, and send it with the soak
report attached. Everything in it is drawn from measurements you took, which is why the
appraisal comes first: *"your portal drops us every 4 hours, here is the log, here is our
MAC"* gets a config change, and *"the Wi-Fi keeps disconnecting"* gets a ticket closed as
no-fault.

## Once it is working: keep watching

The portal will change without telling you — a controller upgrade, a new terms page, a
shortened session cap. Leave a low-frequency soak running permanently
(`SOAK_INTERVAL=1800`) so that when the screen goes stale you can answer "since when" in
one command instead of guessing.

Outputs land in `~/portal-appraisal/`: `pre.json` and `post.json` (machine-readable
snapshots), `post-portal.html` (the saved portal page, for fingerprinting), and `soak.tsv`
(the session-lifetime log).
