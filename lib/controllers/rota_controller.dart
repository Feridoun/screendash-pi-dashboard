import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../models/rota.dart';
import '../services/backend_client.dart';
import 'polling_controller.dart';

/// Polls rota.json and exposes the day the rota card should show.
class RotaController extends PollingController {
  final AppConfig config;
  final BackendClient client;

  RotaController({required this.config, required this.client});

  @override
  Duration get interval => client.jittered(AppConfig.rotaPollInterval);

  RotaFeed _feed = RotaFeed.empty;
  RotaFeed get feed => _feed;

  /// How many days the card shows.
  static const int shownCount = 3;

  /// The days worth putting on the wall — today and the next few — or empty
  /// when nothing published covers today: the feed is stale, or there is no
  /// rota yet. Then the card shows its placeholder rather than yesterday's
  /// roster as today's.
  ///
  /// Weekend days are skipped unless someone actually works them — the roster
  /// says which — so a Friday shows Fri · Mon · Tue and a Saturday visitor
  /// sees who is in next rather than a column of "Off". The list is shorter
  /// than [count] only at the end of the published window.
  ///
  /// [now] is injectable so tests don't have to wait for a weekend.
  List<RotaDay> shownDays({DateTime? now, int count = shownCount}) {
    final t = now ?? DateTime.now();
    final today = DateTime(t.year, t.month, t.day);
    final actual = feed.dayFor(today);
    if (actual == null) return const [];

    final days = <RotaDay>[];
    // Built through the constructor rather than Duration arithmetic so a
    // clock change on the way can't land at 23:00 the day before.
    for (var i = 0; days.length < count; i++) {
      final date = DateTime(today.year, today.month, today.day + i);
      final day = feed.dayFor(date);
      if (day == null) break; // past the published window
      if (date.weekday >= DateTime.saturday && !day.anyoneIn) continue;
      days.add(day);
    }
    // A weekend at the very end of the window, with Monday not published:
    // the weekend day itself, rather than nothing.
    return days.isEmpty ? [actual] : days;
  }

  @override
  Future<void> poll({bool force = false}) async {
    final result = await client.getJson(config.rotaUri, bypassCache: force);
    if (result.notModified) return;
    _feed = RotaFeed.fromJson(result.json!);
    safeNotify();
  }

  /// Ask the backend to re-read the rota sheet, then pull the result. Same
  /// two-hop reasoning as [DirectoryController.refreshFromSource]: rota.json
  /// is regenerated on a cron, so a poll alone can only ever see the last one,
  /// and someone who has just booked leave on their phone and walked over to
  /// the board expects the refresh dot to show it.
  Future<void> refreshFromSource() async {
    try {
      await client.post(config.syncRotaUri);
    } catch (e) {
      debugPrint('[RotaController] rota sync trigger failed: $e');
    }
    await refreshNow();
  }
}
