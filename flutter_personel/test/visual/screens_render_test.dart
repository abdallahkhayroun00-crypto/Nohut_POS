// Visual smoke test; with NOHUT_RENDER_DIR set it also writes PNGs for review.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nohut_personel/home.dart';
import 'package:nohut_personel/manager_main.dart';
import 'package:nohut_personel/owner_api.dart';
import 'package:nohut_personel/owner_payroll.dart';
import 'package:nohut_personel/pos_api.dart';
import 'package:nohut_personel/style.dart';
import 'package:nohut_personel/work_page.dart';

import '../owner_payroll_test.dart' show payrollReply;
import '../work_page_test.dart' show weekReply;
import 'render_harness.dart';

NohutApi workApi() {
  final a = NohutApi(client: MockClient((r) async => switch (r.url.path) {
    '/api/work/week' => http.Response(jsonEncode(weekReply()), 200, headers: {'content-type': 'application/json; charset=utf-8'}),
    '/api/work/schedule' => http.Response(jsonEncode({'plans': [
      {'date': '2026-11-28', 'employeeName': 'Test Personel B', 'start': '12:00', 'end': '20:00'},
      {'date': '2026-11-29', 'employeeName': 'Test Personel A', 'start': '10:00', 'end': '18:00'},
    ]}), 200, headers: {'content-type': 'application/json; charset=utf-8'}),
    _ => http.Response('{}', 404),
  }));
  a..host = 'http://192.168.1.5:8787'..token = 'x' * 40..serverId = 'synthetic'..session = 'synthetic';
  return a;
}

PersonelController staffController() {
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
  return c;
}

class FakeOwnerApi extends OwnerApi {
  FakeOwnerApi() {
    host = 'http://192.168.1.5:8787';
    serverId = 'synthetic';
    employeeId = '1';
    ownerName = 'Test Sahibi';
  }
  final overviewData = <String, dynamic>{
    'cashCents': 184500, 'cardCents': 263000, 'orderCount': 42,
    'hourly': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 6, 9, 5, 3, 2, 4, 7, 8, 4, 0, 0, 0],
    'orders': [
      {'source': 'Masa', 'table': 3, 'status': 'Açık', 'owner': 'Test Personel A', 'totalCents': 42000},
      {'source': 'Gel-Al', 'dailyNumber': 17, 'status': 'Hazırlanıyor', 'owner': 'Test Personel B', 'totalCents': 16500},
      {'source': 'Trendyol Go', 'orderNumber': 'T-1001', 'status': 'Teslim edildi', 'totalCents': 31000},
    ],
    'openAccounts': [{'source': 'Masa', 'table': 2, 'dueCents': 12000}],
  };
  @override
  Future<Json?> cachedOverview(String day) async => overviewData;
  @override
  Future<Json> overview(String day) async => overviewData;
}

void main() {
  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await loadNohutFonts();
  });

  for (final mode in [Brightness.light, Brightness.dark]) {
    final m = mode == Brightness.light ? 'light' : 'dark';
    for (var tab = 0; tab < 3; tab++) {
      testWidgets('work tab $tab $m', (t) async {
        await renderScreen(t, 'work-$tab-$m', MaterialApp(debugShowCheckedModeBanner: false,
            theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
            home: WorkPage(api: workApi(), initialTab: tab)), brightness: mode);
        expect(t.takeException(), isNull);
      });
    }
    testWidgets('staff home $m', (t) async {
      await renderScreen(t, 'staff-home-$m', MaterialApp(debugShowCheckedModeBanner: false,
          theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
          home: StaffHome(controller: staffController(), onUnpair: () {})), brightness: mode);
      expect(t.takeException(), isNull);
    });
  }
  for (final mode in [Brightness.light, Brightness.dark]) {
    final m = mode == Brightness.light ? 'light' : 'dark';
    testWidgets('owner dashboard $m', (t) async {
      final api = FakeOwnerApi();
      await renderScreen(t, 'owner-dashboard-$m', MaterialApp(debugShowCheckedModeBanner: false,
          theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
          home: OwnerHome(controller: PersonelController(api, StaffNotifications()), api: api, onUnpair: () {})),
          brightness: mode);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox()); // stop the 30 s refresh timer
    });
    testWidgets('owner payroll $m', (t) async {
      await renderScreen(t, 'owner-payroll-$m', MaterialApp(debugShowCheckedModeBanner: false,
          theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
          home: OwnerPayrollPage(request: (_) async => payrollReply(paid: 80000))), brightness: mode);
      expect(t.takeException(), isNull);
    });
  }
}
