import 'package:flutter/material.dart';

/// Original QR menu identity. Fonts and logo are bundled for offline use.
abstract final class NohutBrand {
  static const green = Color(0xff123B2D);
  static const gold = Color(0xffC7A15D);
  static const cream = Color(0xffF7F5EE);
  static const card = Color(0xffFFFFFF);
  static const ink = Color(0xff18372C);
  static const muted = Color(0xff65736C);
  static const bodyFont = 'Segoe UI';
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
        primaryContainer: const Color(0xffE8F0E9),
        onPrimaryContainer: green,
        outline: const Color(0xffBECFC5),
      ),
      scaffoldBackgroundColor: cream,
    );
    return base.copyWith(
      dividerTheme: const DividerThemeData(color: Color(0xffE2EAE3), thickness: 1),
      listTileTheme: const ListTileThemeData(iconColor: green, minVerticalPadding: 9),
      dataTableTheme: DataTableThemeData(
        headingRowColor: WidgetStateProperty.all(const Color(0xffF4F7F3)),
        dataRowMinHeight: 54,
        dataRowMaxHeight: 62,
        dividerThickness: 0.6,
        headingTextStyle: const TextStyle(fontWeight: FontWeight.w700, color: green, fontSize: 12),
        dataTextStyle: const TextStyle(fontSize: 13, color: ink),
      ),
      textTheme: base.textTheme.copyWith(
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontFamily: headingFont,
          color: green,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontFamily: headingFont,
          color: green,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 14),
        labelLarge: base.textTheme.labelLarge?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0.5,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xffE0E8E2)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        enabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: Color(0xffD6E1D9)),
          borderRadius: BorderRadius.circular(12),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: green, width: 1.7),
          borderRadius: BorderRadius.circular(12),
        ),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
