import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';

/// Read-only diagnostics plus a few narrow recovery actions, driven from the
/// hidden admin panel ([lib/ui/admin_panel.dart]).
///
/// Why this exists: the board is a wall-mounted display with no keyboard, and
/// the flutter-pi kiosk holds the console so a physical VT switch can't reach a
/// shell. When it lands on a network we can't SSH into (a new site, a captive
/// portal, a tether whose IP we can't guess), the *app itself* is the only way
/// in — and the app can already reach the backend, so it can also report its
/// own network state and run a handful of `nmcli`/`tailscale` commands to get
/// us a remote shell. See docs/captive-portal.md and the deploy README.
///
/// Everything here fails soft. Off-Pi (dev host) the binaries are absent and
/// every call returns a friendly "unavailable" rather than throwing — the wall
/// must never crash because a diagnostic command isn't installed.
///
/// Privileged actions go through `sudo -n` and the narrow rules in
/// deploy/dashboard-admin.sudoers, mirroring [PowerService]. `nmcli` needs no
/// sudo: the `pi` user manages Wi-Fi via polkit/netdev.
class SystemOps {
  const SystemOps();

  /// Hard ceiling on any single command. A hung `tailscale up` (waiting on a
  /// login that will never come) must not wedge the panel.
  static const Duration _timeout = Duration(seconds: 25);

