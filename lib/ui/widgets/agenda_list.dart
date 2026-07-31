import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/calendar_event.dart';
import '../theme.dart';

/// The "what's actually next" companion to the grid's "shape of the fortnight".
/// A compact, time-ordered list of upcoming events.
class AgendaList extends StatelessWidget {
  const AgendaList({super.key, required this.events, this.maxItems = 4});

  final List<CalendarEvent> events;
  final int maxItems;

  @override
  Widget build(BuildContext context) {
    final shown = events.take(maxItems).toList();
    if (shown.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'No upcoming meetings',
          style: TextStyle(color: DashTheme.inkFaint, fontSize: 20),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final e in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: _AgendaTile(event: e),
          ),
      ],
    );
  }
}

class _AgendaTile extends StatelessWidget {
  const _AgendaTile({required this.event});
  final CalendarEvent event;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          DateFormat('EEE  h:mm a').format(event.start),
          style: TextStyle(
            color: DashTheme.accent,
            fontSize: 19,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 2),
        // FittedBox so a long title scales down instead of wrapping to mush.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            event.title,
            maxLines: 1,
            style: TextStyle(
              color: DashTheme.ink,
              fontSize: 25,
              fontWeight: FontWeight.w700,
              height: 1.1,
            ),
          ),
        ),
        if (event.room != null && event.room!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              event.room!,
              style: TextStyle(color: DashTheme.inkFaint, fontSize: 18),
            ),
          ),
      ],
    );
  }
}
