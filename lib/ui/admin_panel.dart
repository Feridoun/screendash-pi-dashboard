import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../services/system_ops.dart';
import 'theme.dart';

/// A hidden, full-screen recovery console for when the board lands on a network
/// we can't SSH into. Reached by a long-press in the top-left corner of the
/// dashboard (see DashboardScreen). Deliberately not discoverable by accident —
/// it exposes Wi-Fi and Tailscale controls, not something a passer-by should hit.
///
/// Three tiers, in the order you actually use them:
///   1. Diagnostics — the board's own IPs, so you can SSH to it over whatever
///      link it's on right now (tether, hotspot) without guessing the subnet.
///   2. Wi-Fi — join a network from the wall.
///   3. Tailscale — join the tailnet with the baked-in auth key for a durable
///      remote shell. This is usually the goal.
///
/// Everything fails soft; on a dev host the commands are simply "unavailable".
class AdminPanel extends StatefulWidget {
  const AdminPanel({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AdminPanel(), fullscreenDialog: true),
    );
  }

  @override
  State<AdminPanel> createState() => _AdminPanelState();
}

class _AdminPanelState extends State<AdminPanel> {
  static const _ops = SystemOps();

  Diagnostics? _diag;
  bool _loadingDiag = true;

  @override
  void initState() {
    super.initState();
    _refreshDiag();
  }

