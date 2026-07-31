import 'package:flutter/foundation.dart';

/// A single meeting, flattened by the backend into events.json.
@immutable
class CalendarEvent {
  final String title;
  final DateTime start;
  final DateTime? end;
  final String? room;

  const CalendarEvent({
    required this.title,
    required this.start,
    this.end,
    this.room,
  });

  /// The calendar day this event falls on (local, midnight-truncated).
  DateTime get day => DateTime(start.year, start.month, start.day);

  factory CalendarEvent.fromJson(Map<String, dynamic> json) => CalendarEvent(
        title: json['title'] as String? ?? 'Untitled',
        // Stored as UTC ISO-8601; render in local time in the UI.
        start: DateTime.tryParse(json['start'] as String? ?? '')?.toLocal() ??
            DateTime.now(),
        end: DateTime.tryParse(json['end'] as String? ?? '')?.toLocal(),
        room: json['room'] as String?,
      );
}

/// The events.json payload: an update timestamp plus the next N meetings.
@immutable
class CalendarFeed {
  final DateTime? updated;
  final List<CalendarEvent> events;

  const CalendarFeed({required this.updated, required this.events});

  static const CalendarFeed empty =
      CalendarFeed(updated: null, events: <CalendarEvent>[]);

  factory CalendarFeed.fromJson(Map<String, dynamic> json) => CalendarFeed(
        updated: DateTime.tryParse(json['updated'] as String? ?? ''),
        events: (json['events'] as List<dynamic>? ?? const [])
            .map((e) => CalendarEvent.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
      );
}
