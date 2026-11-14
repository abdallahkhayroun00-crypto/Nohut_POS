import 'package:flutter/material.dart';

/// Original QR menu identity. Fonts and logo are bundled for offline use.
abstract final class NohutBrand {
  static const green = Color(0xff123e30);
  static const gold = Color(0xffa58336);
  static const cream = Color(0xfff6f2e7);
  static const card = Color(0xfffbf9f3);
  static const ink = Color(0xff152c23);
  static const muted = Color(0xff526251);
  static const bodyFont = 'Barlow Semi Condensed';
  static const headingFont = 'Bree Serif';

  static ThemeData theme() {
    final base = ThemeData(
      useMaterial3: true,
      fontFamily: bodyFont,
      colorScheme: ColorScheme.fromSeed(seedColor: green).copyWith(
        primary: green,
        onPrimary: Colors.white,
        secondary: gold,
        surface: card,
        onSurface: ink,
        primaryContainer: const Color(0xffe5ebdf),
        onPrimaryContainer: green,
        outline: const Color(0xffa1b09f),
      ),
      scaffoldBackgroundColor: cream,
    );
    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontFamily: headingFont,
          color: green,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontFamily: headingFont,
          color: green,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 16),
        labelLarge: base.textTheme.labelLarge?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(17),
          side: const BorderSide(color: Color(0xffdce1d4)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 14,
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        selectedColor: green,
        checkmarkColor: Colors.white,
        secondaryLabelStyle: const TextStyle(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(44, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(44, 44),
          foregroundColor: green,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}
