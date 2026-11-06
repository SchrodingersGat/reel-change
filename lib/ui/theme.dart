import "package:flutter/material.dart";

/// Status colours. Always paired with an icon and a word - never colour alone.
class StatusColors {
  static const Color ok = Color(0xFF1B7F3B);
  static const Color warning = Color(0xFFB26A00);
  static const Color error = Color(0xFFC62828);
}

/// Minimum height for primary actions (gloved use on the shop floor).
const double kBigButtonHeight = 64;

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0D47A1));

  // Slightly larger text throughout, for readability at arm's length.
  // (Scale the M3 geometry - the colour/style text theme has no sizes to scale.)
  final typography = Typography.material2021();
  final TextTheme englishLike = typography.englishLike.apply(
    fontSizeFactor: 1.1,
  );

  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    typography: typography.copyWith(englishLike: englishLike),
  );

  return base.copyWith(
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 20),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(kBigButtonHeight),
        textStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(kBigButtonHeight),
        textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}
