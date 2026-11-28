import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_personel/pos_api.dart';
import 'package:nohut_personel/sales_page.dart';
import 'package:nohut_personel/style.dart';

import 'visual/render_harness.dart';

Future<Json> Function(Json) salesRequest(List<Json> asked) => (p) async {
  asked.add(p);
  final long = p['range'] != 'week';
  final days = long ? 28 : 5;
  final daily = [
    for (var i = 0; i < days; i++) {
      'day': '2026-11-${(28 - days + i).toString().padLeft(2, '0')}'.replaceAll('-11-0', '-11-0'),
      'netCents': 180000 + (i % 7) * 35000, 'orderCount': 20 + i % 7,
    },
  ];
  return {'ok': true, 'sales': {
    'range': p['range'], 'from': daily.first['day'], 'to': daily.last['day'], 'daily': daily,
    'totals': {'netCents': 1245000, 'cashCents': 520000, 'cardCents': 745000, 'refundCents': 20000,
      'orderCount': 118, 'averageCents': 10551},
    'topProducts': [
      {'name': 'Test Falafel Dürüm', 'qty': 84, 'grossCents': 1176000},
      {'name': 'Test Humus Tabağı', 'qty': 31, 'grossCents': 511500},
      {'name': 'Test Ayran', 'qty': 96, 'grossCents': 336000},
    ],
    'online': {'orders': 14, 'grossCents': 238000},
    'note': 'Tahsilatlar kasadaki Masa ve Gel-Al ödemeleridir; online platform satışları ayrı gösterilir.',
  }};
};

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
    testWidgets('sales analysis ($label)', (t) async {
      final asked = <Json>[];
      await renderScreen(t, 'sales-$label', MaterialApp(debugShowCheckedModeBanner: false,
          theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
          home: SalesPage(request: salesRequest(asked))), size: size, brightness: mode);
      expect(asked.single, {'operation': 'ownerSales', 'range': 'week'});
      expect(find.text('12.450,00 ₺'), findsOneWidget);
      if (label != 'compact') expect(find.byKey(const ValueKey('top-product-0')), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('28 days fit without overflow', (t) async {
    await t.pumpWidget(MaterialApp(home: SalesPage(request: salesRequest([]), initialRange: 'last4')));
    await t.pumpAndSettle();
    expect(find.byType(Tooltip), findsWidgets);
    expect(t.takeException(), isNull);
  });
}
