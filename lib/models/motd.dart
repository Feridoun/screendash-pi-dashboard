import 'package:flutter/foundation.dart';

/// Message-of-the-day banner content, pulled from motd.json.
///
/// The backend can carry a light style hint (`accent`) so the office can recolor
/// the banner without an app redeploy. Unknown/blank values fall back gracefully.
@immutable
class Motd {
  final String text;
  final String? accentHex; // e.g. "#E8A33D"; null -> use theme accent
  final DateTime? updated; // when the backend published it; null if unstated

  const Motd({required this.text, this.accentHex, this.updated});

  static const Motd empty = Motd(text: '');

  bool get isEmpty => text.trim().isEmpty;

  factory Motd.fromJson(Map<String, dynamic> json) => Motd(
        text: json['text'] as String? ?? '',
        accentHex: json['accent'] as String?,
        updated: DateTime.tryParse(json['updated'] as String? ?? '')?.toLocal(),
      );
}

/// The current notice plus the ones it replaced, newest first.
///
/// The backend keeps a capped `history` array inside motd.json, so a notice
/// posted while nobody was looking stays reachable from the banner's cycle
/// controls. A cleared banner clears the whole feed: history is there to catch
/// up on what's been said, not to resurrect a notice the office took down.
@immutable
class MotdFeed {
  /// Newest first — `notices.first` is what the banner shows by default.
  final List<Motd> notices;

  const MotdFeed(this.notices);

  static const MotdFeed empty = MotdFeed(<Motd>[]);

  bool get isEmpty => notices.isEmpty;
  int get length => notices.length;

  /// The notice in force right now, or [Motd.empty] when the banner is clear.
  Motd get current => notices.isEmpty ? Motd.empty : notices.first;

  /// The notice at [index], clamped so a stale index can never throw.
  Motd at(int index) {
    if (notices.isEmpty) return Motd.empty;
    return notices[index.clamp(0, notices.length - 1)];
  }

  factory MotdFeed.fromJson(Map<String, dynamic> json) {
    final current = Motd.fromJson(json);
    if (current.isEmpty) return empty;

    final history = (json['history'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(Motd.fromJson)
            .where((m) => !m.isEmpty) ??
        const <Motd>[];

    return MotdFeed(List.unmodifiable([current, ...history]));
  }
}
