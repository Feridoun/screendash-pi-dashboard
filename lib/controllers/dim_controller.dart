import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../models/dim_schedule.dart';
import '../services/dim_schedule_store.dart';

enum DisplayState { active, dimmed, blanked }

/// Owns the display power schedule (Phase 2/3).
///
/// Two layers:
///   - A software scrim opacity (0..1) the UI paints over everything, for smooth
///     daytime dimming with no system calls.
///   - Hardware panel power via `vcgencmd display_power`, for a true overnight
///     blank that actually saves power and eliminates burn-in.
///
/// A wall-clock [Timer] is the source of truth (not an AnimationController), so
/// it survives DST changes and month-long uptimes.
///
/// Two manual escapes sit on top of the schedule:
///   - [wake] — mouse movement over a dimmed/blanked screen (or a tap, for
///     touch panels with no hover) relights it for [AppConfig.wakeDuration],
///     then the schedule resumes.
///   - [updateSchedule] — the on-screen dim-schedule modal edits the hours, and
///     the result is written to a small JSON file so it survives a reboot. The
///     [AppConfig] dart-defines remain the defaults behind it.
class DimController extends ChangeNotifier {
  Timer? _timer;
  Timer? _wakeTimer;
  DisplayState _state = DisplayState.active;
  bool _hardwareOn = true;
  bool _awake = false;

  DimSchedule _schedule = DimSchedule.defaults;

  /// Injectable so tests / non-Pi hosts can stub the system call.
  final Future<void> Function(bool on) setHardwarePower;

  /// Where the edited schedule is persisted.
  final DimScheduleStore store;

  DimController({
    Future<void> Function(bool on)? hardwarePower,
    DimScheduleStore? store,
  })  : setHardwarePower = hardwarePower ?? _vcgencmdPower,
        store = store ?? DimScheduleStore();

  DisplayState get state => _state;

  DimSchedule get schedule => _schedule;
  int get activeStartHour => _schedule.activeStartHour;
  int get activeEndHour => _schedule.activeEndHour;
  int get dimmedEndHour => _schedule.dimmedEndHour;
  double get dimmedScrimOpacity => _schedule.dimmedScrimOpacity;

  /// True while a manual wake is holding the panel lit against the schedule.
  bool get isAwake => _awake;

  /// True when the screen is currently covered by any scrim — i.e. a tap would
  /// wake it rather than hit the UI underneath.
  bool get isDark => scrimOpacity > 0;

  /// Opacity of the black scrim the UI overlays. 0 = fully bright.
  double get scrimOpacity {
    if (_awake) return 0.0;
    switch (_state) {
      case DisplayState.active:
        return 0.0;
      case DisplayState.dimmed:
        return _schedule.dimmedScrimOpacity;
      case DisplayState.blanked:
        return 1.0; // fully black in case hardware-off is unavailable (HDMI/host)
    }
  }

  /// Paint the right state immediately from the defaults, start ticking, then
  /// adopt the saved schedule once the disk read lands — boot never blocks on
  /// the filesystem.
  void start() {
    _evaluate();
    _timer = Timer.periodic(AppConfig.dimTick, (_) => _evaluate());
    unawaited(_restore());
  }

  Future<void> _restore() async {
    final saved = await store.load();
    if (saved == null || saved == _schedule) return;
    _schedule = saved;
    notifyListeners();
    await _evaluate();
  }

  /// Relight the panel for [AppConfig.wakeDuration]. Waking again while already
  /// awake restarts the countdown rather than stacking timers — which is what
  /// keeps a continuously-moving mouse from letting the screen drop away.
  void wake() {
    _wakeTimer?.cancel();
    _wakeTimer = Timer(AppConfig.wakeDuration, _endWake);
    if (_awake) return;
    _awake = true;
    notifyListeners();
    unawaited(_applyHardware());
  }

  /// Drop back to the schedule immediately, cancelling any wake window.
  void sleepNow() {
    _wakeTimer?.cancel();
    _wakeTimer = null;
    _endWake();
  }

  void _endWake() {
    if (!_awake) return;
    _awake = false;
    notifyListeners();
    // Re-read the clock: the schedule may have moved on during the wake window.
    unawaited(_evaluate());
  }

  /// A schedule is usable only if the three boundaries run forward through the
  /// day: bright, then dimmed, then blanked until the next bright window.
  static bool isValidSchedule(int activeStart, int activeEnd, int dimmedEnd) =>
      DimSchedule.isValidHours(activeStart, activeEnd, dimmedEnd);

  /// Apply an edited schedule and write it to disk. Returns false (and changes
  /// nothing) if the hours don't run forward through the day.
  bool updateSchedule({
    int? activeStartHour,
    int? activeEndHour,
    int? dimmedEndHour,
    double? dimmedScrimOpacity,
  }) {
    final next = _schedule.copyWith(
      activeStartHour: activeStartHour,
      activeEndHour: activeEndHour,
      dimmedEndHour: dimmedEndHour,
      dimmedScrimOpacity: dimmedScrimOpacity,
    );
    if (!next.isValid) return false;

    _schedule = next;
    notifyListeners();
    unawaited(_evaluate());
    unawaited(store.save(next));
    return true;
  }

  /// Restore the compile-time defaults from [AppConfig] and forget the saved
  /// override entirely, so a later dart-define change takes effect.
  void resetSchedule() {
    _schedule = DimSchedule.defaults;
    notifyListeners();
    unawaited(_evaluate());
    unawaited(store.clear());
  }

  DisplayState _scheduleFor(DateTime now) {
    final h = now.hour;
    if (h >= _schedule.activeStartHour && h < _schedule.activeEndHour) {
      return DisplayState.active;
    }
    if (h >= _schedule.activeEndHour && h < _schedule.dimmedEndHour) {
      return DisplayState.dimmed;
    }
    return DisplayState.blanked;
  }

  Future<void> _evaluate() async {
    final next = _scheduleFor(DateTime.now());
    if (next != _state) {
      _state = next;
      notifyListeners();
    }
    await _applyHardware();
  }

  /// Drive the panel only on the boundary between "should be lit" and not — a
  /// wake window counts as lit even in the middle of the blanked period.
  Future<void> _applyHardware() async {
    final shouldPower = _awake || _state != DisplayState.blanked;
    if (shouldPower == _hardwareOn) return;
    _hardwareOn = shouldPower;
    try {
      await setHardwarePower(shouldPower);
    } catch (e) {
      // Non-fatal: on an HDMI monitor or the host machine there may be no
      // vcgencmd. The software scrim still blanks the screen visually.
      debugPrint('[DimController] hardware power call failed: $e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _wakeTimer?.cancel();
    super.dispose();
  }
}

/// Default hardware control: toggle HDMI/DSI panel power via vcgencmd.
/// For a backlight-capable DSI panel, swap this for a write to
/// `/sys/class/backlight/<name>/brightness` (see docs/dashboard-plan.md, Phase 2).
Future<void> _vcgencmdPower(bool on) async {
  await Process.run('vcgencmd', ['display_power', on ? '1' : '0']);
}
