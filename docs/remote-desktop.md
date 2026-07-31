# Remote desktop on the board (Guacamole → tailnet → Pi)

A browser-based terminal and Chromium session on the Pi, reached from anywhere
through an existing Guacamole install. No VPN client, no port forwarding, no
inbound hole in the office firewall.

**This is not a view of the kiosk.** It is a *second* X session running beside
it. Read [Why you cannot see the wall](#why-you-cannot-see-the-wall) before
expecting otherwise — the limitation is in the hardware, not the setup.

```
browser → guac.example.com → oauth2-proxy (SSO) → guacamole → guacd
                                                                   │
                                          docker network (guacamole_default)
                                                                   ↓
                                                    vnc-relay-screendash (socat)
                                                                   │
                                        shares netns with tailscale-screendash
                                                                   ↓
                                                  tailnet (WireGuard, DERP relay)
                                                                   ↓
                                      screendash Pi :5901 — TigerVNC display :1
```

## What runs where

**On the Pi** (installed by `deploy.sh provision` when `VNC_PASSWORD` is set):

| Thing | Purpose |
|---|---|
| `tigervncserver@:1.service` | The X session on display `:1`, port 5901 |
| `~/.vnc/xstartup` | matchbox WM + one xterm. Chromium is *not* autostarted |
| `~/.vnc/tigervnc.conf` | 1366x768, depth 24, `VncAuth`, listens beyond localhost |
| `~/.vnc/passwd` | Obfuscated VNC password, mode 0600 |
| `/etc/tigervnc/vncserver.users` | Maps `:1` to the `pi` user |
| `tigervncserver@:1.service.d/override.conf` | `MemoryMax=350M` |
| `dashboard-vnc-firewall.service` | Drops 5901 from anything but `tailscale0` |

**On the Guacamole host**, two services in the compose stack (§3.6, §3.7):

- `tailscale-screendash` — a plain Tailscale client in its **own network
  namespace**. It touches neither the Docker host's networking nor any other
  container, which is the whole reason to use a sidecar instead of installing
  Tailscale on a host running dozens of services.
- `vnc-relay-screendash` — `socat`, sharing that namespace via
  `network_mode: "service:tailscale-screendash"`, forwarding `:5901` to the
  Pi's tailnet address.

`guacd` is **unmodified**. It dials `tailscale-screendash:5901` like any other
VNC backend; the sidecar's name resolves on the shared Docker network.

## Why a sidecar and not Tailscale on the host

Installing Tailscale natively on a box running many containers *usually* works —
Docker's MASQUERADE rule covers tailnet destinations like any other. But it adds
`tailscale0` to the host's root namespace, may rewrite `/etc/resolv.conf` via
MagicDNS, and becomes visible to every `network_mode: host` container. The
sidecar has none of that blast radius: its interface exists only inside its own
namespace, and the Guacamole host still reaches the Pi as an ordinary tailnet
peer — no subnet router, no static routes.

## Three traps, all of which fail silently

**1. `tailscale/tailscale` defaults to userspace networking.** Without
`TS_USERSPACE=false` there is no `tailscale0` interface and no route for
`100.64.0.0/10`. `tailscale ping` still answers — tailscaled handles it
internally — while every real TCP connection times out, because it falls
through to the default route. The symptom points at ACLs or the firewall; the
cause is the image default. Kernel TUN mode is why the container needs
`NET_ADMIN` and `/dev/net/tun`.

**2. `alpine/socat` has its own `ENTRYPOINT`.** A `command:` is *appended* as
arguments to `socat`, not substituted, giving `E exactly 2 addresses required
(there are 3)`. Pass the two addresses as the command and let the entrypoint be
`socat` — that also makes socat PID 1, so signals and restarts behave.

**3. VNC auth uses only the first 8 characters of the password.** The RFB
challenge-response uses them as a DES key. Longer passwords are silently
truncated at both ends, so a mismatch shows up as a bewildering auth failure.
`deploy.sh` rejects anything longer than 8 rather than let you discover this.

## Verifying it properly

An open port proves nothing — the relay will happily accept a connection and
forward it to a dead backend. Test at the protocol layer instead, by driving
`guacd` the way the webapp does: send `select`/`size`/`audio`/`video`/`image`/
`connect`, then look for `ready`. That is the only check that exercises TCP,
the tailnet, RFB, *and* VncAuth in one go.

A quick intermediate check, from any container on the same Docker network:

```bash
# Hold the connection open: closing stdin immediately makes some servers abort
# their WebSocket sniffing before sending the RFB banner, which looks like a
# failure but isn't.
docker run --rm --network guacamole_default --entrypoint /bin/sh alpine/socat \
  -c "(sleep 5) | socat -T6 - TCP:tailscale-screendash:5901 | head -c 12 | xxd"
# expect: RFB 003.008
```

## Security posture

- 5901 is **tailnet-only**. `dashboard-vnc-firewall.service` accepts on
  `tailscale0` and drops everything else, so nothing on the office LAN can
  reach it even though TigerVNC binds all interfaces (its systemd integration
  offers only a yes/no `$localhost`, not a bind address). **The DROP rule does
  the real work** — `INPUT` jumps to tailscaled's `ts-input` chain first and
  that chain already accepts everything on `tailscale0`, so our ACCEPT rule is
  redundant today (counter stays at 0) and is kept only so the unit states its
  intended policy on its own.
- VNC's own auth is weak (8 chars, DES) — a second factor behind the tailnet,
  not the primary control. The primary control is tailnet membership plus
  Guacamole's SSO in front. Tighten further with a Tailscale ACL restricting
  which nodes may reach 5901, rather than the default allow-all.

## Why you cannot see the wall

The obvious ask — "show me what's on the screen" — is not practical on this
hardware, and it is worth recording why so nobody re-derives it:

- `flutter-pi` is DRM master on tty1 with **no X11 or Wayland compositor**
  underneath, so `x11vnc`/`wayvnc` have nothing to attach to.
- `/dev/fb0` exists but is the **fbdev emulation buffer**, not the live
  scanout. It still holds the boot console, frozen at the moment
  `dashboard.service` started and flutter-pi took over. A VNC server pointed at
  it shows a stale boot log while looking perfectly healthy.
- `ffmpeg -f kmsgrab` *can* read the true scanout without disturbing DRM
  master, but the buffer is `DRM_FORMAT_MOD_BROADCOM_VC4_T_TILED` and nothing
  off-the-shelf detiles VC4 T-format, so the capture comes out as stripes.
  Detiling live would mean a custom detiler feeding a raw-framebuffer VNC
  server at a few frames per second on a Pi 3B. `flutter-pi` has no
  software-rendering or linear-buffer flag, and vc4 GL render targets are
  always T-tiled.

If a real view of the wall ever becomes necessary, the tractable option is not
to capture it but to run a **second instance of the dashboard** inside this VNC
session — same backend data, so it looks near-identical — at the cost of
another ~165 MB, which is why it is not the default on a 1 GB board.

## Operating it

```bash
# From the xterm in the VNC session:
chromium --window-size=1366,768 https://example.org &

systemctl status 'tigervncserver@:1'      # on the Pi
journalctl -u 'tigervncserver@:1' -n 50
```

The session is capped at 350 MB, so a runaway Chromium is OOM-killed inside its
own cgroup rather than taking the kiosk down with it. If Chromium dies
unexpectedly, that cap is the first thing to check — raise `MemoryMax` in
[deploy/dashboard-vnc-memory.conf](../deploy/dashboard-vnc-memory.conf), and
accept the trade against the wall's stability.

Restart the whole path from the server side with:

```bash
docker compose up -d tailscale-screendash vnc-relay-screendash
```

## Rebuilding from scratch

```bash
VNC_PASSWORD='8charpw' \
PI_HOST=pi@screendash \
BACKEND_URL=https://screendash.<your-subdomain>.workers.dev \
  ./deploy/deploy.sh provision
```

Then on the Guacamole host, add the two compose services and a `vnc` connection
pointing at `tailscale-screendash:5901`. The sidecar needs its own Tailscale
auth key (reusable + ephemeral is the sane choice, so it re-authenticates
across container restarts and cleans itself up if removed).
