// Full-shell renders of the busiest Windows flow: Masalar, the table's
// account dialog, the order composer and payment. Baselines for the
// Premium UI pass. Set NOHUT_RENDER_DIR to write PNGs.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/brand.dart';
import 'package:nohut_falafel_desktop/floor_plan.dart';
import 'package:nohut_falafel_desktop/main.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';

Json line(int id, String name, int price, int qty) => {
  'productId': id, 'name': name, 'price': price, 'qty': qty,
  'note': '', 'removed': <String>[],
};

Json seed() {
  final s = <String, dynamic>{
    ...emptyPosState(),
    'settings': {'autoPrint': false, 'qrAutoSync': false},
    'localMenu': [
      {'id': 0, 'name': 'Falafel Dürüm', 'category': 'wrap', 'price': 160},
      {'id': 1, 'name': 'Falafel Tabağı', 'category': 'plate', 'price': 230},
      {'id': 2, 'name': 'Humus', 'category': 'meze', 'price': 110},
      {'id': 3, 'name': 'Ayran', 'category': 'drink', 'price': 35},
      {'id': 4, 'name': 'Çay', 'category': 'drink', 'price': 20},
    ],
  };
  newLocalOrder(state: s, source: 'Masa', table: 3, productLines: [
    line(0, 'Falafel Dürüm', 160, 2), line(3, 'Ayran', 35, 2),
    line(2, 'Humus', 110, 1)]);
  newLocalOrder(state: s, source: 'Masa', table: 1, productLines: [
    line(1, 'Falafel Tabağı', 230, 1), line(4, 'Çay', 20, 2)]);
  newLocalOrder(state: s, source: 'Gel-Al', productLines: [
    line(0, 'Falafel Dürüm', 160, 3)], customer: {'name': 'Ayşe'});
  return s;
}

var fontsLoaded = false;

Future<void> mount(WidgetTester t, Size size) async {
  final dir = Directory.systemTemp.createTempSync('nohut-flow-'),
      file = '${dir.path}/db.sqlite3';
  final store = PosStore(databaseFile: file);
  store.replace(seed(), 0);
  store.dispose();
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(() async {
    await t.pumpWidget(const SizedBox.shrink());
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
    dir.deleteSync(recursive: true);
  });
  if (Platform.environment['NOHUT_RENDER_DIR'] != null && !fontsLoaded) {
    fontsLoaded = true;
    await t.runAsync(() async {
      final body = FontLoader(NohutBrand.bodyFont)
        ..addFont(rootBundle.load('assets/brand/fonts/Barlow-Regular.ttf'))
        ..addFont(rootBundle.load('assets/brand/fonts/Barlow-Bold.ttf'));
      final heading = FontLoader(NohutBrand.headingFont)
        ..addFont(rootBundle.load('assets/brand/fonts/BreeSerif-Regular.ttf'));
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await Future.wait([body.load(), heading.load(), icons.load()]);
    });
  }
  await t.pumpWidget(NohutFalafelApp(databaseFile: file, startServer: false));
  await t.pumpAndSettle();
}

Finder onPlan(String text) => find.descendant(
  of: find.byType(RestaurantFloorPlan), matching: find.text(text));

Future<void> click(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

Future<void> shot(WidgetTester t, String name) async {
  final dir = Platform.environment['NOHUT_RENDER_DIR'];
  if (dir == null) return;
  final layer = t.binding.renderViews.first.debugLayer! as OffsetLayer;
  await t.runAsync(() async {
    final size = t.view.physicalSize;
    final image = await layer.toImage(Offset.zero & size);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  for (final (name, size) in [
    ('1536', const Size(1536, 864)),
    ('1280', const Size(1280, 720)),
  ]) {
    testWidgets('Masalar → hesap → sipariş → ödeme at $name', (t) async {
      await mount(t, size);
      await click(t, find.text('Masalar & Siparişler').last);
      expect(t.takeException(), isNull);
      await shot(t, 'flow-$name-1-masalar');

      // Occupied table opens its account dialog.
      await click(t, onPlan('Masa 3'));
      expect(t.takeException(), isNull);
      await shot(t, 'flow-$name-2-hesap');
      expect(find.byType(Dialog), findsOneWidget);
      // İptal and Sil live together at the bottom, once each.
      final zone = find.byKey(const ValueKey('order-danger-zone'));
      await t.ensureVisible(zone);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('order-cancel')), findsOneWidget);
      expect(find.byKey(const ValueKey('order-delete')), findsOneWidget);
      expect(find.text('Siparişi İptal Et'), findsNothing);
      await shot(t, 'flow-$name-2b-hesap-kaldir');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();

      // Empty table opens the composer for that table.
      await click(t, onPlan('Masa 2'));
      expect(t.takeException(), isNull);
      await shot(t, 'flow-$name-3-siparis');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();

      await click(t, find.text('Ödeme Bekleyen').last);
      await shot(t, 'flow-$name-4-odeme-bekleyen');
      expect(t.takeException(), isNull);
    });
  }
}
