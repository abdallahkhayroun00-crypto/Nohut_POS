import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/brand.dart';
import 'package:nohut_falafel_desktop/floor_plan.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/tables_panel.dart';

final now = DateTime.utc(2026, 11, 27, 18, 30);

Json order(int id, String source, int minutesAgo, {
  int? table, List<Json> payments = const [], String? customer,
}) => {
  'id': id,
  'number': id,
  'source': source,
  'table': table,
  'createdAt': now.subtract(Duration(minutes: minutesAgo)).toIso8601String(),
  'closed': false,
  'cancelled': false,
  if (customer != null) 'customer': {'name': customer},
  'batches': [
    {'id': 1, 'staff': 'Test Personel', 'lines': [
      {'name': 'Falafel Dürüm', 'price': 160, 'qty': 2},
      {'name': 'Ayran', 'price': 35, 'qty': 2},
      {'name': 'Humus', 'price': 110, 'qty': 1},
    ]},
  ],
  'payments': payments,
};

Json fixture({bool empty = false}) => {
  ...emptyPosState(),
  'orders': empty ? <Json>[] : [
    order(1, 'Masa', 105, table: 3),
    order(2, 'Masa', 34, table: 1),
    order(3, 'Masa', 12, table: 4,
      payments: [{'method': 'Kart', 'amount': 500}]),
    order(4, 'Gel-Al', 8, customer: 'Ayşe'),
    order(5, 'Gel-Al', 3,
      payments: [{'method': 'Nakit', 'amount': 100}]),
  ],
};

final boundary = GlobalKey();
var fontsLoaded = false;

Future<void> mount(WidgetTester t, Json state, Size size, {
  bool editing = false, double textScale = 1,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
  if (Platform.environment['NOHUT_RENDER_DIR'] != null && !fontsLoaded) {
    fontsLoaded = true;
    await t.runAsync(() async {
      final body = FontLoader(NohutBrand.bodyFont)
        ..addFont(rootBundle.load('assets/brand/fonts/Barlow-Regular.ttf'))
        ..addFont(rootBundle.load('assets/brand/fonts/Barlow-Bold.ttf'));
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await Future.wait([body.load(), icons.load()]);
    });
  }
  await t.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: NohutBrand.theme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale)),
      child: child!),
    home: RepaintBoundary(
      key: boundary,
      child: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: MasalarBoard(
            state: state,
            now: now,
            positions: positionsFromJson(null),
            editing: editing,
            onTable: (_) {},
            onMove: (_, _) {},
            onOpenOrder: (_) {},
            onPrintBill: (_) {},
            onResetLayout: () {},
            onCancelLayout: () {},
            onSaveLayout: () {},
          ),
        ),
      ),
    ),
  ));
  await t.pump();
}

Future<void> shot(WidgetTester t, String name) async {
  final dir = Platform.environment['NOHUT_RENDER_DIR'];
  if (dir == null) return;
  await t.runAsync(() async {
    final image = await (boundary.currentContext!.findRenderObject()
        as RenderRepaintBoundary).toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  const sizes = {
    'wide-1536': Size(1536, 1000),
    'mid-1100': Size(1100, 1500),
    'narrow-720': Size(720, 1500),
    'small-420': Size(420, 1900),
  };
  for (final MapEntry(key: name, value: size) in sizes.entries) {
    testWidgets('Masalar renders without overflow at $name', (t) async {
      await mount(t, fixture(), size);
      expect(t.takeException(), isNull);
      // The open-orders list is never hidden, whatever the width.
      expect(find.text('Açık Masalar'), findsOneWidget);
      expect(find.text('Bekleyen Gel-Al'), findsOneWidget);
      await shot(t, 'masalar-$name');
    });
  }

  testWidgets('narrow layout shows a status tile per table', (t) async {
    await mount(t, fixture(), const Size(720, 1500));
    for (var n = 1; n <= 5; n++) {
      expect(find.byKey(ValueKey('table-tile-$n')), findsOneWidget);
    }
    expect(find.text('Boş'), findsNWidgets(2));
    expect(find.text('Yeni sipariş'), findsNWidgets(2));
    // QA-23: every tile in a row is the same height.
    final heights = {
      for (var n = 1; n <= 5; n++)
        t.getSize(find.byKey(ValueKey('table-tile-$n'))).height,
    };
    expect(heights, hasLength(1));
    expect(find.text('Ödendi · Masa açık'), findsOneWidget);
  });

  testWidgets('empty restaurant and layout editing', (t) async {
    await mount(t, fixture(empty: true), const Size(1536, 1000));
    expect(find.text('Tüm masalar boş'), findsOneWidget);
    expect(find.text('5 boş masa'), findsOneWidget);
    await shot(t, 'masalar-empty-1536');
    await mount(t, fixture(), const Size(1536, 1000), editing: true);
    expect(find.byKey(const ValueKey('floor-edit-bar')), findsOneWidget);
    expect(find.text('Açık Masalar'), findsNothing);
    await shot(t, 'masalar-editing-1536');
  });

  testWidgets('large text at 1100 and 720', (t) async {
    await mount(t, fixture(), const Size(1100, 1700), textScale: 1.3);
    expect(t.takeException(), isNull);
    await shot(t, 'masalar-text130-1100');
    await mount(t, fixture(), const Size(720, 1800), textScale: 1.3);
    expect(t.takeException(), isNull);
    await shot(t, 'masalar-text130-720');
  });
}
