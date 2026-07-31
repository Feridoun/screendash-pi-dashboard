import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../config/app_config.dart';
import '../../controllers/motd_controller.dart';
import '../theme.dart';

/// Full-width message-of-the-day banner along the bottom. Collapses to nothing
/// when there's no message, so the layout below never shows an empty bar.
///
/// Two things a one-line banner couldn't do:
///   * a notice longer than [AppConfig.motdMaxLines] lines is scrolled past
///     rather than ellipsized, so a paragraph still gets read end to end;
///   * the arrows step back through notices this one replaced, for anyone who
///     was away when the last one went up.
///
/// Like the photo controls, the arrows are quiet: they surface on hover or
/// touch and fade again after [AppConfig.motdViewLinger] — which is also when
/// the banner drops back to the current notice, so the wall never sits showing
/// last week's news because somebody wandered off mid-cycle.
class MotdBanner extends StatefulWidget {
  const MotdBanner({super.key});

  @override
  State<MotdBanner> createState() => _MotdBannerState();
}

class _MotdBannerState extends State<MotdBanner> {
  bool _hovering = false;
  bool _touched = false;
  Timer? _linger;

  bool get _controlsVisible => _hovering || _touched;

  @override
  void dispose() {
    _linger?.cancel();
    super.dispose();
  }

  /// Show the controls and restart the countdown that hides them and returns
  /// the banner to the current notice.
  void _reveal() {
    _linger?.cancel();
    if (!_touched) setState(() => _touched = true);
    _linger = Timer(AppConfig.motdViewLinger, () {
      if (!mounted) return;
      setState(() => _touched = false);
      context.read<MotdController>().showCurrent();
    });
  }

  void _step(void Function() move) {
    _reveal();
    move();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<MotdController>();
    final motd = controller.motd;
    if (motd.isEmpty) return const SizedBox.shrink();

    final accent = DashTheme.parseHex(motd.accentHex) ?? DashTheme.accent;
    final showing = controller.isCurrent;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        // A touch anywhere on the banner brings the arrows up — on a wall panel
        // there is no cursor to hover with.
        behavior: HitTestBehavior.opaque,
        onTap: _reveal,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
          decoration: BoxDecoration(
            color: DashTheme.surfaceAlt,
            border: Border(top: BorderSide(color: accent, width: 4)),
          ),
          child: Row(
            children: [
              // The icon carries the "this isn't the current notice" cue at
              // across-the-room distance, where the small pill can't.
              Icon(
                showing ? Icons.campaign_outlined : Icons.history,
                color: showing ? accent : DashTheme.inkFaint,
                size: 40,
              ),
              const SizedBox(width: 24),
              Expanded(
                // Optical alignment, not geometric: the Row already centres both
                // children, but the campaign/history glyphs sit low in their em
                // box, so the text reads as riding below the loudspeaker's axis.
                // Transform rather than padding — this must not change the row's
                // height or the scrolling notice's viewport metrics.
                child: Transform.translate(
                  offset: const Offset(0, -2),
                  child: _ScrollingNotice(
                    // Rebuild fresh per notice so the scroll restarts at the top.
                    key: ValueKey(controller.index),
                    text: motd.text,
                    dimmed: !showing,
                  ),
                ),
              ),
              if (controller.count > 1) ...[
                const SizedBox(width: 24),
                _MotdControls(
                  visible: _controlsVisible,
                  index: controller.index,
                  count: controller.count,
                  // Only worth the space once it says something the current
                  // notice doesn't.
                  stamp: showing ? null : _stampFor(motd.updated),
                  onOlder: controller.canShowOlder
                      ? () => _step(controller.showOlder)
                      : null,
                  onNewer: controller.canShowNewer
                      ? () => _step(controller.showNewer)
                      : null,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// When an older notice went up. Undated notices (pre-history backends) get
  /// no chip rather than a wrong one.
  String? _stampFor(DateTime? updated) =>
      updated == null ? null : DateFormat('d MMM').format(updated);
}

/// Notice text, capped at [AppConfig.motdMaxLines] and slowly scrolled when it
/// doesn't fit.
///
/// Deliberately not draggable: the panel is furniture, and a half-scrolled
/// banner left by a passing finger would be worse than no scrolling at all. The
/// cycle is hold at top → creep down → hold at bottom → glide back, forever,
/// and short notices never move.
class _ScrollingNotice extends StatefulWidget {
  const _ScrollingNotice({super.key, required this.text, required this.dimmed});

  final String text;
  final bool dimmed;

  @override
  State<_ScrollingNotice> createState() => _ScrollingNoticeState();
}

class _ScrollingNoticeState extends State<_ScrollingNotice> {
  static const double _fontSize = 34;
  static const double _lineHeight = 1.15;

  final ScrollController _scroll = ScrollController();

  /// Bumped whenever the text changes, so an in-flight cycle from the previous
  /// notice retires instead of animating the new one.
  int _cycle = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant _ScrollingNotice old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _start(); // retires the running cycle by bumping the generation
    }
  }

  @override
  void dispose() {
    _cycle++; // retire any running cycle before the controller goes away
    _scroll.dispose();
    super.dispose();
  }

  /// Wait for layout, then scroll if (and only if) the text overflows.
  void _start() {
    final generation = ++_cycle;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _cycle || !_scroll.hasClients) return;
      if (_scroll.position.maxScrollExtent <= 0) return; // it all fits
      _run(generation);
    });
  }

