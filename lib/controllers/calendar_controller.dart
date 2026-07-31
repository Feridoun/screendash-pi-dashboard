import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../models/calendar_event.dart';
import '../models/calendar_grid.dart';
import '../services/backend_client.dart';
import 'polling_controller.dart';

/// Polls events.json and exposes both the 14-day grid and the agenda.
class CalendarController extends PollingController {
  final AppConfig config;
  final BackendClient client;

  CalendarController({required this.config, required this.client});

  @override
  Duration get interval => client.jittered(AppConfig.eventsPollInterval);

  CalendarFeed _feed = CalendarFeed.empty;

  /// Events bucketed by calendar day (recomputed on each feed update).
  Map<DateTime, List<CalendarEvent>> _byDay = const {};

  /// Upcoming events, filtered to those not already well past, soonest first.
  /// Drives the agenda list beneath the grid.
  List<CalendarEvent> get upcoming {
    final now = DateTime.now();
    final list = _feed.events
        .where((e) => e.start.isAfter(now.subtract(const Duration(minutes: 5))))
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return list;
  }

  /// The rolling 14-day grid anchored at today, with per-day event counts.
  CalendarGrid get grid => CalendarGrid.build(
        today: DateTime.now(),
        countForDay: (d) => _byDay[d]?.length ?? 0,
      );

  @override
  Future<void> poll({bool force = false}) async {
    final result = await client.getJson(config.eventsUri, bypassCache: force);
    if (result.notModified) return;
    _feed = CalendarFeed.fromJson(result.json!);
    _byDay = bucketByDay(_feed.events);
    safeNotify();
  }

  /// Ask the backend to re-read Google Calendar, then pull the result. Same
  /// two-hop reasoning as [DirectoryController.refreshFromSource]: events.json
  /// is regenerated on a cron, so a poll alone can only ever see the last one.
  Future<void> refreshFromSource() async {
    try {
      await client.post(config.syncCalendarUri);
    } catch (e) {
      debugPrint('[CalendarController] calendar sync trigger failed: $e');
    }
    await refreshNow();
  }
}
