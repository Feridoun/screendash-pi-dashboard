import 'package:flutter/foundation.dart';

/// How a person's day reads at a glance — the four things a dot can say.
///
/// The backend has already resolved the weekly pattern against leave, study
/// days and meetings into one of these per person per day; the wording that
/// goes beside it arrives as [RotaPerson.label]. The app only picks colours.
enum RotaStatus {
  /// In as usual.
  present,

  /// Working, but not on the ward for some or all of the day — a meeting
  /// window, or working remotely. Read the label.
  partial,

  /// Not working today when they usually would be: leave, study, sick.
  away,

  /// Not one of their days.
  off;

  /// The wire form is the backend's word; anything this build doesn't know
  /// still shows as *something* — amber says "read the label" — rather than
  /// hiding a person because the vocabulary moved on before the app did.
  static RotaStatus parse(String? value) => switch (value) {
        'in' => present,
        'partial' => partial,
        'away' => away,
        'off' => off,
        _ => partial,
      };
}

/// One person's entry for one day, as the backend resolved it.
@immutable
class RotaPerson {
  final String name;
  final String? role;
  final RotaStatus status;

  /// The main word for the day: hours when in ("8–6"), otherwise why not
  /// ("Study leave", "Off").
  final String label;

  /// A caveat on a working day ("Meeting 10–12"), or what a window on a day
  /// off is for. Absent for a plain day.
  final String? detail;

  /// How they can be reached while away: "phone", "email", "none".
  final String? contact;

  const RotaPerson({
    required this.name,
    required this.status,
    required this.label,
    this.role,
    this.detail,
    this.contact,
  });

  factory RotaPerson.fromJson(Map<String, dynamic> json) => RotaPerson(
        name: json['name'] as String? ?? '',
        role: json['role'] as String?,
        status: RotaStatus.parse(json['status'] as String?),
        label: json['label'] as String? ?? '',
        detail: json['detail'] as String?,
        contact: json['contact'] as String?,
      );
}

/// Everyone on the roster for one calendar day, in the order the sheet lists
/// them. The count is whatever the rotation brought — this build has no idea
/// how many doctors there are, and must not.
@immutable
class RotaDay {
  /// Local calendar date, `YYYY-MM-DD` as the backend computed it in the
  /// office's own timezone. A string for the same reason [WeatherDay.date]
  /// is: it is a date, not an instant.
  final String date;
  final List<RotaPerson> people;

  const RotaDay({required this.date, required this.people});

  /// Whether anyone is working at all — what decides if a weekend day is
  /// worth showing or the card should look ahead to Monday.
  bool get anyoneIn => people.any((p) => p.status != RotaStatus.off);

  /// The date as a local midnight, for formatting a weekday name. Display
  /// only; nothing compares against it.
  DateTime get day => DateTime.parse(date);

  factory RotaDay.fromJson(Map<String, dynamic> json) => RotaDay(
        date: json['date'] as String? ?? '',
        people: (json['people'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(RotaPerson.fromJson)
            .where((p) => p.name.isNotEmpty)
            .toList(growable: false),
      );
}

/// The rota.json payload: an update timestamp plus the next fortnight, day by
/// day, fully resolved.
@immutable
class RotaFeed {
  final DateTime? updated;
  final List<RotaDay> days;

  const RotaFeed({required this.updated, required this.days});

  static const RotaFeed empty = RotaFeed(updated: null, days: <RotaDay>[]);

  bool get isEmpty => days.isEmpty;

  /// The published entry for [day] (any time of day), or null if the feed
  /// doesn't cover it — which is also how a stale artifact is detected: the
  /// window always starts at the backend's "today", so a feed that stopped
  /// updating stops covering the device's.
  RotaDay? dayFor(DateTime day) {
    final iso = isoDate(day);
    for (final d in days) {
      if (d.date == iso) return d;
    }
    return null;
  }

  /// `YYYY-MM-DD` of a local [DateTime], the form the backend publishes.
  static String isoDate(DateTime day) {
    final y = day.year.toString().padLeft(4, '0');
    final m = day.month.toString().padLeft(2, '0');
    final d = day.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  factory RotaFeed.fromJson(Map<String, dynamic> json) => RotaFeed(
        updated: DateTime.tryParse(json['updated'] as String? ?? '')?.toLocal(),
        days: (json['days'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(RotaDay.fromJson)
            .where((d) => d.date.isNotEmpty)
            .toList(growable: false),
      );
}
