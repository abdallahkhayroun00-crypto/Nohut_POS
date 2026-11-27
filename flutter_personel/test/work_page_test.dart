// Native Mesai / Vardiya / Maaş screens: the phone sends no employee id,
// shows only the server's own-week view, and a retried write keeps its
// request id so the server applies it once.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nohut_personel/pos_api.dart';
import 'package:nohut_personel/style.dart';
import 'package:nohut_personel/work_page.dart';

Map<String, dynamic> weekReply({bool eligible = true}) => {
  'today': '2026-11-27', 'self': true,
  'week': {
    'weekStart': '2026-11-23',
    'employee': {'id': 7, 'name': 'Test Personel A', 'payType': 'Saatlik', 'payRateCents': 10000},
    'status': {'status': 'Taslak', 'minutes': 960, 'daysWorked': 2},
    'plannedMinutes': 960,
    'plans': [
      {'id': 'vp_1', 'date': '2026-11-28', 'start': '10:00', 'end': '18:00', 'dayOff': false, 'breakMinutes': 0, 'updatedAt': 'u1'},
    ],
    'work': [
      {'id': 'mw_1', 'date': '2026-11-24', 'from': '10:00', 'to': '18:00', 'breakMinutes': 0, 'minutes': 480,
       'editable': true, 'updatedAt': 'u2'},
      {'id': 'mw_2', 'date': '2026-11-25', 'from': '10:00', 'to': '18:00', 'breakMinutes': 0, 'minutes': 480,
       'editable': true, 'updatedAt': 'u3'},
    ],
    'pay': {'payrollEligible': eligible, 'earnedCents': 176000, 'paidCents': 80000, 'remainingCents': 96000,
      'financialStatus': 'Kısmen Ödendi', 'lastPaidOn': '2026-11-27'},
    'payments': [
      {'id': 'pp_1', 'paidOn': '2026-11-27', 'kind': 'Ödeme', 'method': 'Nakit', 'amountCents': 80000},
    ],
  },
};

void main() {
  late List<http.Request> seen;
  late int writes;
  late bool failNextWrite;

  NohutApi api({bool eligible = true}) {
    FlutterSecureStorage.setMockInitialValues({});
    final a = NohutApi(client: MockClient((r) async {
      seen.add(r);
      switch (r.url.path) {
        case '/api/work/week':
          return http.Response(jsonEncode(weekReply(eligible: eligible)), 200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        case '/api/work/schedule':
          return http.Response(jsonEncode({'plans': [
            {'date': '2026-11-28', 'employeeName': 'Test Personel B', 'start': '12:00', 'end': '20:00'},
          ]}), 200, headers: {'content-type': 'application/json; charset=utf-8'});
        case '/api/work/write':
          if (failNextWrite) {
            failNextWrite = false;
            throw http.ClientException('connection reset');
          }
          writes++;
          return http.Response(jsonEncode({'ok': true}), 200);
      }
      return http.Response('{}', 404);
    }));
    a.host = 'http://192.168.1.5:8787';
    a.token = 'x' * 40;
    a.serverId = 'server-1234567890';
    a.session = 'abc123';
    return a;
  }

  setUp(() { seen = []; writes = 0; failNextWrite = false; });

  Future<void> pump(WidgetTester t, NohutApi a, {int tab = 0}) async {
    t.view.physicalSize = const Size(412 * 3, 915 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: NohutStyle.theme, home: WorkPage(api: a, initialTab: tab)));
    await t.pumpAndSettle();
  }

  testWidgets('Mesai: own week, hours and submit; no employee id is ever sent', (t) async {
    final a = api();
    await pump(t, a);
    expect(find.text('Taslak'), findsOneWidget);
    expect(find.text('16 sa'), findsWidgets);
    expect(find.textContaining('Sal 24 Kas · 10:00–18:00'), findsOneWidget);
    await t.tap(find.text('Haftalık Mesailerimi Gönder'));
    await t.pumpAndSettle();
    await t.tap(find.text('Gönder'));
    await t.pumpAndSettle();
    expect(writes, 1);
    final write = seen.firstWhere((r) => r.url.path == '/api/work/write');
    final body = jsonDecode(write.body) as Map;
    expect(body['action'], 'week_submit');
    expect(body['weekStart'], '2026-11-23');
    for (final r in seen) {
      expect(r.url.queryParameters.containsKey('employeeId'), false);
      if (r.method == 'POST') expect((jsonDecode(r.body) as Map).containsKey('employeeId'), false);
      expect(r.headers['cookie'], 'nohut_lan=abc123');
    }
  });

  testWidgets('a write after a lost connection retries with the same request id', (t) async {
    final a = api();
    await pump(t, a);
    failNextWrite = true;
    for (var i = 0; i < 2; i++) {
      await t.tap(find.text('Haftalık Mesailerimi Gönder'));
      await t.pumpAndSettle();
      await t.tap(find.text('Gönder'));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 5)); // let the message close
      await t.pumpAndSettle();
    }
    expect(find.textContaining('kayıt iki kez oluşmaz'), findsNothing);
    final ids = [for (final r in seen.where((r) => r.url.path == '/api/work/write')) (jsonDecode(r.body) as Map)['requestId']];
    expect(ids, hasLength(2));
    expect(ids[0], ids[1]);
    expect(writes, 1);
  });

  testWidgets('Vardiya: my plans and the team schedule', (t) async {
    await pump(t, api(), tab: 1);
    expect(find.textContaining('Cmt 28 Kas · 10:00–18:00'), findsOneWidget);
    expect(find.textContaining('Test Personel B 12:00–20:00'), findsOneWidget);
  });

  testWidgets('Maaş: acceptance numbers (1760 earned, 800 paid, 960 left, Kısmen Ödendi)', (t) async {
    await pump(t, api(), tab: 2);
    expect(find.text('Kısmen Ödendi'), findsOneWidget);
    expect(find.text(money(176000)), findsOneWidget);
    expect(find.text(money(80000)), findsWidgets);
    expect(find.text(money(96000)), findsOneWidget);
    expect(find.text('Ödeme geçmişim'), findsOneWidget);
  });

  testWidgets('Maaş: not on payroll (e.g. the owner) shows no money', (t) async {
    await pump(t, api(eligible: false), tab: 2);
    expect(find.textContaining('bordrosuna dahil değilsiniz'), findsOneWidget);
    expect(find.text(money(176000)), findsNothing);
  });

  testWidgets('small phone with large text: every tab lays out without overflow', (t) async {
    t.view.physicalSize = const Size(320 * 2, 640 * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    for (var tab = 0; tab < 3; tab++) {
      await t.pumpWidget(MaterialApp(theme: NohutStyle.theme,
        builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(1.3)), child: child!),
        home: WorkPage(key: ValueKey(tab), api: api(), initialTab: tab)));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: 'tab $tab');
    }
  });

  test('formatting helpers', () {
    expect(WorkFormat.addDays('2026-11-30', 1), '2026-12-01');
    expect(WorkFormat.day('2026-11-23'), 'Pzt 23 Kas');
    expect(WorkFormat.hours(450), '7 sa 30 dk');
    final ids = WorkRequestIds();
    final a = ids.forPayload({'x': 1});
    expect(ids.forPayload({'x': 1}), a);
    expect(ids.forPayload({'x': 2}), isNot(a));
    ids.done({'x': 1});
    expect(ids.forPayload({'x': 1}), isNot(a));
  });
}
