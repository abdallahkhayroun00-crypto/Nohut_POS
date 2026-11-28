// Pairing and sign-in screens (Personel) with synthetic data.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_personel/manager_main.dart';
import 'package:nohut_personel/pair_page.dart';
import 'package:nohut_personel/style.dart';

import 'render_harness.dart';
import 'screens_render_test.dart' show staffController;

void main() {
  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await loadNohutFonts();
  });

  for (final (label, size, mode) in [
    ('phone', const Size(412, 915), Brightness.light),
    ('phone-dark', const Size(412, 915), Brightness.dark),
    ('compact', const Size(320, 640), Brightness.light),
  ]) {
    testWidgets('pair $label', (t) async {
      await renderScreen(t, 'pair-$label', MaterialApp(debugShowCheckedModeBanner: false,
          theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
          home: PairPage(controller: staffController(), onPaired: () {})),
          size: size, brightness: mode);
      expect(find.byKey(const ValueKey('pair-submit')), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('a typed address is recognised; missing PIN is explained', (t) async {
    t.view.physicalSize = const Size(412, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: NohutStyle.theme,
        home: PairPage(controller: staffController(), onPaired: () {})));
    await t.tap(find.text('Kamera yoksa adresi elle girin'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('pair-address')), 'http://192.168.1.10:8787/personel');
    await t.pump();
    expect(find.byKey(const ValueKey('pair-found')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('pair-submit')));
    await t.pump();
    expect(find.textContaining('6 haneli PIN'), findsOneWidget);
  });

  for (final (label, mode) in [('phone', Brightness.light), ('phone-dark', Brightness.dark)]) {
    testWidgets('owner pair $label', (t) async {
      await renderScreen(t, 'owner-pair-$label', const NohutOwnerApp(), size: const Size(412, 915), brightness: mode);
      expect(find.byKey(const ValueKey('owner-pair-scan')), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
