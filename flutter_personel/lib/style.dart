/// Nohut design system for the native Android apps (Personel + Yönetim).
/// Forest green, cream and gold; Bree for display, Barlow for text; light
/// and dark themes. Widgets read colours from the theme ([NohutColors]), so
/// both modes stay readable.
library;

import 'package:flutter/material.dart';

/// Brand constants. Prefer `context.nohut` / `Theme.of(context)` in widgets,
/// so dark mode works; these stay for brand-fixed surfaces (logo panel).
class NohutStyle {
  static const green = Color(0xff123e30);
  static const greenDeep = Color(0xff0b2a20);
  static const cream = Color(0xfff6f2e7);
  static const card = Color(0xfffbf9f3);
  static const gold = Color(0xffa58336);
  static const goldSoft = Color(0xfff1e6c8);
  static const muted = Color(0xff60705f);
  static const outline = Color(0xffd9ddcc);

  static ThemeData get theme => _build(Brightness.light);
  static ThemeData get darkTheme => _build(Brightness.dark);

  static ThemeData _build(Brightness b) {
    final dark = b == Brightness.dark;
    final c = dark ? NohutColors.dark : NohutColors.light;
    final scheme = ColorScheme.fromSeed(
      seedColor: green,
      brightness: b,
      primary: dark ? const Color(0xff8fd0ae) : green,
      onPrimary: dark ? greenDeep : Colors.white,
      primaryContainer: dark ? const Color(0xff1d4d3c) : const Color(0xffd6eadf),
      onPrimaryContainer: dark ? const Color(0xffcfeedd) : greenDeep,
      secondary: dark ? const Color(0xffe2c47e) : gold,
      onSecondary: dark ? const Color(0xff2b2205) : Colors.white,
      secondaryContainer: dark ? const Color(0xff4a3d17) : goldSoft,
      onSecondaryContainer: dark ? const Color(0xfff6e5b8) : const Color(0xff3d300b),
      surface: c.background,
      onSurface: c.ink,
      onSurfaceVariant: c.muted,
      surfaceContainerLowest: c.card,
      surfaceContainerLow: c.card,
      surfaceContainer: c.card,
      surfaceContainerHigh: c.raised,
      surfaceContainerHighest: c.raised,
      outline: c.outline,
      outlineVariant: c.outline,
      error: c.danger,
    );
    final base = ThemeData(useMaterial3: true, brightness: b, colorScheme: scheme, fontFamily: 'Barlow');
    final text = base.textTheme.copyWith(
      displaySmall: base.textTheme.displaySmall?.copyWith(fontFamily: 'Bree', color: c.heading),
      headlineMedium: base.textTheme.headlineMedium?.copyWith(fontFamily: 'Bree', color: c.heading),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(fontFamily: 'Bree', color: c.heading, fontSize: 23),
      titleLarge: base.textTheme.titleLarge?.copyWith(fontFamily: 'Bree', color: c.heading, fontSize: 21),
      titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: .2),
    );
    final round = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
    return base.copyWith(
      textTheme: text,
      extensions: [c],
      scaffoldBackgroundColor: c.background,
      appBarTheme: AppBarTheme(
        backgroundColor: c.background,
        surfaceTintColor: Colors.transparent,
        foregroundColor: c.heading,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
      ),
      cardTheme: CardThemeData(
        color: c.card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 4),
        shape: RoundedRectangleBorder(side: BorderSide(color: c.outline), borderRadius: BorderRadius.circular(18)),
      ),
      dividerTheme: DividerThemeData(color: c.outline, space: 1, thickness: 1),
      listTileTheme: ListTileThemeData(iconColor: c.heading, shape: round, minVerticalPadding: 10),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.field,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: c.outline)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: c.outline)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: scheme.primary, width: 1.6)),
      ),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
        minimumSize: const Size(48, 50),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        shape: round,
        textStyle: const TextStyle(fontFamily: 'Barlow', fontWeight: FontWeight.w700, fontSize: 15),
      )),
      outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        side: BorderSide(color: c.outline),
        foregroundColor: c.heading,
        shape: round,
        textStyle: const TextStyle(fontFamily: 'Barlow', fontWeight: FontWeight.w600, fontSize: 15),
      )),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(
        foregroundColor: scheme.primary, shape: round,
        textStyle: const TextStyle(fontFamily: 'Barlow', fontWeight: FontWeight.w600),
      )),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.card,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.secondaryContainer,
        elevation: 0,
        labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(fontFamily: 'Barlow', fontSize: 12,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
            color: s.contains(WidgetState.selected) ? c.heading : c.muted)),
        iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
            color: s.contains(WidgetState.selected) ? scheme.onSecondaryContainer : c.muted)),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: c.card,
        indicatorColor: scheme.secondaryContainer,
        selectedIconTheme: IconThemeData(color: scheme.onSecondaryContainer),
        unselectedIconTheme: IconThemeData(color: c.muted),
        selectedLabelTextStyle: TextStyle(fontFamily: 'Barlow', fontWeight: FontWeight.w700, color: c.heading),
        unselectedLabelTextStyle: TextStyle(fontFamily: 'Barlow', color: c.muted),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: c.heading,
        unselectedLabelColor: c.muted,
        indicatorColor: scheme.secondary,
        dividerColor: c.outline,
        labelStyle: const TextStyle(fontFamily: 'Barlow', fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(fontFamily: 'Barlow', fontWeight: FontWeight.w500),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: c.card, side: BorderSide(color: c.outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        labelStyle: TextStyle(fontFamily: 'Barlow', color: c.ink, fontWeight: FontWeight.w600),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark ? const Color(0xffe7efe9) : greenDeep,
        contentTextStyle: TextStyle(fontFamily: 'Barlow', color: dark ? greenDeep : Colors.white, fontSize: 15),
        shape: round,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.card, surfaceTintColor: Colors.transparent, showDragHandle: true,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      ),
      dialogTheme: DialogThemeData(backgroundColor: c.card, surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)), titleTextStyle: text.titleLarge),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary, foregroundColor: scheme.onPrimary,
        elevation: 2, highlightElevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        extendedTextStyle: const TextStyle(fontFamily: 'Barlow', fontWeight: FontWeight.w700, fontSize: 15),
      ),
      drawerTheme: DrawerThemeData(backgroundColor: c.card, surfaceTintColor: Colors.transparent),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary, linearTrackColor: c.outline),
      bannerTheme: MaterialBannerThemeData(backgroundColor: c.warningSoft, contentTextStyle: TextStyle(color: c.warning)),
    );
  }
}

