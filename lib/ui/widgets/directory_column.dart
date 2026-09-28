import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/app_config.dart';
import '../../controllers/directory_controller.dart';
import '../../controllers/rota_controller.dart';
import '../../models/directory_entry.dart';
import '../directory_screen.dart';
import '../theme.dart';
import 'directory_list.dart';
import 'kiosk_scroll_behavior.dart';
import 'rota_card.dart';
import 'section_header.dart';

/// The right-hand dashboard column, in two equal halves.
///
/// Above, the directory: a compact grouped contact list that scrolls in place,
/// so a long staff list can be read without leaving the dashboard, with a tap
/// anywhere still opening the roomier full-screen version. Below, the doctors
/// rota: who is in over the next few days, with their hours.
class DirectoryColumn extends StatelessWidget {
  const DirectoryColumn({super.key});

  /// The status overlay's gear and refresh icons float in the bottom-right
  /// corner of the column area, which is this column's bottom-right corner.
  /// The rota keeps that strip clear, so the last doctor's hours never end up
  /// under a gear. The icons are 48 px tall and sit 24 px up, on this
  /// column's 24 px of bottom padding.
  static const double statusOverlayClearance = 48;

  @override
  Widget build(BuildContext context) {
    final dir = context.watch<DirectoryController>();
    final today = DateTime.now();
    final rotaDays = context.watch<RotaController>().shownDays(now: today);

    return Container(
      color: DashTheme.surface,
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // --- Directory ---
          Expanded(
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
                          style: TextStyle(
                              color: DashTheme.inkFaint, fontSize: 18),
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const Divider(height: 1, thickness: 1, color: DashTheme.line),
          const SizedBox(height: 18),

          // --- Doctors rota ---
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Each day column carries its own date, so the heading needs
                // no trailing one — and no "· MONDAY" when the card is looking
                // past a weekend, since the columns say so.
                const SectionHeader(title: 'DOCTORS ROTA'),
                const SizedBox(height: 14),
                Expanded(
                  child: Padding(
                    padding:
                        const EdgeInsets.only(bottom: statusOverlayClearance),
                    child: RotaCard(days: rotaDays, today: today),
                  ),
                ),
              ],
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
            const SizedBox(height: 6),
            // The lower banner: an affordance that the list scrolls, and that
            // there's a roomier version behind a click.
            Row(
              children: [
                Icon(Icons.open_in_full,
                    size: 15, color: DashTheme.inkFaint),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    'Scroll, or click to expand',
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
