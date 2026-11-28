import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_personel/demand_page.dart';
import 'package:nohut_personel/pos_api.dart';
import 'package:nohut_personel/style.dart';

import 'visual/render_harness.dart';

Future<Json> Function(Json) demandRequest(List<Json> asked, {bool empty = false}) => (p) async {
  asked.add(p);
  final heat = [
    for (var d = 0; d < 7; d++)
      [for (var h = 0; h < 24; h++) empty || h < 11 || h > 22 ? 0 : ((h == 12 || h == 19) ? 6 : 2) + (d >= 4 ? 3 : 0) - (d == 0 ? 2 : 0)],
  ];
  final orders = heat.expand((r) => r).fold<int>(0, (a, b) => a + b);
  return {'ok': true, 'demand': {
    'range': p['range'], 'from': '2026-10-31', 'to': '2026-11-27', 'orders': orders,
    'heatmap': heat, 'perDay': [for (final r in heat) r.fold<int>(0, (a, b) => a + b)],
    'peak': empty ? null : {'weekday': 4, 'hour': 12, 'orders': 9},
    'busiestWeekday': empty ? null : 4,
    'note': 'İptal edilenler hariç; masa, gel-al ve online siparişler dahil.',
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
    testWidgets('heatmap by range ($label)', (t) async {
      final asked = <Json>[];
      await renderScreen(t, 'demand-$label', MaterialApp(debugShowCheckedModeBanner: false,
          theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
          home: DemandPage(request: demandRequest(asked))), size: size, brightness: mode);
      expect(asked.single, {'operation': 'ownerDemand', 'range': 'last4'});
      expect(find.text('Cum 12:00'), findsOneWidget);
      expect(find.text('Cuma'), findsOneWidget);
      expect(find.byKey(const ValueKey('heat-4-12')), findsOneWidget);
      expect(find.byKey(const ValueKey('heat-4-3')), findsNothing, reason: 'quiet night hours are trimmed');
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('switching range asks again; empty period says so', (t) async {
    final asked = <Json>[];
    await t.pumpWidget(MaterialApp(home: DemandPage(request: demandRequest(asked, empty: true))));
    await t.pumpAndSettle();
    expect(find.text('Bu dönemde sipariş yok.'), findsOneWidget);
    await t.tap(find.text('Bu Hafta'));
    await t.pumpAndSettle();
    expect(asked.map((a) => a['range']), ['last4', 'week']);
  });
}
