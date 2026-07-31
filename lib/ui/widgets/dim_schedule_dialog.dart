import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/dim_controller.dart';
import '../../services/power_service.dart';
import '../theme.dart';

/// Open the dim-schedule modal. Reached from the gear in the status overlay.
Future<void> showDimScheduleDialog(BuildContext context) {
  final dim = context.read<DimController>();
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.7),
    builder: (_) => ChangeNotifierProvider<DimController>.value(
      value: dim,
      child: const _DimScheduleDialog(),
    ),
  );
}

/// A small, touch-sized editor for the three schedule boundaries plus the
/// evening scrim strength. Edits persist across reboots (DimScheduleStore);
/// the compile-time dart-defines remain the defaults behind them, and "Reset"
/// forgets the saved override and returns to them.
class _DimScheduleDialog extends StatefulWidget {
  const _DimScheduleDialog();

  @override
  State<_DimScheduleDialog> createState() => _DimScheduleDialogState();
}

class _DimScheduleDialogState extends State<_DimScheduleDialog> {
  late int _activeStart;
  late int _activeEnd;
  late int _dimmedEnd;
  late double _opacity;

  // Shutdown is a two-step tap. This is a wall-mounted touchscreen: a single
  // stray press must never be able to take the board down.
  Timer? _confirmTimer;
  bool _confirmingShutdown = false;
  bool _shuttingDown = false;
  String? _powerError;

  @override
  void initState() {
    super.initState();
    _loadFrom(context.read<DimController>());
  }

  @override
  void dispose() {
    _confirmTimer?.cancel();
    super.dispose();
  }

