# Tailnet security: a board on a public wall

The board is a Raspberry Pi in a corridor anyone can walk down, and it is on a
tailnet so it can be reached from a home network. This documents what that does
and does not expose, and the four controls that keep the trade acceptable.

## What Tailscale exposes, and what it does not

A tailnet node does not bridge networks. Joining gives the Pi a WireGuard
interface and a route for `100.64.0.0/10` — nothing else. **Your home LAN is not
reachable from the board**, and nothing on the office LAN can hop through it.

Two things would change that, and neither is configured here:

| | What it takes | Where it stands |
|---|---|---|
| **Subnet routes** | a node running `--advertise-routes` *and* the Pi running `--accept-routes` | the Pi passes `--accept-routes=false` explicitly ([system_ops.dart](../lib/services/system_ops.dart)) |
| **Exit node** | the Pi running `--exit-node=…` | never set |

Verify on the device — both should come back empty:

```bash
ip route | grep -v 100.100.100 | grep 100.      # installed tailnet subnet routes
tailscale status --json | jq '.Self.ExitNodeOption, .Peer[].PrimaryRoutes'
```

What *is* exposed is **every other node on the tailnet**. A new tailnet's default
policy is `src: ["*"] → dst: ["*:*"]`, so whoever owns the board can reach your
dev box, the Guacamole host, and anything else you have joined, on every port,
plus enumerate them all over MagicDNS. For most people that is a better prize
than the LAN. That is the risk this document is about.

Assume the board itself is lost the moment someone takes it: physical access to
a Pi is root access (pull the SD card, edit `/etc/shadow`, boot).
`/etc/sudoers.d/010_pi-nopasswd` makes it quicker but is not what decides it.
The goal below is **containment, not prevention**.

## 1. The ACL — the control that actually matters

[deploy/tailscale-acl.json](../deploy/tailscale-acl.json) replaces the
allow-everything default. It names `tag:kiosk` only as a *destination*: nothing
anywhere lists it as a source, so a stolen board can open a connection to
nothing on the tailnet. Save it under **Access controls** in the admin console,
then re-authenticate the Pi so it actually lands in the tag:

```bash
sudo tailscale up --advertise-tags=tag:kiosk --ssh --accept-routes=false
```

The hidden admin panel passes `--advertise-tags` for you when it joins. **An
untagged board is covered by none of this** — check the Machines page for the tag
after you apply the policy.

This costs the board nothing it uses. Tailnet ACLs govern tailnet traffic only;
ordinary internet access to the Worker origin is untouched.

## 2. The bundle is no longer world-readable

[deploy.sh](../deploy/deploy.sh) can bake a Tailscale auth key into the app
bundle, so a stranded board can be brought onto the tailnet without anyone typing
60 characters on a touchscreen. That was a hole with no device access required at
all, because the read path was entirely anonymous:

```
GET /version.json  →  bundle_url  →  tar xzf  →  strings | grep tskey-auth-
```

`/bundles/*` now requires a bearer token ([worker/src/serve.js](../worker/src/serve.js)).
Everything else — the JSON artifacts, the photos — stays public as before; the
bundle is the only object that can carry a secret.

**Generate the token and set it in both places:**

```bash
openssl rand -hex 32
(cd worker && npx wrangler secret put DEVICE_TOKEN)
```

The device half lives in `/etc/default/dashboard-update`, mode `0600 root:root`,
written by `deploy.sh provision`. systemd reads it as root before dropping to
`User=pi`, and [update.sh](../deploy/update.sh) passes it to curl through a
`0600` header file rather than a `-H` flag, because `/proc/<pid>/cmdline` is
world-readable.

### Rollout order on a live board

The Worker fails **closed**: with no `DEVICE_TOKEN` configured, bundle requests
get a `503` and a line in `wrangler tail`. Serving bundles publicly whenever the
secret happens to be missing would silently reopen the hole, so the failure mode
is paused updates instead — the board keeps running the version it has.

Do it in this order, or the board stops updating until you catch up:

1. `wrangler secret put DEVICE_TOKEN` — the currently deployed Worker ignores it.
2. Get the token onto the Pi (needs SSH or the tailnet):
   `DEVICE_TOKEN=… ./deploy/deploy.sh provision`
3. `npx wrangler deploy` — the gate goes live.

To confirm the hole is closed, from anywhere:

```bash
curl -sI "$BACKEND_URL/bundles/$(curl -s "$BACKEND_URL/version.json" | jq -r .version).tar.gz"
# expect 404 — anonymous callers cannot even confirm the version exists
```

Then check the device took an update: `journalctl -u dashboard-update -n 30`.

## 3. Auth keys

Generate the key **tagged `tag:kiosk`**, reusable-OFF, ephemeral-OFF, short
expiry — and revoke it once the board has joined.

- **Tagged** is the one that matters: it is what puts the node under the policy
  above. A tagged key can only ever create `tag:kiosk` nodes, so a leaked one
  adds a contained node rather than a free-roaming one.
- **Ephemeral OFF.** The board is a permanent node; an ephemeral one
  deregisters itself the first time it is powered off overnight.
- `deploy.sh publish` prints a revoke reminder whenever `TAILSCALE_AUTHKEY` was
  baked in, because the key stays in that bundle for as long as the bundle
  exists.

## 4. Expiry, and how to revoke a board

Note the trade honestly: **Tailscale disables key expiry on tagged devices by
default.** Tagging is still the right call — a wall display that needs
re-authentication after a month offline is a display someone has to physically
visit — and the ACL is what makes a long-lived node key nearly worthless. What it
means is that expiry is not your revocation story:

- If a board goes missing, **remove the device** in the admin console. That is
  the revocation, and it takes effect in seconds.
- Re-enable key expiry per-device in the console if you would rather have both.

## 5. Tailscale SSH

`tailscale up --ssh` on the device is fine under this policy. Tailscale SSH is a
separate gate from the `acls` block and denies by default until an `ssh` rule
exists; the policy file grants it to `autogroup:member` for the `pi` user only.
Plain OpenSSH on port 22 — what `deploy.sh provision` drives — is governed by the
`acls` block instead. Both paths are wanted, which is why both appear.

`--shields-up` is *not* the answer here, despite sounding like it: it blocks
inbound connections, which is exactly the access you are trying to keep.

## Summary

| Control | Where | Stops |
|---|---|---|
| Kiosk ACL, no rule with `tag:kiosk` as source | [deploy/tailscale-acl.json](../deploy/tailscale-acl.json) | a stolen board pivoting to any other node |
| `--accept-routes=false`, no exit node | [system_ops.dart](../lib/services/system_ops.dart) | any LAN appearing behind the board |
| `DEVICE_TOKEN` on `/bundles/*` | [worker/src/serve.js](../worker/src/serve.js) | anyone downloading the app and reading baked-in secrets |
| Tagged, short-expiry, revoked auth keys | [deploy.sh](../deploy/deploy.sh) | a leaked key joining an unconstrained node |
| VNC restricted to `tailscale0` | [dashboard-vnc-firewall.service](../deploy/dashboard-vnc-firewall.service) | the office LAN reaching the admin desktop |