/// Semantic colours beyond the Material scheme.
@immutable
class NohutColors extends ThemeExtension<NohutColors> {
  const NohutColors({
    required this.background, required this.card, required this.raised, required this.field,
    required this.ink, required this.heading, required this.muted, required this.outline,
    required this.success, required this.successSoft, required this.warning, required this.warningSoft,
    required this.danger, required this.dangerSoft, required this.brandPanel,
  });

  final Color background, card, raised, field, ink, heading, muted, outline;
  final Color success, successSoft, warning, warningSoft, danger, dangerSoft;
  /// Fixed dark green panel for the logo / hero areas in both modes.
  final Color brandPanel;

  static const light = NohutColors(
    background: NohutStyle.cream, card: NohutStyle.card, raised: Color(0xffffffff), field: Color(0xffffffff),
    ink: Color(0xff1d2a22), heading: NohutStyle.green, muted: NohutStyle.muted, outline: NohutStyle.outline,
    success: Color(0xff1f6b43), successSoft: Color(0xffdcefe2),
    warning: Color(0xff7a5200), warningSoft: Color(0xfffff0cf),
    danger: Color(0xff9b2c1a), dangerSoft: Color(0xfffde2dc),
    brandPanel: NohutStyle.green,
  );
  static const dark = NohutColors(
    background: Color(0xff0d1713), card: Color(0xff15221c), raised: Color(0xff1c2b24), field: Color(0xff1c2b24),
    ink: Color(0xffe6ece7), heading: Color(0xffd9eadf), muted: Color(0xff9db0a3), outline: Color(0xff2c3d34),
    success: Color(0xff8fd0ae), successSoft: Color(0xff1d3a2c),
    warning: Color(0xffecc67a), warningSoft: Color(0xff3a2f14),
    danger: Color(0xfff0a493), dangerSoft: Color(0xff43211a),
    brandPanel: Color(0xff123e30),
  );

  @override
  NohutColors copyWith() => this;
  @override
  NohutColors lerp(ThemeExtension<NohutColors>? other, double t) =>
      other is NohutColors && t >= .5 ? other : this;
}

extension NohutTheme on BuildContext {
  NohutColors get nohut => Theme.of(this).extension<NohutColors>() ?? NohutColors.light;
}

/// Tone of a status pill or metric.
enum NohutTone { neutral, success, warning, danger, brand }

class NohutPill extends StatelessWidget {
  const NohutPill(this.text, {super.key, this.tone = NohutTone.neutral, this.icon});
  final String text;
  final NohutTone tone;
  final IconData? icon;

  /// Maps the server's status words to a tone.
  static NohutTone toneFor(String status) => switch (status) {
    'Gönderildi' || 'Ödendi' || 'Bağlı' => NohutTone.success,
    'Değişti' || 'Kısmen Ödendi' || 'Taslak' => NohutTone.warning,
    'Ödenmedi' || 'Bağlantı yok' => NohutTone.danger,
    _ => NohutTone.neutral,
  };

  @override
  Widget build(BuildContext context) {
    final c = context.nohut;
    final (bg, fg) = switch (tone) {
      NohutTone.success => (c.successSoft, c.success),
      NohutTone.warning => (c.warningSoft, c.warning),
      NohutTone.danger => (c.dangerSoft, c.danger),
      NohutTone.brand => (Theme.of(context).colorScheme.secondaryContainer, Theme.of(context).colorScheme.onSecondaryContainer),
      NohutTone.neutral => (c.raised, c.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 15, color: fg), const SizedBox(width: 5)],
        Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 13))),
      ]),
    );
  }
}

