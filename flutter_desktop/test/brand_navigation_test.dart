import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/main.dart';
import 'package:nohut_falafel_desktop/brand.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';

void main() {
  testWidgets(
    'six branded destinations retain online orders, employee management and pairing',
    (t) async {
      final dir = Directory.systemTemp.createTempSync('nohut-brand-');
      final file = '${dir.path}/db';
      final db = PosStore(databaseFile: file);
      final state = emptyPosState();
      state['settings'] = {'qrAutoSync': false, 'autoPrint': false};
      db.replace(state, db.read().revision);
      db.dispose();
      t.view.physicalSize = const Size(1440, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(() async {
        await t.pumpWidget(const SizedBox.shrink());
        t.view.resetPhysicalSize();
        t.view.resetDevicePixelRatio();
        dir.deleteSync(recursive: true);
      });
      await t.runAsync(() async {
        final body = FontLoader(NohutBrand.bodyFont)
          ..addFont(rootBundle.load('assets/brand/fonts/Barlow-Regular.ttf'))
          ..addFont(rootBundle.load('assets/brand/fonts/Barlow-Bold.ttf'));
        final heading = FontLoader(
          NohutBrand.headingFont,
        )..addFont(rootBundle.load('assets/brand/fonts/BreeSerif-Regular.ttf'));
        await Future.wait([body.load(), heading.load()]);
      });
      await t.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('brand-capture'),
          child: NohutFalafelApp(databaseFile: file, startServer: false),
        ),
      );
      await t.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is ListTile &&
              w.key is ValueKey<String> &&
              (w.key as ValueKey<String>).value.startsWith('navigation-'),
        ),
        findsNWidgets(6),
      );
      expect(find.text('Personel Yönetimi'), findsNothing);
      expect(find.text('Online Siparişler'), findsNothing);
      final boundary = t.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('brand-capture')),
      );
      await t.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final proof = File('build/desktop-brand-proof.png');
        proof.parent.createSync(recursive: true);
        proof.writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await t.tap(find.byKey(const ValueKey('navigation-orders')));
      await t.pumpAndSettle();
      expect(find.text('Online Siparişler'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('navigation-settings')));
      await t.pumpAndSettle();
      for (final tab in ['Personel', 'Bağlantı', 'Yazıcı']) {
        await t.tap(find.text(tab).first);
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      }
      expect(find.text('Windows · Fiş görseli'), findsOneWidget);
      expect(find.text('Hizalama Testi Yazdır'), findsOneWidget);
    },
  );
}
