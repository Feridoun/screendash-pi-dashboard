import 'package:flutter/material.dart';

import '../../models/calendar_grid.dart';
import '../theme.dart';

/// Renders the rolling 14-day grid: a Mon-first weekday header over rows of
/// day-cells. Today gets an accent fill. Read-only and static — no scrolling,
/// no month navigation.
class CalendarGridView extends StatelessWidget {
  const CalendarGridView({super.key, required this.grid});

  final CalendarGrid grid;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Weekday header (Mon-first).
        Row(
          children: [
            for (final label in CalendarGrid.weekdayLabels)
              Expanded(
                child: Center(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: DashTheme.inkFaint,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
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

class _Cell extends StatelessWidget {
  const _Cell({required this.cell});
  final GridCell cell;

  @override
  Widget build(BuildContext context) {
    if (cell.isBlank) {
      return const AspectRatio(aspectRatio: 1, child: SizedBox());
    }

    final today = cell.isToday;
    return Padding(
      padding: const EdgeInsets.all(3),
      child: AspectRatio(
        aspectRatio: 1,
        child: Container(
          decoration: BoxDecoration(
            color: today ? DashTheme.accent : DashTheme.surfaceAlt,
            borderRadius: BorderRadius.circular(8),
            border: today
                ? null
                : Border.all(color: DashTheme.line, width: 1),
          ),
          child: Center(
            child: Text(
              '${cell.date!.day}',
              style: TextStyle(
                color: today ? const Color(0xFF1A140A) : DashTheme.ink,
                fontSize: 22,
                fontWeight: today ? FontWeight.w800 : FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
