import 'dart:async';

import 'package:flutter/foundation.dart';

/// Shared scaffolding for the "poll an artifact on a timer, fail soft" pattern.
///
/// Subclasses implement [poll]; this class owns the timer lifecycle and the
/// convention that a failed poll leaves the last-good state untouched.
abstract class PollingController extends ChangeNotifier {
  Timer? _timer;
  bool _disposed = false;

  /// Whether the most recent poll succeeded. Drives the UI's connectivity dot.
  bool get online => _online;
  bool _online = false;

  /// The interval between polls. Implementations typically jitter this.
  Duration get interval;

  /// Do one unit of work. Should throw on failure (caught here) and must not
  /// mutate visible state on the failure path — keep the last-good value.
  ///
  /// [force] marks a poll the user asked for by hand, where a cached "nothing
  /// changed" is the wrong answer — implementations should bypass their caches.
  Future<void> poll({bool force = false});

  /// Start polling immediately, then on a repeating (jittered) schedule.
  void start() {
    _tick(); // fire once now so the screen isn't blank on boot
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(interval, () {
      _tick();
      if (!_disposed) _schedule(); // re-jitter each cycle
    });
  }

  /// Poll right now instead of waiting for the timer, then restart the
  /// schedule from this moment. For a manual "refresh" action.
  Future<void> refreshNow() async {
    await _tick(force: true);
    if (!_disposed) _schedule();
  }

  Future<void> _tick({bool force = false}) async {
    try {
      await poll(force: force);
      _setOnline(true);
    } catch (e, st) {
      // Fail soft: log, keep last-good state, mark offline for the status dot.
      debugPrint('[${runtimeType.toString()}] poll failed: $e\n$st');
      _setOnline(false);
    }
  }

  void _setOnline(bool value) {
    if (_online != value && !_disposed) {
      _online = value;
      notifyListeners();
    }
  }

  /// Notify listeners only if still alive (avoids "used after dispose" errors
  /// when a poll resolves after teardown).
  @protected
  void safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
