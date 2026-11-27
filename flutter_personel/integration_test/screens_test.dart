// Runs on the CI Android emulator: real Flutter screens of the Personel app
// with clearly synthetic data (no restaurant data, no server). Screenshots
// are evidence of rendering on Android, not of a physical device.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nohut_personel/home.dart';
import 'package:nohut_personel/pos_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nohut_personel/style.dart';
import 'package:nohut_personel/work_page.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Personel screens with synthetic data', (tester) async {
    final c = PersonelController(NohutApi(), StaffNotifications());
    c.state = {
      'employees': [
        {'id': 1, 'name': 'Test Personel A', 'active': true},
        {'id': 2, 'name': 'Test Personel B', 'active': true},
      ],
      'localMenu': [
        {'id': 1, 'name': 'Test Falafel Dürüm', 'price': 140, 'category': 'wrap'},
        {'id': 2, 'name': 'Test Humus Tabağı', 'price': 165, 'category': 'plate'},
        {'id': 3, 'name': 'Test Ayran', 'price': 35, 'category': 'drink'},
      ],
      'orders': <dynamic>[],
    };
    c.online = true;
    await tester.pumpWidget(MaterialApp(
      theme: NohutStyle.theme,
      home: StaffHome(controller: c, onUnpair: () {}),
    ));
    await tester.pumpAndSettle();
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();
    await binding.takeScreenshot('personel-masalar');
    for (final (tab, name) in [('Ürünler', 'urunler'), ('Sepet', 'sepet'), ('Siparişler', 'siparisler')]) {
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
      await binding.takeScreenshot('personel-$name');
    }
  });

  testWidgets('Mesai, Vardiya and Maaş screens with synthetic data', (tester) async {
    const json = {'content-type': 'application/json; charset=utf-8'};
    final api = NohutApi(client: MockClient((r) async => switch (r.url.path) {
      '/api/work/week' => http.Response(jsonEncode({'today': '2026-11-27', 'self': true, 'week': {
        'weekStart': '2026-11-23',
        'employee': {'id': 7, 'name': 'Test Personel A', 'payType': 'Saatlik', 'payRateCents': 10000},
        'status': {'status': 'Taslak', 'minutes': 960, 'daysWorked': 2},
        'plannedMinutes': 960,
        'plans': [{'id': 'vp_1', 'date': '2026-11-28', 'start': '10:00', 'end': '18:00', 'dayOff': false}],
        'work': [
          {'id': 'mw_1', 'date': '2026-11-24', 'from': '10:00', 'to': '18:00', 'minutes': 480, 'editable': true},
          {'id': 'mw_2', 'date': '2026-11-25', 'from': '10:00', 'to': '18:00', 'minutes': 480, 'editable': true},
        ],
        'pay': {'payrollEligible': true, 'earnedCents': 176000, 'paidCents': 80000, 'remainingCents': 96000,
          'financialStatus': 'Kısmen Ödendi', 'lastPaidOn': '2026-11-27'},
        'payments': [{'id': 'pp_1', 'paidOn': '2026-11-27', 'kind': 'Ödeme', 'method': 'Nakit', 'amountCents': 80000}],
      }}), 200, headers: json),
      '/api/work/schedule' => http.Response(jsonEncode({'plans': [
        {'date': '2026-11-28', 'employeeName': 'Test Personel B', 'start': '12:00', 'end': '20:00'}]}), 200, headers: json),
      _ => http.Response('{}', 404),
    }));
    api..host = 'http://192.168.1.5:8787'..token = 'x' * 40..serverId = 'synthetic-server'..session = 'synthetic';
    await tester.pumpWidget(MaterialApp(theme: NohutStyle.theme, home: WorkPage(api: api)));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('personel-mesai');
    for (final (tab, name) in [('Vardiya', 'vardiya'), ('Maaş', 'maas')]) {
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
      await binding.takeScreenshot('personel-$name');
    }
  });
}
