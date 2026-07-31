import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../models/directory_entry.dart';
import '../services/backend_client.dart';
import 'polling_controller.dart';

/// Polls directory.json and exposes the grouped office directory.
class DirectoryController extends PollingController {
  final AppConfig config;
  final BackendClient client;

  DirectoryController({required this.config, required this.client});

  @override
  Duration get interval => client.jittered(AppConfig.directoryPollInterval);

  DirectoryFeed _feed = DirectoryFeed.empty;
  DirectoryFeed get feed => _feed;

  /// Groups that actually have people, preserving backend order.
  List<DirectoryGroup> get groups =>
      _feed.groups.where((g) => g.people.isNotEmpty).toList(growable: false);

  bool get hasEntries => groups.isNotEmpty;

  @override
  Future<void> poll({bool force = false}) async {
    final result = await client.getJson(config.directoryUri, bypassCache: force);
    if (result.notModified) return;
    _feed = DirectoryFeed.fromJson(result.json!);
    safeNotify();
  }

  /// Ask the backend to re-read the Google Sheet, then pull the result.
  ///
  /// Polling alone can't surface a sheet edit: directory.json is only
  /// regenerated on the backend's 15-minute cron, so until that fires we would
  /// re-download the identical file however often we asked. This drives the
  /// first hop as well as the second, which is what the refresh button means.
  ///
  /// A failed trigger is not fatal — we still poll, and a stale directory is
  /// better than an empty one.
  Future<void> refreshFromSource() async {
    try {
      await client.post(config.syncDirectoryUri);
    } catch (e) {
      debugPrint('[DirectoryController] sheet sync trigger failed: $e');
    }
    await refreshNow();
  }
}
