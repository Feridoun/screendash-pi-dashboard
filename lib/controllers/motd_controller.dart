import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../models/motd.dart';
import '../services/backend_client.dart';
import 'polling_controller.dart';

/// Polls motd.json and exposes the current banner.
///
/// The artifact carries the notices it replaced as well as the live one, so
/// this also owns *which* of them the banner is showing. The rule is that the
/// device volunteers nothing: it always returns to the current notice, either
/// when the reader stops stepping (the banner's own timer calls [showCurrent])
/// or as soon as a poll brings a new one.
class MotdController extends PollingController {
  final AppConfig config;
  final BackendClient client;

  /// Called when a poll brings a genuinely new notice — not on the first load,
  /// and not when the banner is cleared. Wired to the celebration overlay.
  final VoidCallback? onNoticeArrived;

  MotdController({
    required this.config,
    required this.client,
    this.onNoticeArrived,
  });

  /// Whether we've completed a poll yet. The first notice of the session is the
  /// board catching up, not news — a reboot shouldn't throw a party.
  bool _polledOnce = false;

  @override
  Duration get interval => client.jittered(AppConfig.motdPollInterval);

  MotdFeed _feed = MotdFeed.empty;
  MotdFeed get feed => _feed;

  /// 0 = the notice in force; higher = further back through the history.
  int _index = 0;
  int get index => _index;
  int get count => _feed.length;

  /// The notice on screen — the current one unless someone has stepped back.
  Motd get motd => _feed.at(_index);

  /// Whether the banner is showing the live notice rather than an old one.
  bool get isCurrent => _index == 0;

  bool get canShowOlder => _index < _feed.length - 1;
  bool get canShowNewer => _index > 0;

  /// Step back through superseded notices, and forward again towards the live
  /// one. Both stop at the ends rather than wrapping: the feed has a first and
  /// a last, and running off either would hide that.
  void showOlder() => _showAt(_index + 1);
  void showNewer() => _showAt(_index - 1);
  void showCurrent() => _showAt(0);

  void _showAt(int index) {
    if (index < 0 || index >= _feed.length || index == _index) return;
    _index = index;
    safeNotify();
  }

  @override
  Future<void> poll({bool force = false}) async {
    final result = await client.getJson(config.motdUri, bypassCache: force);
    if (result.notModified) return;

    final feed = MotdFeed.fromJson(result.json!);
    // A new notice takes the screen back, even from someone mid-history: it is
    // the one thing on the wall that may be time-critical.
    final replaced = feed.current.text != _feed.current.text ||
        feed.current.updated != _feed.current.updated;
    _feed = feed;
    if (replaced || _index >= feed.length) _index = 0;
    safeNotify();

    // Celebrate a genuinely new notice. Taking the banner *down* is a change
    // too, but an empty banner is nothing to announce.
    if (replaced && _polledOnce && !feed.current.isEmpty) {
      onNoticeArrived?.call();
    }
    _polledOnce = true;
  }
}
