import 'package:flutter/material.dart';

class NohutStyle {
  static const green = Color(0xff123e30);
  static const cream = Color(0xfff6f2e7);
  static const card = Color(0xfffbf9f3);
  static const gold = Color(0xffa58336);
  static const muted = Color(0xff60705f);
  static const outline = Color(0xffd9ddcc);

  static ThemeData get theme => ThemeData(
    useMaterial3: true,
    fontFamily: 'Barlow',
    colorScheme: ColorScheme.fromSeed(
      seedColor: green,
      primary: green,
      secondary: gold,
      surface: cream,
    ),
    scaffoldBackgroundColor: cream,
    appBarTheme: const AppBarTheme(
      backgroundColor: card,
      foregroundColor: green,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: outline),
        borderRadius: BorderRadius.circular(16),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      ),
    ),
  );
}

class NohutBrandHeader extends StatelessWidget {
  const NohutBrandHeader({super.key, this.subtitle});
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: Image.asset('assets/nohut-logo.webp', width: 51, height: 51),
      ),
      const SizedBox(width: 12),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Nohut Falafel', style: TextStyle(
              fontSize: 25, fontFamily: 'Bree', color: NohutStyle.green)),
          if (subtitle != null) Text(subtitle!, style:
              const TextStyle(fontSize: 13, color: NohutStyle.muted)),
        ],
      )),
    ]);
  }
}
