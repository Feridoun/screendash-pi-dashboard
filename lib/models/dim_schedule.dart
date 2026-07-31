import '../config/app_config.dart';

/// The four numbers that describe the display's day: when it goes bright, when
/// it soft-dims, when the panel powers off, and how heavy the evening scrim is.
///
/// Hours are local 24h boundaries in the range 0..24 (24 meaning "midnight at
/// the end of this day"), and must run forward: bright → dimmed → off.
class DimSchedule {
  const DimSchedule({
    required this.activeStartHour,
    required this.activeEndHour,
    required this.dimmedEndHour,
    required this.dimmedScrimOpacity,
  });

  final int activeStartHour;
  final int activeEndHour;
  final int dimmedEndHour;
  final double dimmedScrimOpacity;

  /// The compile-time schedule from the dart-defines — what a fresh device uses
  /// and what "Reset" returns to.
  static const DimSchedule defaults = DimSchedule(
    activeStartHour: AppConfig.activeStartHour,
    activeEndHour: AppConfig.activeEndHour,
    dimmedEndHour: AppConfig.dimmedEndHour,
    dimmedScrimOpacity: AppConfig.dimmedScrimOpacity,
  );

  static bool isValidHours(int activeStart, int activeEnd, int dimmedEnd) =>
      activeStart >= 0 &&
      activeStart < activeEnd &&
      activeEnd <= dimmedEnd &&
      dimmedEnd <= 24;

  bool get isValid =>
      isValidHours(activeStartHour, activeEndHour, dimmedEndHour);

  DimSchedule copyWith({
    int? activeStartHour,
    int? activeEndHour,
    int? dimmedEndHour,
    double? dimmedScrimOpacity,
  }) {
    return DimSchedule(
      activeStartHour: activeStartHour ?? this.activeStartHour,
      activeEndHour: activeEndHour ?? this.activeEndHour,
      dimmedEndHour: dimmedEndHour ?? this.dimmedEndHour,
      dimmedScrimOpacity:
          (dimmedScrimOpacity ?? this.dimmedScrimOpacity).clamp(0.0, 1.0),
    );
  }

  Map<String, dynamic> toJson() => {
        'activeStartHour': activeStartHour,
        'activeEndHour': activeEndHour,
        'dimmedEndHour': dimmedEndHour,
        'dimmedScrimOpacity': dimmedScrimOpacity,
      };

  /// Returns null for anything malformed, out of range, or out of order — a
  /// half-written file on a yanked SD card must not brick the schedule, it
  /// should just fall back to [defaults].
  static DimSchedule? fromJson(Map<String, dynamic> json) {
    final start = _asInt(json['activeStartHour']);
    final activeEnd = _asInt(json['activeEndHour']);
    final dimmedEnd = _asInt(json['dimmedEndHour']);
    final opacity = _asDouble(json['dimmedScrimOpacity']);
    if (start == null || activeEnd == null || dimmedEnd == null) return null;
    if (!isValidHours(start, activeEnd, dimmedEnd)) return null;

    return DimSchedule(
      activeStartHour: start,
      activeEndHour: activeEnd,
      dimmedEndHour: dimmedEnd,
      dimmedScrimOpacity:
          (opacity ?? defaults.dimmedScrimOpacity).clamp(0.0, 1.0),
    );
  }

  static int? _asInt(Object? v) => v is num ? v.toInt() : null;
  static double? _asDouble(Object? v) => v is num ? v.toDouble() : null;

  @override
  bool operator ==(Object other) =>
      other is DimSchedule &&
      other.activeStartHour == activeStartHour &&
      other.activeEndHour == activeEndHour &&
      other.dimmedEndHour == dimmedEndHour &&
      other.dimmedScrimOpacity == dimmedScrimOpacity;

  @override
  int get hashCode => Object.hash(
      activeStartHour, activeEndHour, dimmedEndHour, dimmedScrimOpacity);

  @override
  String toString() => 'DimSchedule($activeStartHour→$activeEndHour→'
      '$dimmedEndHour, scrim ${dimmedScrimOpacity.toStringAsFixed(2)})';
}
