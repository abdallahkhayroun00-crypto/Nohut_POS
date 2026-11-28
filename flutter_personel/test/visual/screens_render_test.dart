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
    'activeTables': 2,
    'team': {
      'planned': [
        {'employeeName': 'Test Personel A', 'start': '10:00', 'end': '18:00'},
        {'employeeName': 'Test Personel B', 'start': '16:00', 'end': '00:30', 'endsNextDay': true},
      ],
      'worked': [{'employeeId': 7, 'name': 'Test Personel A', 'minutes': 450}],
      'actualMinutes': 450,
    },
  };
  @override
  Future<Json> request(Json payload) async =>
      payload['operation'] == 'ownerPayroll' ? payrollReply(paid: 80000) : throw const FormatException('?');
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
    testWidgets('staff home signed in $m', (t) async {
      final api = workApi()..sessionInfo = {'session': {'status': 'ok', 'employeeId': 7, 'username': 'personela'}};
      final c = PersonelController(api, StaffNotifications())
        ..state = staffController().state
        ..online = true;
      c.state['orders'] = [{'id': 1, 'source': 'Masa', 'table': 2}, {'id': 2, 'source': 'Gel-Al'}];
      await renderScreen(t, 'staff-home-signed-in-$m', MaterialApp(debugShowCheckedModeBanner: false,
          theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
          home: StaffHome(controller: c, onUnpair: () {})), brightness: mode);
      expect(find.text('Mesai Ekle'), findsOneWidget);
      expect(find.text('Kazanılan'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
  for (final mode in [Brightness.light, Brightness.dark]) {
    final m = mode == Brightness.light ? 'light' : 'dark';
    testWidgets('owner Personel tab $m', (t) async {
      final api = FakeOwnerApi();
      api.overviewData['employees'] = [
        {'id': 7, 'name': 'Test Personel A', 'role': 'Kasa', 'active': true},
        {'id': 8, 'name': 'Test Personel B', 'role': 'Mutfak', 'active': true},
      ];
      await renderScreen(t, 'owner-staff-$m', MaterialApp(debugShowCheckedModeBanner: false,
          theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
          home: OwnerHome(controller: PersonelController(api, StaffNotifications()), api: api, onUnpair: () {})),
          brightness: mode, before: (t) async {
            // §24.3 bottom bar: Ana Sayfa / Satışlar / Finans / Personel / Daha Fazla.
            for (final l in ['Ana Sayfa', 'Satışlar', 'Finans', 'Personel', 'Daha Fazla']) {
              expect(find.descendant(of: find.byType(NavigationBar), matching: find.text(l)), findsOneWidget);
            }
            await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Personel')));
            await t.pumpAndSettle();
          });
      expect(find.byKey(const ValueKey('staff-payroll')), findsOneWidget);
      expect(find.text('Test Personel B'), findsWidgets);
      await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Daha Fazla')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('owner-nav-settings')), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
    testWidgets('owner Ayarlar $m', (t) async {
      final api = FakeOwnerApi();
      await renderScreen(t, 'owner-settings-$m', MaterialApp(debugShowCheckedModeBanner: false,
          theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
          home: OwnerHome(controller: PersonelController(api, StaffNotifications()), api: api, onUnpair: () {})),
          brightness: mode, before: (t) async {
            await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Daha Fazla')));
            await t.pumpAndSettle();
            await t.tap(find.byKey(const ValueKey('owner-nav-settings')));
            await t.pumpAndSettle();
          });
      expect(find.text('Windows’ta yönetilenler'), findsOneWidget);
      await t.scrollUntilVisible(find.byKey(const ValueKey('settings-forget')), 200, scrollable: find.byType(Scrollable).first);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
    testWidgets('owner dashboard $m', (t) async {
      final api = FakeOwnerApi();
      await renderScreen(t, 'owner-dashboard-$m', MaterialApp(debugShowCheckedModeBanner: false,
          theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
          home: OwnerHome(controller: PersonelController(api, StaffNotifications()), api: api, onUnpair: () {})),
          brightness: mode);
      expect(t.takeException(), isNull);
      // §24.3: payroll panel and today's team on Ana Sayfa.
      expect(find.byKey(const ValueKey('dash-payroll')), findsOneWidget);
      expect(find.text('1 gecikti'), findsOneWidget);
      expect(find.textContaining('Planlı 2 kişi'), findsOneWidget);
      await t.pumpWidget(const SizedBox()); // stop the 30 s refresh timer
    });
    testWidgets('owner payroll $m', (t) async {
      await renderScreen(t, 'owner-payroll-$m', MaterialApp(debugShowCheckedModeBanner: false,
          theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
          home: OwnerPayrollPage(request: (_) async => payrollReply(paid: 80000))), brightness: mode);
      expect(t.takeException(), isNull);
    });
  }

  // Compact phone with large text and a tablet: the new Ana Sayfa screens.
  for (final (label, size, scale) in [('compact', const Size(320, 640), 1.3), ('tablet', const Size(1100, 800), 1.0)]) {
    testWidgets('staff home signed in $label', (t) async {
      final api = workApi()..sessionInfo = {'session': {'status': 'ok', 'employeeId': 7, 'username': 'personela'}};
      final c = PersonelController(api, StaffNotifications())..state = staffController().state..online = true;
      await renderScreen(t, 'staff-home-$label', MaterialApp(debugShowCheckedModeBanner: false,
          theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
          builder: (ctx, child) => MediaQuery(data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
          home: StaffHome(controller: c, onUnpair: () {})), size: size);
      expect(t.takeException(), isNull);
    });
    testWidgets('owner dashboard $label', (t) async {
      final api = FakeOwnerApi();
      await renderScreen(t, 'owner-dashboard-$label', MaterialApp(debugShowCheckedModeBanner: false,
          theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
          builder: (ctx, child) => MediaQuery(data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
          home: OwnerHome(controller: PersonelController(api, StaffNotifications()), api: api, onUnpair: () {})), size: size);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  }
}