  Future<void> _refreshDiag() async {
    setState(() => _loadingDiag = true);
    final d = await _ops.diagnostics();
    if (!mounted) return;
    setState(() {
      _diag = d;
      _loadingDiag = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DashTheme.bg,
      appBar: AppBar(
        backgroundColor: DashTheme.surface,
        foregroundColor: DashTheme.ink,
        title: Row(
          children: [
            Icon(Icons.terminal, color: DashTheme.accent, size: 26),
            const SizedBox(width: 12),
            Text(
              'ADMIN',
              style: TextStyle(
                color: DashTheme.accent,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: 4,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loadingDiag ? null : _refreshDiag,
          ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
          children: [
            _DiagnosticsCard(diag: _diag, loading: _loadingDiag),
            const SizedBox(height: 20),
            _TailscaleCard(ops: _ops, diag: _diag, onChanged: _refreshDiag),
            const SizedBox(height: 20),
            _WifiCard(ops: _ops, onChanged: _refreshDiag),
            const SizedBox(height: 20),
            _StopKioskCard(ops: _ops),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared card chrome
// ---------------------------------------------------------------------------
class _Card extends StatelessWidget {
  const _Card({required this.icon, required this.title, required this.child, this.trailing});
  final IconData icon;
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: DashTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: DashTheme.line),
      ),
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: DashTheme.accent, size: 24),
              const SizedBox(width: 12),
              Text(
                title,
                style: TextStyle(
                  color: DashTheme.ink,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
              const Spacer(),
              ?trailing,
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

/// A pill that reflects a boolean state (green/amber-red).
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.good});
  final String label;
  final bool good;

  @override
  Widget build(BuildContext context) {
    final color = good ? DashTheme.online : DashTheme.offline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 1),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tier 1 — diagnostics
// ---------------------------------------------------------------------------
class _DiagnosticsCard extends StatelessWidget {
  const _DiagnosticsCard({required this.diag, required this.loading});
  final Diagnostics? diag;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return _Card(
      icon: Icons.lan_outlined,
      title: 'HOW TO REACH THIS BOARD',
      trailing: loading
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: DashTheme.inkFaint),
            )
          : null,
      child: diag == null
          ? Text(
              loading ? 'Reading network state…' : 'Diagnostics unavailable (dev host?).',
              style: TextStyle(color: DashTheme.inkFaint, fontSize: 16),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (diag!.addresses.isEmpty)
                  _kv('Addresses', 'none — not on any network')
                else
                  ...diag!.addresses.map((a) => _kv('Address', a, mono: true)),
                _kv('Gateway', diag!.gateway.isEmpty ? '—' : diag!.gateway, mono: true),
                _kv('Wi-Fi SSID', diag!.ssid ?? '— (wired / tether / none)'),
                _kv('Hostname', diag!.hostname, mono: true),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _StatusPill(label: diag!.sshActive ? 'SSH ON' : 'SSH OFF', good: diag!.sshActive),
                    _StatusPill(
                      label: diag!.tailscaleOnline
                          ? 'TAILSCALE UP'
                          : diag!.tailscaleInstalled
                              ? 'TAILSCALE DOWN'
                              : 'NO TAILSCALE',
                      good: diag!.tailscaleOnline,
                    ),
                    _StatusPill(label: diag!.sudoReady ? 'SUDO OK' : 'NO SUDO', good: diag!.sudoReady),
                    _StatusPill(label: diag!.ntpSynced ? 'CLOCK SYNCED' : 'CLOCK UNSYNCED', good: diag!.ntpSynced),
                  ],
                ),
                if (diag!.tailscaleIps.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _kv('Tailscale IP', diag!.tailscaleIps.split('\n').first, mono: true),
                ],
                const SizedBox(height: 10),
                Text(
                  diag!.tailscaleOnline
                      ? 'Reachable over Tailscale. SSH to the 100.x address above.'
                      : diag!.addresses.isNotEmpty
                          ? 'No Tailscale yet — SSH to an address above from a device on the same network, or bring up Tailscale below.'
                          : 'Get it onto a network first (Wi-Fi below, or a USB tether).',
                  style: TextStyle(color: DashTheme.inkFaint, fontSize: 15, height: 1.4),
                ),
              ],
            ),
    );
  }

  Widget _kv(String k, String v, {bool mono = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(k, style: TextStyle(color: DashTheme.inkFaint, fontSize: 15)),
          ),
          Expanded(
            child: SelectableText(
              v,
              style: TextStyle(
                color: DashTheme.ink,
                fontSize: 16,
                fontFeatures: mono ? const [FontFeature.tabularFigures()] : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tier 3 — Tailscale (placed above Wi-Fi: it's the usual goal)
// ---------------------------------------------------------------------------
class _TailscaleCard extends StatefulWidget {
  const _TailscaleCard({required this.ops, required this.diag, required this.onChanged});
  final SystemOps ops;
  final Diagnostics? diag;
  final VoidCallback onChanged;

  @override
  State<_TailscaleCard> createState() => _TailscaleCardState();
}

class _TailscaleCardState extends State<_TailscaleCard> {
  final _keyField = TextEditingController(text: AppConfig.tailscaleAuthKey);
  // Obscured by default -- the board hangs in a public corridor. But this is a
  // RECOVERY panel on a device with no clipboard, so a key you cannot read back
  // is a key you cannot correct: a single mistyped character returns nothing but
  // "key does not exist". Reveal is opt-in and momentary.
  bool _showKey = false;
  bool _busy = false;
  ActionResult? _result;

  @override
  void dispose() {
    _keyField.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final key = _keyField.text.trim();
    if (key.isEmpty) {
      setState(() => _result = const ActionResult.fail('Paste a tskey-auth-… key first.'));
      return;
    }
    setState(() {
      _busy = true;
      _result = null;
    });
    final r = await widget.ops.joinTailscale(key);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = r;
    });
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final already = widget.diag?.tailscaleOnline ?? false;
    final baked = AppConfig.tailscaleAuthKey.isNotEmpty;

    return _Card(
      icon: Icons.hub_outlined,
      title: 'REMOTE ACCESS (TAILSCALE)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            already
                ? 'Already on the tailnet. Re-running is harmless.'
                : 'Bring this board onto your tailnet for a durable remote shell.',
            style: TextStyle(color: DashTheme.inkFaint, fontSize: 15, height: 1.4),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _keyField,
            obscureText: !_showKey,
            style: TextStyle(color: DashTheme.ink, fontSize: 15),
            decoration: InputDecoration(
              labelText: baked ? 'Auth key (baked in at build)' : 'Paste auth key (tskey-auth-…)',
              labelStyle: TextStyle(color: DashTheme.inkFaint),
              suffixIcon: IconButton(
                icon: Icon(
                  _showKey ? Icons.visibility_off : Icons.visibility,
                  color: DashTheme.inkFaint,
                ),
                tooltip: _showKey ? 'Hide key' : 'Show key',
                onPressed: () => setState(() => _showKey = !_showKey),
              ),
              filled: true,
              fillColor: DashTheme.surfaceAlt,
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: DashTheme.line),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: DashTheme.accent),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _join,
                style: FilledButton.styleFrom(
                  backgroundColor: DashTheme.accent,
                  foregroundColor: DashTheme.bg,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                ),
                icon: _busy
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.login),
                label: Text(_busy ? 'Joining…' : 'Join tailnet', style: const TextStyle(fontSize: 17)),
              ),
            ],
          ),
          if (_result != null) ...[
            const SizedBox(height: 14),
            _ResultLine(result: _result!),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tier 2 — Wi-Fi
// ---------------------------------------------------------------------------
class _WifiCard extends StatefulWidget {
  const _WifiCard({required this.ops, required this.onChanged});
  final SystemOps ops;
  final VoidCallback onChanged;

  @override
  State<_WifiCard> createState() => _WifiCardState();
}

class _WifiCardState extends State<_WifiCard> {
  List<WifiNetwork>? _nets;
  bool _scanning = false;
  WifiNetwork? _selected;
  final _pwField = TextEditingController();
  bool _showPw = false;
  bool _connecting = false;
  ActionResult? _result;

  @override
  void dispose() {
    _pwField.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _result = null;
    });
    final nets = await widget.ops.scanWifi();
    if (!mounted) return;
    setState(() {
      _nets = nets;
      _scanning = false;
    });
  }

  Future<void> _connect() async {
    final net = _selected;
    if (net == null) return;
    setState(() {
      _connecting = true;
      _result = null;
    });
    final r = await widget.ops.connectWifi(net.ssid, _pwField.text);
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _result = r;
    });
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return _Card(
      icon: Icons.wifi,
      title: 'WI-FI',
      trailing: TextButton.icon(
        onPressed: _scanning ? null : _scan,
        icon: _scanning
            ? SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: DashTheme.inkFaint))
            : Icon(Icons.wifi_find, color: DashTheme.accent, size: 20),
        label: Text(_scanning ? 'Scanning…' : 'Scan', style: TextStyle(color: DashTheme.accent)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'One radio: joining a network drops the current Wi-Fi link. Do this '
            'while you still have another way in (tether, keyboard).',
            style: TextStyle(color: DashTheme.offline, fontSize: 14, height: 1.4),
          ),
          const SizedBox(height: 14),
          if (_nets == null)
            Text('Tap Scan to list networks.', style: TextStyle(color: DashTheme.inkFaint, fontSize: 15))
          else if (_nets!.isEmpty)
            Text('No networks found (or no Wi-Fi on this host).',
                style: TextStyle(color: DashTheme.inkFaint, fontSize: 15))
          else
            ...(_nets!.take(12).map((n) => _NetRow(
                  net: n,
                  selected: _selected?.ssid == n.ssid,
                  onTap: () => setState(() {
                    _selected = n;
                    _result = null;
                  }),
                ))),
          if (_selected != null) ...[
            const SizedBox(height: 14),
            if (!_selected!.open)
              TextField(
                controller: _pwField,
                obscureText: !_showPw,
                style: TextStyle(color: DashTheme.ink),
                decoration: InputDecoration(
                  labelText: 'Password for “${_selected!.ssid}”',
                  labelStyle: TextStyle(color: DashTheme.inkFaint),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _showPw ? Icons.visibility_off : Icons.visibility,
                      color: DashTheme.inkFaint,
                    ),
                    tooltip: _showPw ? 'Hide password' : 'Show password',
                    onPressed: () => setState(() => _showPw = !_showPw),
                  ),
                  filled: true,
                  fillColor: DashTheme.surfaceAlt,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: DashTheme.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: DashTheme.accent),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _connecting ? null : _connect,
              style: FilledButton.styleFrom(
                backgroundColor: DashTheme.accent,
                foregroundColor: DashTheme.bg,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              ),
              icon: _connecting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_tethering),
              label: Text(_connecting ? 'Joining…' : 'Join “${_selected!.ssid}”'),
            ),
          ],
          if (_result != null) ...[
            const SizedBox(height: 14),
            _ResultLine(result: _result!),
          ],
        ],
      ),
    );
  }
}

