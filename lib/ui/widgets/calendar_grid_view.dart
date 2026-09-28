import 'package:flutter/material.dart';

import '../../models/calendar_grid.dart';
import '../theme.dart';

/// Renders the rolling 14-day grid: a Mon-first weekday header over rows of
/// day-cells. Today gets an accent fill, and the weekend recedes. Read-only and
/// static — no scrolling, no month navigation.
///
/// Saturday and Sunday are drawn a step back from the working week — a darker
/// fill than the column's own surface and a quieter number — so the shape of a
/// week is legible at a glance without anyone counting columns. It is a
/// recession, not a highlight: on an office board the days that matter are the
/// ones people are in.
class CalendarGridView extends StatelessWidget {
  const CalendarGridView({super.key, required this.grid});

  final CalendarGrid grid;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Weekday header (Mon-first). The last two columns are the weekend.
        Row(
          children: [
            for (var i = 0; i < CalendarGrid.weekdayLabels.length; i++)
              Expanded(
                child: Center(
                  child: Text(
                    CalendarGrid.weekdayLabels[i],
                    style: TextStyle(
                      color: _isWeekendColumn(i)
                          ? DashTheme.inkFaint
                          : DashTheme.inkSoft,
                      fontSize: 18,
                      fontWeight:
                          _isWeekendColumn(i) ? FontWeight.w500 : FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        // Day rows.
        for (final row in grid.rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                for (final cell in row)
                  Expanded(child: _Cell(cell: cell)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Whether column [index] of a Monday-first header is Saturday or Sunday.
bool _isWeekendColumn(int index) => index >= 5;

class _Cell extends StatelessWidget {
  const _Cell({required this.cell});
  final GridCell cell;

  @override
  Widget build(BuildContext context) {
    if (cell.isBlank) {
      return const AspectRatio(aspectRatio: 1, child: SizedBox());
    }

    final today = cell.isToday;
    // Today outranks the weekend: a Saturday that is today still gets the
    // accent, or the board would quietly stop showing where "now" is for two
    // days out of every seven.
    final weekend = !today && cell.date!.weekday >= DateTime.saturday;
    return Padding(
      padding: const EdgeInsets.all(3),
      child: AspectRatio(
        aspectRatio: 1,
        child: Container(
          decoration: BoxDecoration(
            color: today
                ? DashTheme.accent
                : weekend
                    // Darker than the column it sits on, so the weekend reads
                    // as a hole in the week rather than another working day.
                    ? DashTheme.bg
                    : DashTheme.surfaceAlt,
            borderRadius: BorderRadius.circular(8),
            border: today
                ? null
                : Border.all(color: DashTheme.line, width: 1),
          ),
          child: Center(
            child: Text(
              '${cell.date!.day}',
              style: TextStyle(
                color: today
                    ? const Color(0xFF1A140A)
                    : weekend
                        ? DashTheme.inkFaint
                        : DashTheme.ink,
                fontSize: 22,
                fontWeight: today
                    ? FontWeight.w800
                    : weekend
                        ? FontWeight.w500
                        : FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
