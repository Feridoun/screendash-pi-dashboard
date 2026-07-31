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

  static ThemeData build() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: base.colorScheme.copyWith(
        surface: surface,
        primary: accent,
        onSurface: ink,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: ink,
        displayColor: ink,
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
