import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/calendar_controller.dart';
import '../../controllers/directory_controller.dart';
import '../../controllers/motd_controller.dart';
import '../../controllers/photo_controller.dart';
import '../theme.dart';
import 'dim_schedule_dialog.dart';

/// A bottom-right pair of icons: a gear for configuration and a refresh glyph
/// doing double duty as the connectivity indicator — green when all pollers are
/// online, amber-red if any is currently failing.
///
/// The clock used to live here as a floating corner overlay; it now sits at the
/// top of the calendar column ([ClockHeader]).
///
/// Tapping the gear opens the dim-schedule modal — the one bit of on-device
/// configuration.
class StatusOverlay extends StatefulWidget {
  const StatusOverlay({super.key});

  @override
  State<StatusOverlay> createState() => _StatusOverlayState();
}

class _StatusOverlayState extends State<StatusOverlay> {
  bool _refreshing = false;

  /// Pull everything now. Calendar and directory go via [refreshFromSource],
  /// which first tells the backend to re-read Google Calendar / the Sheet —
  /// otherwise we would just re-download the artifact its cron last wrote, and
  /// an edit made a minute ago would stay invisible for another fifteen.
  Future<void> _refreshNow() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await Future.wait([
        context.read<PhotoController>().refreshNow(),
        context.read<MotdController>().refreshNow(),
        context.read<CalendarController>().refreshFromSource(),
        context.read<DirectoryController>().refreshFromSource(),
      ]);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final allOnline = context.watch<PhotoController>().online &&
        context.watch<CalendarController>().online &&
        context.watch<MotdController>().online;

    return Stack(
      children: [
        Positioned(
          bottom: 24,
          right: 32,
          child: Row(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                // Now that it's a visible gear rather than a hidden gesture on
                // the clock, a tap is what people actually try. Long-press is
                // kept so the original muscle memory still works.
                onTap: () => showDimScheduleDialog(context),
                onLongPress: () => showDimScheduleDialog(context),
                child: Padding(
                  // Roomy enough to be a reliable touch target at arm's length.
                  padding: const EdgeInsets.all(12),
                  child: Icon(
                    Icons.settings,
                    size: 24,
                    color: DashTheme.ink.withValues(alpha: 0.6),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _RefreshButton(
                refreshing: _refreshing,
                online: allOnline,
                onTap: _refreshNow,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A quiet icon button that forces every poller to sync right now, instead of
/// waiting out its jittered interval. Spins while the refresh is in flight.
/// Doubles as the connectivity indicator: green when every poller is online,
/// amber-red if any is currently failing.
class _RefreshButton extends StatefulWidget {
  const _RefreshButton({
    required this.refreshing,
    required this.online,
    required this.onTap,
  });

  final bool refreshing;
  final bool online;
  final VoidCallback onTap;

  @override
  State<_RefreshButton> createState() => _RefreshButtonState();
}

class _RefreshButtonState extends State<_RefreshButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didUpdateWidget(covariant _RefreshButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshing) {
      _spin.repeat();
    } else {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.refreshing ? null : widget.onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: RotationTransition(
          turns: _spin,
          child: Icon(
            Icons.refresh,
            size: 24,
            color: widget.online ? DashTheme.online : DashTheme.offline,
          ),
        ),
      ),
    );
  }
}
