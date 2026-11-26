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
      // Flat cards with a light outline everywhere (same as the new panels).
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        margin: const EdgeInsets.symmetric(vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xffE1E7E3)),
        ),
      ),
      expansionTileTheme: const ExpansionTileThemeData(
        shape: Border(),
        collapsedShape: Border(),
        iconColor: green,
        collapsedIconColor: green,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: green,
          selectedForegroundColor: Colors.white,
          side: const BorderSide(color: Color(0xffD5DED8)),
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

/// Lays tiles out in balanced rows that fill the available width
/// (5 tiles on 4 columns → 3 + 2, never 4 + 1).
class EvenGrid extends StatelessWidget {
  const EvenGrid({
    super.key,
    required this.children,
    this.minTileWidth = 200,
    this.spacing = 12,
  });
  final List<Widget> children;
  final double minTileWidth, spacing;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final n = children.length;
      if (n == 0) return const SizedBox.shrink();
      final fit = ((box.maxWidth + spacing) / (minTileWidth + spacing))
          .floor()
          .clamp(1, n);
      final rows = (n / fit).ceil();
      final columns = (n / rows).ceil();
      final width = (box.maxWidth - spacing * (columns - 1)) / columns;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}
