import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/app_config.dart';
import '../../controllers/directory_controller.dart';
import '../../models/directory_entry.dart';
import '../directory_screen.dart';
import '../theme.dart';
import 'directory_list.dart';
import 'kiosk_scroll_behavior.dart';
import 'section_header.dart';

/// The right-hand dashboard column: a compact grouped contact list that scrolls
/// in place, so a long staff list can be read without leaving the dashboard.
/// Tapping anywhere still opens the roomier full-screen directory.
class DirectoryColumn extends StatelessWidget {
  const DirectoryColumn({super.key});

  @override
  Widget build(BuildContext context) {
    final dir = context.watch<DirectoryController>();

    return Container(
      color: DashTheme.surface,
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'DIRECTORY'),
          const SizedBox(height: 14),
          Expanded(
            child: dir.hasEntries
                ? _TappableList(groups: dir.groups)
                : Text(
                    'No directory entries',
                    style:
                        TextStyle(color: DashTheme.inkFaint, fontSize: 18),
                  ),
          ),
        ],
      ),
    );
  }
}

class _TappableList extends StatefulWidget {
  const _TappableList({required this.groups});
  final List<DirectoryGroup> groups;

  @override
  State<_TappableList> createState() => _TappableListState();
}

class _TappableListState extends State<_TappableList> {
  final ScrollController _controller = ScrollController();

  Timer? _returnTimer;

  /// True while we are scrolling the column back ourselves. The animation emits
  /// the same notifications a person does, so without this it would keep
  /// re-arming its own timer forever on an unattended board.
  bool _returning = false;

  @override
  void dispose() {
    _returnTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Re-arm the idle countdown on every scroll, so the column only drifts back
  /// once nobody has touched it for [AppConfig.directoryScrollLinger].
  bool _onScroll(ScrollNotification notification) {
    if (_returning) return false;
    _returnTimer?.cancel();
    // Already home — nothing to schedule.
    if (!_controller.hasClients || _controller.offset <= 0) return false;
    _returnTimer = Timer(AppConfig.directoryScrollLinger, _returnToTop);
    return false; // let the notification keep bubbling (the scrollbar wants it)
  }

  Future<void> _returnToTop() async {
    if (!_controller.hasClients || _controller.offset <= 0) return;
    _returning = true;
    try {
      await _controller.animateTo(
        0,
        duration: AppConfig.directoryScrollReturn,
        curve: Curves.easeOutCubic,
      );
    } finally {
      // Also runs when a fresh drag interrupts the glide, which is what hands
      // control straight back to whoever grabbed it.
      _returning = false;
    }
  }

  /// The scrolling contact list: an always-visible thumb over a clamped scroll
  /// view, with the idle countdown wired in.
  Widget _buildScroller() {
    return ScrollConfiguration(
      behavior: const KioskScrollBehavior(),
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: RawScrollbar(
          controller: _controller,
          thumbVisibility: true,
          thickness: 5,
          radius: const Radius.circular(3),
          thumbColor: DashTheme.inkFaint.withValues(alpha: 0.55),
          child: SingleChildScrollView(
            controller: _controller,
            // Clamping, not bouncing: an overscroll rubber-band on an always-on
            // board just looks like a glitch from across the room.
            physics: const ClampingScrollPhysics(),
            // Keep the text clear of the scrollbar track.
            padding: const EdgeInsets.only(right: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final g in widget.groups)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: DirectoryGroupBlock(group: g, compact: true),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      // A plain tap still opens the full directory; a drag is claimed by the
      // scroll view instead, so the two gestures don't fight.
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const DirectoryScreen()),
      ),
      child: ClipRect(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildScroller()),
            // Affordance that there's more behind a click.
            Row(
              children: [
                Icon(Icons.open_in_full,
                    size: 15, color: DashTheme.inkFaint),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    'Scroll, or click for full directory',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(color: DashTheme.inkFaint, fontSize: 15),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
