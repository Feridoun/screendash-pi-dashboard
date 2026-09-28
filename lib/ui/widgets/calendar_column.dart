import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../controllers/calendar_controller.dart';
import '../../models/calendar_grid.dart';
import '../theme.dart';
import 'calendar_grid_view.dart';
import 'clock_header.dart';
import 'message_panel.dart';
import 'section_header.dart';
import 'weather_strip.dart';

/// The middle column: the clock and outlook, then the rolling 14-day grid, then
/// the messages, which take whatever height the grid leaves.
class CalendarColumn extends StatelessWidget {
  const CalendarColumn({super.key});

  @override
  Widget build(BuildContext context) {
    final cal = context.watch<CalendarController>();
    final grid = cal.grid;
    final today = DateTime.now();
    final rangeLabel =
        '${DateFormat('d MMM').format(today)} – '
        '${DateFormat('d MMM').format(CalendarGrid.lastDay(today))}';

    return Container(
      color: DashTheme.surface,
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The header band: day/date/time stacked on the left, the outlook
          // opposite it on the right. The weather sits with the clock rather
          // than under its own heading — what it is doing today is part of the
          // same glance as the date — and collapses to nothing when there is no
          // fresh forecast, leaving the clock where it was.
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: ClockHeader()),
              WeatherStrip(),
            ],
          ),
          const SizedBox(height: 18),
          const Divider(height: 1, thickness: 1, color: DashTheme.line),
          const SizedBox(height: 18),
          SectionHeader(title: 'NEXT 14 DAYS', trailing: rangeLabel),
          const SizedBox(height: 14),
          CalendarGridView(grid: grid),
          const SizedBox(height: 22),
          SectionHeader(title: 'MESSAGES'),
          const SizedBox(height: 12),
          // The message panel takes the remaining height and scrolls its own
          // overflow, rather than the column overflowing as messages arrive.
          const Expanded(child: MessagePanel()),
        ],
      ),
    );
  }
}