  Future<void> _onShutdownTap() async {
    if (_shuttingDown) return;

    // First tap arms it; it disarms itself so a modal left open on the wall
    // doesn't sit in a one-touch-to-power-off state indefinitely.
    if (!_confirmingShutdown) {
      _confirmTimer?.cancel();
      setState(() {
        _confirmingShutdown = true;
        _powerError = null;
      });
      _confirmTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _confirmingShutdown = false);
      });
      return;
    }

    _confirmTimer?.cancel();
    setState(() {
      _confirmingShutdown = false;
      _shuttingDown = true;
    });

    final accepted = await const PowerService().shutdown();
    if (!mounted) return;
    // On success we simply stay in the "shutting down" state until systemd
    // SIGTERMs us -- there is nothing useful left to do.
    if (!accepted) {
      setState(() {
        _shuttingDown = false;
        _powerError = 'Shutdown unavailable — dashboard-power.sudoers missing?';
      });
    }
  }

  void _loadFrom(DimController dim) {
    _activeStart = dim.activeStartHour;
    _activeEnd = dim.activeEndHour;
    _dimmedEnd = dim.dimmedEndHour;
    _opacity = dim.dimmedScrimOpacity;
  }

  bool get _valid =>
      DimController.isValidSchedule(_activeStart, _activeEnd, _dimmedEnd);

  void _save() {
    context.read<DimController>().updateSchedule(
          activeStartHour: _activeStart,
          activeEndHour: _activeEnd,
          dimmedEndHour: _dimmedEnd,
          dimmedScrimOpacity: _opacity,
        );
    Navigator.of(context).pop();
  }

  void _reset() {
    final dim = context.read<DimController>()..resetSchedule();
    setState(() => _loadFrom(dim));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<DimController>().state;

    return AlertDialog(
      backgroundColor: DashTheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titlePadding: const EdgeInsets.fromLTRB(28, 24, 28, 8),
      contentPadding: const EdgeInsets.fromLTRB(28, 0, 28, 8),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      title: Row(
        children: [
          Icon(Icons.brightness_4_outlined, color: DashTheme.accent, size: 28),
          const SizedBox(width: 14),
          Text(
            'DIM SCHEDULE',
            style: TextStyle(
              color: DashTheme.accent,
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: 3,
            ),
          ),
          const Spacer(),
          _StateChip(state: state),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _HourRow(
              label: 'Bright from',
              hour: _activeStart,
              onChanged: (h) => setState(() => _activeStart = h),
            ),
            _HourRow(
              label: 'Dim at',
              hour: _activeEnd,
              onChanged: (h) => setState(() => _activeEnd = h),
            ),
            _HourRow(
              label: 'Screen off at',
              hour: _dimmedEnd,
              onChanged: (h) => setState(() => _dimmedEnd = h),
            ),
            const SizedBox(height: 20),
            _OpacityRow(
              value: _opacity,
              onChanged: (v) => setState(() => _opacity = v),
            ),
            const SizedBox(height: 8),
            Text(
              _valid
                  ? 'Tap the screen while it is off to wake it briefly.'
                  : 'Hours must run forward: bright → dim → off.',
              style: TextStyle(
                color: _valid ? DashTheme.inkFaint : DashTheme.offline,
                fontSize: 17,
              ),
            ),
            const SizedBox(height: 20),
            Divider(color: DashTheme.line, height: 1),
            const SizedBox(height: 16),
            _ShutdownRow(
              confirming: _confirmingShutdown,
              shuttingDown: _shuttingDown,
              error: _powerError,
              onTap: _onShutdownTap,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _reset,
          child: Text('Reset', style: TextStyle(color: DashTheme.inkSoft, fontSize: 20)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: DashTheme.inkSoft, fontSize: 20)),
        ),
        FilledButton(
          onPressed: _valid ? _save : null,
          style: FilledButton.styleFrom(
            backgroundColor: DashTheme.accent,
            foregroundColor: DashTheme.bg,
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          ),
          child: const Text('Save',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

/// Clean-shutdown control, so the board can be unplugged without risking the
/// SD card. Deliberately the quietest thing in the modal until it is armed:
/// the common case is someone adjusting the dim hours, not powering down.
class _ShutdownRow extends StatelessWidget {
  const _ShutdownRow({
    required this.confirming,
    required this.shuttingDown,
    required this.error,
    required this.onTap,
  });

  final bool confirming;
  final bool shuttingDown;
  final String? error;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final danger = DashTheme.offline;
    final armed = confirming || shuttingDown;
    final color = armed ? danger : DashTheme.inkSoft;

    final label = switch ((shuttingDown, confirming)) {
      (true, _) => 'Shutting down…',
      (_, true) => 'Tap again to power off',
      _ => 'Shut down',
    };

    // Tell them what "safe to unplug" actually looks like -- on a Lite install
    // the screen just goes black, which is indistinguishable from a crash. The
    // Pi's green ACT LED blinks 10 times and then stays dark; that's the signal.
    final hint = switch ((shuttingDown, error)) {
      (true, _) => 'Wait for the green LED to blink 10× and stop, then unplug.',
      (_, final e?) => e,
      _ => 'Stops the Pi cleanly so a write in flight cannot corrupt the card.',
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            hint,
            style: TextStyle(
              color: error != null ? danger : DashTheme.inkFaint,
              fontSize: 16,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Material(
          color: armed ? danger.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: shuttingDown ? null : onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: armed ? danger : DashTheme.line,
                  width: armed ? 2 : 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.power_settings_new, size: 22, color: color),
                  const SizedBox(width: 10),
                  Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontSize: 18,
                      fontWeight: armed ? FontWeight.w700 : FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One boundary: a label and a big −/+ hour stepper, sized for a fingertip.
class _HourRow extends StatelessWidget {
  const _HourRow({
    required this.label,
    required this.hour,
    required this.onChanged,
  });

  final String label;
  final int hour;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: DashTheme.inkSoft, fontSize: 21),
            ),
          ),
          _StepButton(
            icon: Icons.remove,
            onTap: hour > 0 ? () => onChanged(hour - 1) : null,
          ),
          SizedBox(
            width: 150,
            child: Text(
              hourLabel(hour),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: DashTheme.ink,
                fontSize: 23,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          _StepButton(
            icon: Icons.add,
            onTap: hour < 24 ? () => onChanged(hour + 1) : null,
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: onTap == null ? DashTheme.surface : DashTheme.surfaceAlt,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(
            icon,
            size: 26,
            color: onTap == null ? DashTheme.inkFaint : DashTheme.ink,
          ),
        ),
      ),
    );
  }
}

class _OpacityRow extends StatelessWidget {
  const _OpacityRow({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          'Evening dimness',
          style: TextStyle(color: DashTheme.inkSoft, fontSize: 21),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: 0,
            max: 0.95,
            divisions: 19,
            activeColor: DashTheme.accent,
            inactiveColor: DashTheme.line,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 70,
          child: Text(
            '${(value * 100).round()}%',
            textAlign: TextAlign.right,
            style: TextStyle(
              color: DashTheme.ink,
              fontSize: 21,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

/// What the schedule says right now, so the edit has visible context.
class _StateChip extends StatelessWidget {
  const _StateChip({required this.state});

  final DisplayState state;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      DisplayState.active => ('BRIGHT', DashTheme.online),
      DisplayState.dimmed => ('DIMMED', DashTheme.accent),
      DisplayState.blanked => ('OFF', DashTheme.offline),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 15,
          fontWeight: FontWeight.w700,
          letterSpacing: 2,
        ),
      ),
    );
  }
}

/// "8 AM", "6 PM", "12 AM (next day)" for the 0..24 boundary hours.
String hourLabel(int hour) {
  if (hour == 24) return '12 AM +1';
  if (hour == 0) return '12 AM';
  if (hour == 12) return '12 PM';
  return hour < 12 ? '$hour AM' : '${hour - 12} PM';
}
