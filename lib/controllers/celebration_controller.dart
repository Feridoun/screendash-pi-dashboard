import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../models/celebration.dart';

/// Holds the one celebration currently on screen, if any.
///
/// The photo and notice controllers report arrivals here (wired up in main.dart)
/// rather than reaching into the UI themselves, so "what counts as new" stays
/// with the controller that polls, and "how it looks" stays with the overlay.
///
/// Only one celebration shows at a time: a second arrival replaces the first
/// rather than queueing behind it. On a wall display the point is to catch an
/// eye passing by, and a backlog of stale party popper animations would just
/// delay the news.
class CelebrationController extends ChangeNotifier {
  Celebration? _current;
  Timer? _timer;
  int _serial = 0;

  /// The celebration on screen, or null when the board is idle.
  Celebration? get current => _current;

  bool get isCelebrating => _current != null;

  /// New photos finished downloading. [count] is how many landed in this batch.
  void photosArrived(int count) {
    if (count <= 0) return;
    _show(CelebrationKind.photos, count);
  }

  /// A new notice replaced the one on the banner.
  void noticeArrived() => _show(CelebrationKind.notice, 1);

  void _show(CelebrationKind kind, int count) {
    _timer?.cancel();
    _current = Celebration(kind: kind, count: count, serial: ++_serial);
    notifyListeners();
    _timer = Timer(AppConfig.celebrationDuration, dismiss);
  }

  /// Take it down early — the overlay has run its course, or a test wants it gone.
  void dismiss() {
    _timer?.cancel();
    _timer = null;
    if (_current == null) return;
    _current = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
