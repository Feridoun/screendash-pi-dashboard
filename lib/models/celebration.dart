import 'package:flutter/foundation.dart';

/// What just arrived on the board.
enum CelebrationKind { photos, notice }

/// One "something new landed" moment, shown briefly over the dashboard.
///
/// [serial] exists so two celebrations of the same kind back-to-back are still
/// distinct values: the overlay keys its animation off it, and without it a
/// second notice arriving during the first one's fade would silently reuse the
/// spent animation instead of restarting.
@immutable
class Celebration {
  const Celebration({
    required this.kind,
    required this.count,
    required this.serial,
  });

  final CelebrationKind kind;

  /// How many things arrived — photos land in batches, notices one at a time.
  final int count;

  final int serial;

  @override
  bool operator ==(Object other) =>
      other is Celebration &&
      other.kind == kind &&
      other.count == count &&
      other.serial == serial;

  @override
  int get hashCode => Object.hash(kind, count, serial);

  @override
  String toString() => 'Celebration(${kind.name} x$count #$serial)';
}