class _NetRow extends StatelessWidget {
  const _NetRow({required this.net, required this.selected, required this.onTap});
  final WifiNetwork net;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? DashTheme.accent.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? DashTheme.accent : Colors.transparent),
        ),
        child: Row(
          children: [
            Icon(
              net.signal >= 60 ? Icons.wifi : (net.signal >= 30 ? Icons.wifi_2_bar : Icons.wifi_1_bar),
              size: 20,
              color: DashTheme.inkSoft,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(net.ssid, style: TextStyle(color: DashTheme.ink, fontSize: 16)),
            ),
            Icon(
              net.open ? Icons.lock_open : Icons.lock_outline,
              size: 16,
              color: DashTheme.inkFaint,
            ),
            const SizedBox(width: 10),
            Text('${net.signal}%', style: TextStyle(color: DashTheme.inkFaint, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tier 4 — stop kiosk (last resort)
// ---------------------------------------------------------------------------
class _StopKioskCard extends StatefulWidget {
  const _StopKioskCard({required this.ops});
  final SystemOps ops;

  @override
  State<_StopKioskCard> createState() => _StopKioskCardState();
}

class _StopKioskCardState extends State<_StopKioskCard> {
  bool _confirming = false;
  bool _busy = false;
  ActionResult? _result;

  Future<void> _tap() async {
    if (_busy) return;
    if (!_confirming) {
      setState(() => _confirming = true);
      return;
    }
    setState(() {
      _confirming = false;
      _busy = true;
    });
    final r = await widget.ops.stopKiosk();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    return _Card(
      icon: Icons.warning_amber_rounded,
      title: 'STOP KIOSK (LAST RESORT)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Stops the dashboard so a keyboard on the Pi can reach a login '
            '(Ctrl+Alt+F2). The screen goes blank. Only do this if you have a '
            'keyboard on the device — otherwise you lose the one way in you have.',
            style: TextStyle(color: DashTheme.inkFaint, fontSize: 14, height: 1.4),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: _busy ? null : _tap,
            style: OutlinedButton.styleFrom(
              foregroundColor: DashTheme.offline,
              side: BorderSide(color: DashTheme.offline, width: _confirming ? 2 : 1),
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            ),
            icon: const Icon(Icons.stop_circle_outlined),
            label: Text(
              _busy ? 'Stopping…' : (_confirming ? 'Tap again to confirm' : 'Stop kiosk'),
              style: TextStyle(fontSize: 16, fontWeight: _confirming ? FontWeight.w700 : FontWeight.w600),
            ),
          ),
          if (_result != null) ...[
            const SizedBox(height: 14),
            _ResultLine(result: _result!),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
class _ResultLine extends StatelessWidget {
  const _ResultLine({required this.result});
  final ActionResult result;

  @override
  Widget build(BuildContext context) {
    final color = result.ok ? DashTheme.online : DashTheme.offline;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(result.ok ? Icons.check_circle_outline : Icons.error_outline, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: SelectableText(
            result.message,
            style: TextStyle(color: color, fontSize: 15, height: 1.4),
          ),
        ),
      ],
    );
  }
}