  // --- primitive ------------------------------------------------------------
  /// Run [exe] [args] and capture output, never throwing. [timeout] overrides
  /// the default for slow actions (install, tailscale up).
  Future<_Run> _run(
    String exe,
    List<String> args, {
    Duration? timeout,
  }) async {
    try {
      final p = await Process.start(exe, args, runInShell: false);
      final out = StringBuffer();
      final err = StringBuffer();
      final outDone = p.stdout.transform(utf8.decoder).forEach(out.write);
      final errDone = p.stderr.transform(utf8.decoder).forEach(err.write);

      final code = await p.exitCode.timeout(
        timeout ?? _timeout,
        onTimeout: () {
          p.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      await Future.wait([outDone, errDone]).catchError((_) => <void>[]);
      return _Run(code, out.toString().trim(), err.toString().trim());
    } catch (e) {
      // ENOENT (binary missing on a dev host) lands here.
      return _Run(-1, '', '$e');
    }
  }

  // --- diagnostics (Tier 1) -------------------------------------------------
  /// Gather everything that helps someone standing at the board decide *how to
  /// get in*: its addresses, the network it's on, and whether SSH / Tailscale
  /// are already usable. All read-only.
  Future<Diagnostics> diagnostics() async {
    // Run the independent probes concurrently; each is cheap and read-only.
    final results = await Future.wait([
      _run('hostname', []), // 0
      _run('ip', ['-o', '-4', 'addr', 'show', 'scope', 'global']), // 1
      _run('ip', ['-4', 'route', 'show', 'default']), // 2
      _run('iwgetid', ['-r']), // 3  current SSID
      _run('systemctl', ['is-active', 'ssh']), // 4
      _run('tailscale', ['ip', '-4']), // 5
      _run('tailscale', ['status']), // 6
      _run('sudo', ['-n', 'true']), // 7  passwordless-sudo probe
      _run('date', ['-u', '+%Y-%m-%dT%H:%M:%SZ']), // 8
      _run('timedatectl', ['show', '-p', 'NTPSynchronized', '--value']), // 9
    ]);

    final addrs = <String>[];
    for (final line in const LineSplitter().convert(results[1].out)) {
      // `ip -o -4 addr` line: "<idx>: <iface>  inet <cidr> ..."
      final parts = line.split(RegExp(r'\s+'));
      final i = parts.indexOf('inet');
      if (i != -1 && i + 1 < parts.length && parts.length > 1) {
        addrs.add('${parts[1]}  ${parts[i + 1]}');
      }
    }

    final gateway = () {
      final m = RegExp(r'default via (\S+) dev (\S+)').firstMatch(results[2].out);
      return m == null ? '' : '${m.group(1)} (${m.group(2)})';
    }();

    final tsIps = results[5].ok ? results[5].out : '';
    final tsOnline = tsIps.isNotEmpty &&
        !results[6].out.toLowerCase().contains('stopped') &&
        !results[6].out.toLowerCase().contains('logged out');

    return Diagnostics(
      hostname: results[0].ok ? results[0].out : 'unknown',
      addresses: addrs,
      gateway: gateway,
      ssid: results[3].ok && results[3].out.isNotEmpty ? results[3].out : null,
      sshActive: results[4].out == 'active',
      tailscaleIps: tsIps,
      tailscaleOnline: tsOnline,
      tailscaleInstalled: results[5].code != -1 || results[6].code != -1,
      sudoReady: results[7].ok,
      utcNow: results[8].ok ? results[8].out : DateTime.now().toUtc().toIso8601String(),
      ntpSynced: results[9].out == 'yes',
    );
  }

  // --- Wi-Fi (Tier 2) -------------------------------------------------------
  /// SSIDs currently in range, strongest first. Empty on a dev host.
  Future<List<WifiNetwork>> scanWifi() async {
    // Ask for a rescan first so a network that appeared after boot shows up.
    await _run('nmcli', ['device', 'wifi', 'rescan'], timeout: const Duration(seconds: 12));
    final r = await _run(
      'nmcli',
      ['-t', '-f', 'SSID,SIGNAL,SECURITY', 'device', 'wifi', 'list'],
    );
    if (!r.ok) return const [];

    final seen = <String>{};
    final nets = <WifiNetwork>[];
    for (final line in const LineSplitter().convert(r.out)) {
      // Fields are ':'-separated; nmcli escapes literal ':' in an SSID as '\:'.
      final fields = _splitNmcli(line);
      if (fields.isEmpty) continue;
      final ssid = fields[0];
      if (ssid.isEmpty || !seen.add(ssid)) continue; // drop blanks + dupes
      final signal = fields.length > 1 ? int.tryParse(fields[1]) ?? 0 : 0;
      final security = fields.length > 2 ? fields[2] : '';
      nets.add(WifiNetwork(ssid: ssid, signal: signal, open: security.isEmpty));
    }
    nets.sort((a, b) => b.signal.compareTo(a.signal));
    return nets;
  }

  /// Join [ssid]. Returns an outcome message suitable for showing on screen.
  ///
  /// Note the single-radio reality: on the Pi 3B this drops whatever Wi-Fi
  /// (or hotspot tether does not use the radio) you were on. The caller warns
  /// about this before invoking.
  Future<ActionResult> connectWifi(String ssid, String password) async {
    final args = ['device', 'wifi', 'connect', ssid];
    if (password.isNotEmpty) args.addAll(['password', password]);
    final r = await _run('nmcli', args, timeout: const Duration(seconds: 40));
    if (r.ok) return ActionResult.ok('Joined “$ssid”.');
    // nmcli prints the useful part on stderr.
    final why = r.err.isNotEmpty ? r.err : r.out;
    return ActionResult.fail(why.isEmpty ? 'Could not join “$ssid”.' : why);
  }

  // --- Tailscale (Tier 3) ---------------------------------------------------
  /// Bring the device onto the tailnet non-interactively with a pre-auth key,
  /// installing Tailscale first if it isn't present. This is the clean path to
  /// a durable remote shell: once it's up, SSH to the device's 100.x address.
  ///
  /// [authKey] is a single-use `tskey-auth-…`. It is never logged.
  Future<ActionResult> joinTailscale(String authKey) async {
    if (authKey.isEmpty) {
      return ActionResult.fail('No auth key supplied.');
    }

    // Install on demand. The installer is idempotent and quick on a warm apt
    // cache; give it a generous window because it may hit the network.
    final present = (await _run('tailscale', ['version'])).code != -1;
    if (!present) {
      final install = await _run(
        'sh',
        ['-c', 'curl -fsSL https://tailscale.com/install.sh | sudo -n sh'],
        timeout: const Duration(minutes: 3),
      );
      if (install.code != 0) {
        return ActionResult.fail(
          'Tailscale install failed. ${_tail(install.err.isEmpty ? install.out : install.err)}',
        );
      }
    }

    // --accept-routes=false is stated rather than assumed: it is the default,
    // but `tailscale up` persists flags from previous runs, and this is the one
    // flag that decides whether the board installs subnet routes advertised by
    // other nodes — i.e. whether someone else's LAN appears behind a device on
    // a public wall. See docs/tailnet-security.md.
    List<String> args({required bool tagged}) => [
          '-n',
          'tailscale',
          'up',
          '--authkey=$authKey',
          '--ssh',
          '--hostname=screendash',
          '--accept-routes=false',
          if (tagged) '--advertise-tags=${AppConfig.tailscaleTag}',
        ];

    final wantTag = AppConfig.tailscaleTag.isNotEmpty;
    var up = await _run('sudo', args(tagged: wantTag), timeout: const Duration(seconds: 60));

    // A tagged join is refused outright if the policy file has no tagOwners
    // entry for the tag, or the key's owner may not apply it. That must not
    // strand a board we are using this panel to recover, so retry untagged —
    // and say so in the result, because untagged means the containment policy
    // in deploy/tailscale-acl.json does not cover this node.
    var untagged = false;
    if (up.code != 0 && wantTag) {
      final retry = await _run('sudo', args(tagged: false), timeout: const Duration(seconds: 60));
      if (retry.code == 0) {
        up = retry;
        untagged = true;
      }
    }
    if (up.code != 0) {
      return ActionResult.fail('tailscale up failed. ${_tail(up.err.isEmpty ? up.out : up.err)}');
    }

    final ip = await _run('tailscale', ['ip', '-4']);
    final addr = ip.ok ? ip.out.split('\n').first : '(check the admin console)';
    if (untagged) {
      return ActionResult.ok(
        'On the tailnet as an UNTAGGED node — ${AppConfig.tailscaleTag} was refused, '
        'so the kiosk ACL does not cover it. SSH to  pi@$addr  and re-join with a '
        'tagged key once the policy is saved.',
      );
    }
    return ActionResult.ok('On the tailnet. SSH to  pi@$addr');
  }

  // --- last-resort local access (Tier 4) ------------------------------------
  /// Stop the kiosk service, which releases the console VT so a physical
  /// Ctrl+Alt+F2 finally reaches a login. Risky by design — if the keyboard is
  /// also misbehaving you've now lost the screen with no shell — so the caller
  /// gates it behind an explicit two-step confirm.
  Future<ActionResult> stopKiosk() async {
    final r = await _run('sudo', ['-n', 'systemctl', 'stop', 'dashboard.service']);
    // If it worked we're about to be SIGTERMed, so this reply may never render.
    return r.ok
        ? ActionResult.ok('Stopping the kiosk…')
        : ActionResult.fail(r.err.isEmpty ? 'Stop failed.' : r.err);
  }

  // --- helpers --------------------------------------------------------------
  @visibleForTesting
  static List<String> splitNmcliLine(String line) => _splitNmcli(line);

  /// nmcli `-t` escapes ':' inside fields as '\:'. Split on unescaped colons.
  static List<String> _splitNmcli(String line) {
    final out = <String>[];
    final buf = StringBuffer();
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '\\' && i + 1 < line.length) {
        buf.write(line[++i]);
      } else if (c == ':') {
        out.add(buf.toString());
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    out.add(buf.toString());
    return out;
  }

  /// Keep an error message short enough for a touch panel.
  static String _tail(String s, [int max = 160]) {
    final one = s.replaceAll('\n', ' ').trim();
    return one.length <= max ? one : '…${one.substring(one.length - max)}';
  }
}

/// Result of a captured command run.
class _Run {
  const _Run(this.code, this.out, this.err);
  final int code;
  final String out;
  final String err;
  bool get ok => code == 0;
}

/// A point-in-time snapshot of how to reach this device.
@immutable
class Diagnostics {
  const Diagnostics({
    required this.hostname,
    required this.addresses,
    required this.gateway,
    required this.ssid,
    required this.sshActive,
    required this.tailscaleIps,
    required this.tailscaleOnline,
    required this.tailscaleInstalled,
    required this.sudoReady,
    required this.utcNow,
    required this.ntpSynced,
  });

  final String hostname;

  /// "iface  a.b.c.d/nn" per global IPv4 address. This is the line that tells
  /// you the tether/Wi-Fi IP to SSH to when Tailscale isn't up yet.
  final List<String> addresses;
  final String gateway;
  final String? ssid;
  final bool sshActive;
  final String tailscaleIps;
  final bool tailscaleOnline;
  final bool tailscaleInstalled;

  /// Whether `sudo -n` runs without a password — i.e. whether the Tailscale /
  /// stop-kiosk actions can work at all. Shown so a failure isn't a mystery.
  final bool sudoReady;
  final String utcNow;
  final bool ntpSynced;
}

class WifiNetwork {
  const WifiNetwork({required this.ssid, required this.signal, required this.open});
  final String ssid;
  final int signal; // 0..100
  final bool open;
}

/// Outcome of an action, for display. [ok] drives colour; [message] is shown.
@immutable
class ActionResult {
  const ActionResult._(this.ok, this.message);
  const ActionResult.ok(String message) : this._(true, message);
  const ActionResult.fail(String message) : this._(false, message);
  final bool ok;
  final String message;
}
