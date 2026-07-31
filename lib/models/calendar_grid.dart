import 'package:flutter/foundation.dart';

import 'calendar_event.dart';

/// One cell in the 14-day grid. A [date] of null is a padding blank used to
/// align the first/last partial weeks under a Mon-first header.
@immutable
class GridCell {
  final DateTime? date; // null = leading/trailing blank
  final bool isToday;
  final int eventCount;

  const GridCell.blank()
      : date = null,
        isToday = false,
        eventCount = 0;

  const GridCell.day({
    required this.date,
    required this.isToday,
    required this.eventCount,
  });

  bool get isBlank => date == null;
}

/// Builds the rolling **14-day** grid: 14 real day-cells starting at [today],
/// laid out under a Monday-first weekday header. The first row is padded with
/// leading blanks (from the Monday on/before today up to today) and the last
/// row is padded with trailing blanks so every row has 7 cells.
///
/// [countForDay] returns how many events fall on a given (midnight-truncated)
/// day — used to render the per-cell marker.
class CalendarGrid {
  /// Number of real day-cells shown, starting at today.
  static const int span = 14;

  /// Weekday header labels, Monday-first.
  static const List<String> weekdayLabels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  final List<GridCell> cells;

  const CalendarGrid._(this.cells);

  factory CalendarGrid.build({
    required DateTime today,
    required int Function(DateTime day) countForDay,
  }) {
    final t = DateTime(today.year, today.month, today.day);

    // Monday on/before today. Dart weekday: Mon=1 … Sun=7.
    final leadingBlanks = t.weekday - DateTime.monday; // 0..6

    final cells = <GridCell>[];
    for (var i = 0; i < leadingBlanks; i++) {
      cells.add(const GridCell.blank());
    }
    for (var i = 0; i < span; i++) {
      final d = t.add(Duration(days: i));
      cells.add(GridCell.day(
        date: d,
        isToday: i == 0,
        eventCount: countForDay(d),
      ));
    }
    // Trailing blanks to complete the final row of 7.
    while (cells.length % 7 != 0) {
      cells.add(const GridCell.blank());
    }
    return CalendarGrid._(List.unmodifiable(cells));
  }

  /// The cells chunked into rows of 7 for a Table/GridView.
  List<List<GridCell>> get rows {
    final out = <List<GridCell>>[];
    for (var i = 0; i < cells.length; i += 7) {
      out.add(cells.sublist(i, i + 7));
    }
    return out;
  }

  /// The last day the grid covers (today + 13), for range display.
  static DateTime lastDay(DateTime today) =>
      DateTime(today.year, today.month, today.day)
          .add(const Duration(days: span - 1));
}

/// Buckets a list of events by their calendar day, for fast per-day counts.
Map<DateTime, List<CalendarEvent>> bucketByDay(List<CalendarEvent> events) {
  final map = <DateTime, List<CalendarEvent>>{};
  for (final e in events) {
    (map[e.day] ??= <CalendarEvent>[]).add(e);
  }
  return map;
}
