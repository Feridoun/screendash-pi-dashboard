import 'package:flutter_test/flutter_test.dart';

import 'package:screendash/models/weather.dart';

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Map<String, dynamic> _payload(List<Map<String, dynamic>> days) => {
      'updated': '2026-08-03T09:40:00.000Z',
      'place': 'Anytown',
      'days': days,
    };

void main() {
  group('WeatherOutlook.fromJson', () {
    test('parses a well-formed two-day payload', () {
      final outlook = WeatherOutlook.fromJson(_payload([
        {
          'date': '2026-08-03',
          'code': 3,
          'high': 21,
          'low': 13,
          'rain': 20,
          'condition': 'Cloudy',
        },
        {
          'date': '2026-08-04',
          'code': 61,
          'high': 18,
          'low': 12,
          'rain': 70,
          'condition': 'Light rain',
        },
      ]));

      expect(outlook.days, hasLength(2));
      expect(outlook.place, 'Anytown');
      expect(outlook.updated, isNotNull);

      final today = outlook.days.first;
      expect(today.date, '2026-08-03');
      expect(today.code, 3);
      expect(today.high, 21);
      expect(today.low, 13);
      expect(today.rain, 20);
      expect(today.condition, 'Cloudy');
    });

    test('a day with no rain probability still renders', () {
      final outlook = WeatherOutlook.fromJson(_payload([
        {'date': '2026-08-03', 'code': 0, 'high': 24, 'low': 15},
      ]));

      expect(outlook.days, hasLength(1));
      expect(outlook.days.single.rain, isNull);
      expect(outlook.days.single.condition, '');
    });

    test('rounds fractional temperatures rather than dropping them', () {
      final outlook = WeatherOutlook.fromJson(_payload([
        {'date': '2026-08-03', 'high': 20.6, 'low': 12.4, 'rain': 33.3},
      ]));

      expect(outlook.days.single.high, 21);
      expect(outlook.days.single.low, 12);
      expect(outlook.days.single.rain, 33);
    });

    test('drops a day carrying no temperature at all', () {
      final outlook = WeatherOutlook.fromJson(_payload([
        {'date': '2026-08-03', 'code': 3, 'rain': 20},
        {'date': '2026-08-04', 'code': 61, 'high': 18, 'low': 12},
      ]));

      expect(outlook.days, hasLength(1));
      expect(outlook.days.single.date, '2026-08-04');
    });

    test('garbage fields degrade to nulls instead of throwing', () {
      final outlook = WeatherOutlook.fromJson(_payload([
        {
          'date': '2026-08-03',
          'code': 'sunny',
          'high': 19,
          'low': null,
          'rain': 'lots',
        },
      ]));

      final day = outlook.days.single;
      expect(day.code, isNull);
      expect(day.high, 19);
      expect(day.low, isNull);
      expect(day.rain, isNull);
    });

    test('an empty or missing days list yields the empty outlook', () {
      expect(WeatherOutlook.fromJson(_payload([])).isEmpty, isTrue);
      expect(WeatherOutlook.fromJson(const {}).isEmpty, isTrue);
    });
  });

  group('staleness', () {
    // The artifact is served from storage, so a backend that stops syncing keeps
    // handing out the same forecast forever. Days-old weather must not be shown
    // as today's.
    final now = DateTime(2026, 8, 3, 9, 40);

    test('a forecast starting today is fresh', () {
      final outlook = WeatherOutlook.fromJson(_payload([
        {'date': _isoDate(now), 'high': 21, 'low': 13},
        {'date': _isoDate(now.add(const Duration(days: 1))), 'high': 18, 'low': 12},
      ]));

      expect(outlook.isStale(now: now), isFalse);
    });

    test("yesterday's forecast is stale", () {
      final yesterday = now.subtract(const Duration(days: 1));
      final outlook = WeatherOutlook.fromJson(_payload([
        {'date': _isoDate(yesterday), 'high': 21, 'low': 13},
        {'date': _isoDate(now), 'high': 18, 'low': 12},
      ]));

      expect(outlook.isStale(now: now), isTrue,
          reason: 'even though it contains today, it is labelled as tomorrow');
    });

    test('a forecast that has not started yet is stale', () {
      final tomorrow = now.add(const Duration(days: 1));
      final outlook = WeatherOutlook.fromJson(_payload([
        {'date': _isoDate(tomorrow), 'high': 18, 'low': 12},
      ]));

      expect(outlook.isStale(now: now), isTrue);
    });

    test('the empty outlook is stale', () {
      expect(WeatherOutlook.empty.isStale(now: now), isTrue);
    });

    test('single-digit months and days compare correctly', () {
      // A naive "$year-$month-$day" would produce 2026-1-5 and never match.
      final jan = DateTime(2026, 1, 5, 12);
      final outlook = WeatherOutlook.fromJson(_payload([
        {'date': '2026-01-05', 'high': 6, 'low': 1},
      ]));

      expect(outlook.isStale(now: jan), isFalse);
    });
  });
}
