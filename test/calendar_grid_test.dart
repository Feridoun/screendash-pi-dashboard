import 'package:flutter_test/flutter_test.dart';

import 'package:screendash/models/calendar_event.dart';
import 'package:screendash/models/calendar_grid.dart';

/// Convenience: build a grid with no events.
CalendarGrid gridFor(DateTime today) =>
    CalendarGrid.build(today: today, countForDay: (_) => 0);

void main() {
  group('CalendarGrid', () {
    test('always emits whole rows of 7', () {
      // Walk a full week of possible "today" weekdays.
      for (var i = 0; i < 7; i++) {
        final today = DateTime(2026, 7, 20).add(Duration(days: i)); // Mon..Sun
        final grid = gridFor(today);
        expect(grid.cells.length % 7, 0,
            reason: 'weekday ${today.weekday} produced a ragged final row');
        for (final row in grid.rows) {
          expect(row.length, 7);
        }
      }
    });

    test('contains exactly CalendarGrid.span real day-cells', () {
      for (var i = 0; i < 7; i++) {
        final today = DateTime(2026, 7, 20).add(Duration(days: i));
        final grid = gridFor(today);
        final realCells = grid.cells.where((c) => !c.isBlank);
        expect(realCells.length, CalendarGrid.span);
      }
    });

    test('leading blanks align today under its weekday column', () {
      // Wednesday 2026-07-22 -> Mon, Tue blank, today in column index 2.
      final wed = DateTime(2026, 7, 22);
      expect(wed.weekday, DateTime.wednesday);

      final grid = gridFor(wed);
      expect(grid.cells[0].isBlank, isTrue);
      expect(grid.cells[1].isBlank, isTrue);
      expect(grid.cells[2].isBlank, isFalse);
      expect(grid.cells[2].isToday, isTrue);
      expect(grid.cells[2].date, wed);
    });

    test('a Monday today needs no leading blanks', () {
      final mon = DateTime(2026, 7, 20);
      expect(mon.weekday, DateTime.monday);

      final grid = gridFor(mon);
      expect(grid.cells.first.isBlank, isFalse);
      expect(grid.cells.first.isToday, isTrue);
    });

    test('exactly one cell is marked today, and it is the first real cell', () {
      final grid = gridFor(DateTime(2026, 7, 23));
      final todays = grid.cells.where((c) => c.isToday).toList();
      expect(todays.length, 1);
      final firstReal = grid.cells.firstWhere((c) => !c.isBlank);
      expect(firstReal.isToday, isTrue);
    });

    test('days run consecutively from today with no gaps', () {
      final today = DateTime(2026, 7, 23);
      final grid = gridFor(today);
      final days = grid.cells
          .where((c) => !c.isBlank)
          .map((c) => c.date!)
          .toList();

      for (var i = 0; i < days.length; i++) {
        expect(days[i], today.add(Duration(days: i)));
      }
    });

    test('spans month and year boundaries correctly', () {
      // A 14-day span from 27 Dec 2026 runs into January 2027:
      // 27–31 Dec is 5 days, so the remaining 9 land on 1–9 Jan.
      final today = DateTime(2026, 12, 27);
      final grid = gridFor(today);
      final days =
          grid.cells.where((c) => !c.isBlank).map((c) => c.date!).toList();

      expect(days.length, CalendarGrid.span,
          reason: 'the dates below assume a 14-day span');
      expect(days.first, DateTime(2026, 12, 27));
      expect(days.last, DateTime(2027, 1, 9));
      expect(CalendarGrid.lastDay(today), DateTime(2027, 1, 9));
    });

    test('ignores the time component of "today"', () {
      final withTime = DateTime(2026, 7, 23, 17, 42, 13);
      final grid = gridFor(withTime);
      final first = grid.cells.firstWhere((c) => !c.isBlank);
      expect(first.date, DateTime(2026, 7, 23));
    });

    test('surfaces per-day event counts', () {
      final today = DateTime(2026, 7, 23);
      final grid = CalendarGrid.build(
        today: today,
        countForDay: (d) => d == today ? 3 : 0,
      );
      final todayCell = grid.cells.firstWhere((c) => c.isToday);
      expect(todayCell.eventCount, 3);
      final others =
          grid.cells.where((c) => !c.isBlank && !c.isToday);
      expect(others.every((c) => c.eventCount == 0), isTrue);
    });
  });

  group('bucketByDay', () {
    test('groups events onto their local calendar day', () {
      final events = [
        CalendarEvent(title: 'A', start: DateTime(2026, 7, 23, 9, 30)),
        CalendarEvent(title: 'B', start: DateTime(2026, 7, 23, 14, 0)),
        CalendarEvent(title: 'C', start: DateTime(2026, 7, 24, 11, 0)),
      ];

      final buckets = bucketByDay(events);
      expect(buckets[DateTime(2026, 7, 23)]!.length, 2);
      expect(buckets[DateTime(2026, 7, 24)]!.length, 1);
      expect(buckets[DateTime(2026, 7, 25)], isNull);
    });

    test('event.day truncates the time component', () {
      final e = CalendarEvent(title: 'X', start: DateTime(2026, 7, 23, 23, 59));
      expect(e.day, DateTime(2026, 7, 23));
    });
  });
}