/// One number with its label (and optional icon), never a fake value: pass
/// '—' when the amount is unknown.
class NohutMetric extends StatelessWidget {
  const NohutMetric({super.key, required this.label, required this.value, this.icon, this.caption, this.emphasis = false});
  final String label, value;
  final String? caption;
  final IconData? icon;
  final bool emphasis;
  @override
  Widget build(BuildContext context) {
    final c = context.nohut, scheme = Theme.of(context).colorScheme;
    final fg = emphasis ? Colors.white : c.heading;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: emphasis ? c.brandPanel : c.card,
        borderRadius: BorderRadius.circular(18),
        border: emphasis ? null : Border.all(color: c.outline),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          if (icon != null) ...[
            Icon(icon, size: 17, color: emphasis ? const Color(0xffe2c47e) : scheme.secondary),
            const SizedBox(width: 6),
          ],
          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: emphasis ? Colors.white70 : c.muted, fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 6),
        FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
          child: Text(value, maxLines: 1, style: TextStyle(fontSize: emphasis ? 28 : 21, fontWeight: FontWeight.w700,
              color: fg, fontFeatures: const [FontFeature.tabularFigures()]))),
        if (caption != null) ...[
          const SizedBox(height: 2),
          Text(caption!, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: emphasis ? Colors.white60 : c.muted)),
        ],
      ]),
    );
  }
}

/// Responsive grid of metrics: 2 columns on phones, more when wide.
class NohutMetricGrid extends StatelessWidget {
  const NohutMetricGrid({super.key, required this.children, this.minTileWidth = 150});
  final List<Widget> children;
  final double minTileWidth;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final cols = (box.maxWidth / minTileWidth).floor().clamp(1, 4);
    // Rows of equal height: a caption on one tile never leaves its
    // neighbours short (Premium UI review QA-22).
    return Column(children: [
      for (var i = 0; i < children.length; i += cols) ...[
        if (i > 0) const SizedBox(height: 10),
        IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var j = i; j < i + cols; j++) ...[
            if (j > i) const SizedBox(width: 10),
            Expanded(child: j < children.length ? children[j] : const SizedBox()),
          ],
        ])),
      ],
    ]);
  });
}

/// Section heading with an optional trailing action.
class NohutSection extends StatelessWidget {
  const NohutSection(this.title, {super.key, this.action, this.subtitle});
  final String title;
  final String? subtitle;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 8),
    child: Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.end,
        runSpacing: 4, spacing: 8, children: [
      Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        if (subtitle != null) Text(subtitle!, style: TextStyle(color: context.nohut.muted, fontSize: 13)),
      ]),
      ?action,
    ]),
  );
}

/// Calm empty / error state with one action.
class NohutEmpty extends StatelessWidget {
  const NohutEmpty({super.key, required this.icon, required this.message, this.action, this.onAction});
  final IconData icon;
  final String message;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.secondaryContainer, shape: BoxShape.circle),
        child: Icon(icon, size: 28, color: Theme.of(context).colorScheme.onSecondaryContainer)),
      const SizedBox(height: 12),
      Text(message, textAlign: TextAlign.center, style: TextStyle(color: context.nohut.muted, fontSize: 15)),
      if (action != null && onAction != null) ...[
        const SizedBox(height: 12),
        FilledButton.tonal(onPressed: onAction, child: Text(action!)),
      ],
    ]),
  );
}

class NohutBrandHeader extends StatelessWidget {
  const NohutBrandHeader({super.key, this.subtitle, this.online});
  final String? subtitle;
  /// When set, a status dot (green / amber) precedes the subtitle.
  final bool? online;

  @override
  Widget build(BuildContext context) {
    final c = context.nohut;
    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxWidth < 220;
      final logoSize = compact ? 32.0 : 40.0;
      return Row(children: [
        Container(
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: NohutStyle.gold, width: 1.5)),
          child: ClipOval(child: Image.asset('assets/nohut-logo.webp', width: logoSize, height: logoSize,
              errorBuilder: (_, _, _) => SizedBox(width: logoSize, height: logoSize,
                  child: const Icon(Icons.restaurant, color: NohutStyle.gold)))),
        ),
        SizedBox(width: compact ? 6 : 10),
        Expanded(child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(compact ? 'Nohut' : 'Nohut Falafel', maxLines: 1,
              overflow: TextOverflow.ellipsis, style: TextStyle(
                fontSize: compact ? 17 : 20, fontFamily: 'Bree', color: c.heading, height: 1.1)),
            if (subtitle != null) Row(children: [
              if (online != null) ...[
                Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle,
                    color: online! ? c.success : c.warning)),
                const SizedBox(width: 5),
              ],
              Flexible(child: Text(subtitle!, maxLines: 1,
                overflow: TextOverflow.ellipsis, style:
                TextStyle(fontFamily: 'Barlow', fontSize: compact ? 11 : 12.5, color: c.muted, fontWeight: FontWeight.w600))),
            ]),
          ],
        )),
      ]);
    });
  }
}
