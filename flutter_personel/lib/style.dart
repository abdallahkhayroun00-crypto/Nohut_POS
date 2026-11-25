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
    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxWidth < 220;
      final logoSize = compact ? 30.0 : 44.0;
      return Row(children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: Image.asset('assets/nohut-logo.webp', width: logoSize, height: logoSize),
      ),
      SizedBox(width: compact ? 5 : 10),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(compact ? 'Nohut' : 'Nohut Falafel', maxLines: 1,
            overflow: TextOverflow.ellipsis, style: TextStyle(
              fontSize: compact ? 17 : 22, fontFamily: 'Bree', color: NohutStyle.green)),
          if (subtitle != null) Text(subtitle!, maxLines: 1,
              overflow: TextOverflow.ellipsis, style:
              TextStyle(fontSize: compact ? 10 : 12, color: NohutStyle.muted)),
        ],
      )),
    ]);
    });
  }
}