  Future<void> _run(int generation) async {
    // Every await is a chance for the widget to go away or the notice to
    // change; `_alive` is the one guard both cases funnel through.
    bool alive() => mounted && generation == _cycle && _scroll.hasClients;

    while (alive() && _scroll.position.maxScrollExtent > 0) {
      final extent = _scroll.position.maxScrollExtent;

      await Future.delayed(AppConfig.motdScrollHold);
      if (!alive()) return;
      await _scroll.animateTo(
        extent,
        duration: _durationFor(extent, AppConfig.motdScrollSpeed),
        curve: Curves.linear,
      );
      if (!alive()) return;

      await Future.delayed(AppConfig.motdScrollHold);
      if (!alive()) return;
      // The way back is a rewind, not reading time — take it briskly.
      await _scroll.animateTo(
        0,
        duration: _durationFor(extent, AppConfig.motdScrollSpeed * 6),
        curve: Curves.easeInOut,
      );
    }
  }

  Duration _durationFor(double extent, double pixelsPerSecond) {
    final ms = (extent / pixelsPerSecond * 1000).round();
    return Duration(milliseconds: ms.clamp(200, 60000));
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxHeight: _fontSize * _lineHeight * AppConfig.motdMaxLines,
      ),
      child: SingleChildScrollView(
        controller: _scroll,
        physics: const NeverScrollableScrollPhysics(),
        child: Text(
          widget.text,
          style: TextStyle(
            // Older notices read a shade quieter than the one in force.
            color: widget.dimmed ? DashTheme.inkSoft : DashTheme.ink,
            fontSize: _fontSize,
            fontWeight: FontWeight.w600,
            height: _lineHeight,
          ),
        ),
      ),
    );
  }
}

/// The cycle pill: step back through notices, position, step forward, and — for
/// an older notice — the day it went up.
class _MotdControls extends StatelessWidget {
  const _MotdControls({
    required this.visible,
    required this.index,
    required this.count,
    required this.stamp,
    required this.onOlder,
    required this.onNewer,
  });

  final bool visible;
  final int index;
  final int count;
  final String? stamp;
  final VoidCallback? onOlder;
  final VoidCallback? onNewer;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: IgnorePointer(
        ignoring: !visible,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: DashTheme.ink.withValues(alpha: 0.18)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Left steps backwards in time, which is where the history is.
              _ControlButton(icon: Icons.chevron_left, onTap: onOlder),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  '${index + 1} / $count',
                  style: TextStyle(
                    color: DashTheme.ink.withValues(alpha: 0.85),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    // Tabular so the pill doesn't jitter as the index changes.
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              _ControlButton(icon: Icons.chevron_right, onTap: onNewer),
              if (stamp != null) ...[
                Container(
                  width: 1,
                  height: 22,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  color: DashTheme.ink.withValues(alpha: 0.18),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8, left: 2),
                  child: Text(
                    stamp!,
                    style: TextStyle(
                      color: DashTheme.inkFaint,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A roomy icon tap target, sized for a finger at arm's length. Disabled at the
/// ends of the feed rather than removed, so the pill keeps its shape under a
/// finger that's stepping through.
class _ControlButton extends StatelessWidget {
  const _ControlButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Icon(
          icon,
          size: 24,
          color: DashTheme.ink.withValues(alpha: enabled ? 0.85 : 0.3),
        ),
      ),
    );
  }
}
