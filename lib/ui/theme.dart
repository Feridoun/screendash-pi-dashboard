import 'package:flutter/material.dart';

/// Dashboard theme — a dark "always-on display" identity tuned for glanceability
/// from across a room. Deep warm-slate ground with a phosphor-amber accent.
class DashTheme {
  const DashTheme._();

  // Temporary low-strain palette (charcoal/amber) — swap back to the
  // warm-slate defaults above when done evaluating.
  static const Color bg = Color(0xFF121212);
  static const Color surface = Color(0xFF1A1A1A);
  static const Color surfaceAlt = Color(0xFF242424);
  static const Color line = Color(0xFF2A2A2A);
  static const Color ink = Color(0xFFE0E0E0);
  static const Color inkSoft = Color(0xFFD0D0D0);
  static const Color inkFaint = Color(0xFF7D7D7D);
  static const Color accent = Color(0xFFFFC107);
  static const Color online = Color(0xFF7FB98A);
  static const Color offline = Color(0xFFE08B6F);

  /// The in-between of [online] and [offline]: a muted sand at their
  /// softness. The full-strength [accent] read brighter than the green and
  /// red either side of it, so a WFH or clinic day outshone everyone in.
  static const Color partial = Color(0xFFCAAD73);

  /// The text face, pinned rather than left to the platform.
  ///
  /// Flutter's Typography would pick this same name on Linux and "Segoe UI" on
  /// Windows. Naming it here costs nothing on the Pi and makes a developer's
  /// screen render the same face as the wall, which is the only place the
  /// layout is ever actually judged. Both are bundled, so this always resolves.
  static const String _fontFamily = 'Roboto';

  /// Consulted only for characters [_fontFamily] cannot draw.
  ///
  /// Order is load-bearing. NotoColorEmoji has no Latin coverage, so it has to
  /// sit behind a family that does -- if it is ever the first name that
  /// resolves, it becomes the face for every glyph and the dashboard renders
  /// blank. That is not hypothetical: it is exactly what happened when this
  /// list was added while the primary family was a name no font on the Pi
  /// supplied.
  static const List<String> _fontFallback = ['NotoColorEmoji'];

  static ThemeData build() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: base.colorScheme.copyWith(
        surface: surface,
        primary: accent,
        onSurface: ink,
      ),
      // Applied at the theme root rather than per-widget: the fallback list is
      // inherited through TextStyle.merge, so the many widgets that pass a bare
      // TextStyle(fontSize: ...) pick it up without naming it. Anything built
      // with inherit: false would opt out -- nothing currently does.
      textTheme: base.textTheme.apply(
        bodyColor: ink,
        displayColor: ink,
        fontFamily: _fontFamily,
        fontFamilyFallback: _fontFallback,
      ),
    );
  }

  /// Parse a "#RRGGBB" hex string to a Color, or null if malformed.
  static Color? parseHex(String? hex) {
    if (hex == null) return null;
    final cleaned = hex.replaceFirst('#', '').trim();
    if (cleaned.length != 6) return null;
    final value = int.tryParse(cleaned, radix: 16);
    if (value == null) return null;
    return Color(0xFF000000 | value);
  }
}
