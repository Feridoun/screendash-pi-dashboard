import 'package:flutter/foundation.dart';

/// One day of the outlook, as flattened by the backend.
///
/// The backend sends both a raw WMO [code] and its English [condition]: the
/// wording is the backend's so it can be changed without an app redeploy, while
/// the icon is chosen from the code app-side, because icons aren't strings.
@immutable
class WeatherDay {
  /// Local calendar date, `YYYY-MM-DD` as the backend computed it in the
  /// office's own timezone. Kept as a string rather than a DateTime because it
  /// is a *date*, not an instant — parsing it to local midnight and back is a
  /// round trip through exactly the ambiguity we asked the backend to resolve.
  final String date;

  /// WMO weather code, or null if the backend couldn't supply one.
  final int? code;

  /// Daily high/low in whole degrees Celsius. Either may be missing.
  final int? high;
  final int? low;

  /// Chance of precipitation, 0–100, or null if unstated.
  final int? rain;

  /// English description, e.g. "Light rain". Empty when the code is unmapped.
  final String condition;

  const WeatherDay({
    required this.date,
    this.code,
    this.high,
    this.low,
    this.rain,
    this.condition = '',
  });

  /// Whether there is anything worth drawing a row for.
  bool get hasTemperature => high != null || low != null;

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return null;
  }

  factory WeatherDay.fromJson(Map<String, dynamic> json) => WeatherDay(
        date: json['date'] as String? ?? '',
        code: _asInt(json['code']),
        high: _asInt(json['high']),
        low: _asInt(json['low']),
        rain: _asInt(json['rain']),
        condition: json['condition'] as String? ?? '',
      );
}

/// The two-day outlook pulled from weather.json.
///
/// The artifact is served from storage, so a backend that loses its upstream
/// keeps handing out the *last good* forecast indefinitely. That is the right
/// behaviour for photos and a directory, and the wrong one here: a forecast is
/// only a fact about a particular day. [isStale] is how the strip knows to say
/// nothing rather than to state yesterday's weather as today's.
@immutable
class WeatherOutlook {
  final List<WeatherDay> days;

  /// Where the forecast is for. Display label only; may be empty.
  final String place;

  /// When the backend published it; null if unstated.
  final DateTime? updated;

  const WeatherOutlook({
    required this.days,
    this.place = '',
    this.updated,
  });

  static const WeatherOutlook empty = WeatherOutlook(days: <WeatherDay>[]);

  bool get isEmpty => days.isEmpty;

  /// True when the first day published is no longer today — the forecast has
  /// rolled over, or the backend stopped updating and this is history.
  ///
  /// [now] is injectable so tests don't have to wait for midnight.
  bool isStale({DateTime? now}) {
    if (days.isEmpty) return true;
    final today = now ?? DateTime.now();
    final y = today.year.toString().padLeft(4, '0');
    final m = today.month.toString().padLeft(2, '0');
    final d = today.day.toString().padLeft(2, '0');
    return days.first.date != '$y-$m-$d';
  }

  factory WeatherOutlook.fromJson(Map<String, dynamic> json) {
    final days = (json['days'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(WeatherDay.fromJson)
            .where((d) => d.hasTemperature)
            .toList(growable: false) ??
        const <WeatherDay>[];

    if (days.isEmpty) return empty;

    return WeatherOutlook(
      days: List.unmodifiable(days),
      place: json['place'] as String? ?? '',
      updated: DateTime.tryParse(json['updated'] as String? ?? '')?.toLocal(),
    );
  }
}
