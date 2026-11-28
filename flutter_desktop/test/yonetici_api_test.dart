import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/lan_auth_gate.dart';
import 'package:nohut_falafel_desktop/lan_server.dart';
import 'package:nohut_falafel_desktop/local_accounts.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';

void main() {
  late Directory dir;
  late PosStore store;
  late LocalAuth auth;
  late PosLanServer server;
  const device = 'manager-device-0001-abc';
  final today = DateTime.now();
  final day = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('nohut-yonetici');
    store = PosStore(databaseFile: '${dir.path}/db');
    auth = LocalAuth(store.authDatabase, iterations: 1000);
    await auth.createUser(username: 'sahip', password: 'owner-pass-1', role: 'Yönetici', isOwner: true);
    await auth.createUser(username: 'mudur', password: 'mudur-pass-1', role: 'Müdür');
    await auth.createUser(username: 'garson', password: 'staff-pass-1', role: 'Personel');
    server = PosLanServer(store, port: 0, staffHtml: '<h1>P</h1>',
        yoneticiHtml: '<h1>Yönetici</h1>', authGate: LanAuthGate(auth));
    await server.start();
  });
  tearDown(() async {
    await server.stop();
    server.dispose();
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<(int, Object?, String?)> call(String method, String path, {Object? body, String? cookie}) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${server.port}$path'));
      if (cookie != null) req.headers.set(HttpHeaders.cookieHeader, cookie);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final decoded = res.headers.contentType?.mimeType == 'application/json' ? jsonDecode(text) : text;
      return (res.statusCode, decoded, res.headers.value(HttpHeaders.setCookieHeader));
    } finally {
      client.close(force: true);
    }
  }

  Future<String> login(String user, String pass) async {
    final (status, body, setCookie) = await call('POST', '/api/auth/login',
        body: {'username': user, 'password': pass, 'deviceId': '$device-$user', 'client': 'yonetici'});
    expect(status, 200, reason: '$body');
    return setCookie!.split(';').first;
  }

  test('/yonetici page is served; its API always needs a login', () async {
    final (page, html, _) = await call('GET', '/yonetici');
    expect(page, 200);
    expect(html, contains('Yönetici'));
    // Even with "Bireysel giriş zorunlu" off (legacy Personel mode).
    expect(auth.lanLoginRequired, false);
    final (status, body, _) = await call('GET', '/api/yonetici/overview?day=$day');
    expect(status, 401);
    expect((body as Map)['error'], 'auth_required');
  });

  test('a Personel account cannot open the Yönetici app', () async {
    final cookie = await login('garson', 'staff-pass-1');
    final (o, ob, _) = await call('GET', '/api/yonetici/overview?day=$day', cookie: cookie);
    expect(o, 403);
    expect((ob as Map)['error'], 'forbidden');
  });

  test('money is hidden until the owner allows finance on the local network', () async {
    final cookie = await login('sahip', 'owner-pass-1');
    final (s1, b1, _) = await call('GET', '/api/yonetici/overview?day=$day', cookie: cookie);
    expect(s1, 200);
    final v1 = (b1 as Map)['view'] as Map;
    expect(v1.containsKey('cashCents'), false);
    expect(v1.containsKey('reviews'), false);
    expect(b1['financeAllowed'], false);
    final month = day.substring(0, 7);
    final (m1, mb1, _) = await call('GET', '/api/yonetici/month?month=$month', cookie: cookie);
    expect(m1, 403);
    expect((mb1 as Map)['error'], 'https_required');

    auth.setSetting('local_finance_http', '1');
    final (s2, b2, _) = await call('GET', '/api/yonetici/overview?day=$day', cookie: cookie);
    expect(s2, 200);
    expect(((b2 as Map)['view'] as Map).containsKey('cashCents'), true);
    final (m2, mb2, _) = await call('GET', '/api/yonetici/month?month=$month', cookie: cookie);
    expect(m2, 200);
    expect(((mb2 as Map)['view'] as Map).containsKey('weeklyPayroll'), true);

    // Expense write goes through the desktop domain rules, once.
    final request = {'requestId': 'yonetici_test_000001', 'action': 'other_create', 'data': {
      'date': day, 'category': 'Temizlik', 'name': 'Deterjan', 'amountCents': 12500, 'paymentMethod': 'Nakit'}};
    final (w, wb, _) = await call('POST', '/api/yonetici/write', body: request, cookie: cookie);
    expect(w, 200, reason: '$wb');
    await call('POST', '/api/yonetici/write', body: request, cookie: cookie);
    final other = asMaps((store.read().data['finance'] as Map)['other']);
    expect(other.where((r) => r['name'] == 'Deterjan').length, 1);
  });

  test('a manager without payroll rights gets finance without payroll', () async {
    auth.setSetting('local_finance_http', '1');
    final mudur = auth.users().firstWhere((u) => u['username'] == 'mudur')['userId'] as String;
    auth.setGrant(mudur, 'finance.view', true);
    auth.setGrant(mudur, 'payroll.view', false);
    auth.setGrant(mudur, 'payroll.manage', false);
    final cookie = await login('mudur', 'mudur-pass-1');
    final (m, mb, _) = await call('GET', '/api/yonetici/month?month=${day.substring(0, 7)}', cookie: cookie);
    expect(m, 200);
    final view = (mb as Map)['view'] as Map;
    expect(view.containsKey('weeklyPayroll'), false);
    expect((view['summary'] as Map).containsKey('payrollCents'), false);
    expect((view['employees'] as List).every((e) => !(e as Map).containsKey('payRateCents')), true);
    final (w, wb, _) = await call('POST', '/api/yonetici/write', cookie: cookie, body: {
      'requestId': 'yonetici_test_000002', 'action': 'payroll_paid', 'data': {'employeeId': 1, 'weekStart': day}});
    expect(w, 403);
    expect((wb as Map)['error'], 'forbidden');
  });

  test('fixed monthly cost can be marked paid and unpaid with version checks', () async {
    auth.setSetting('local_finance_http', '1');
    final cookie = await login('sahip', 'owner-pass-1');
    final month = day.substring(0, 7);
    Future<(int, Object?)> write(String id, String action, Map<String, Object?> data) async {
      final (st, b, _) = await call('POST', '/api/yonetici/write', cookie: cookie,
          body: {'requestId': id, 'action': action, 'data': data});
      return (st, b);
    }
    final (s1, b1) = await write('yonetici_fixed_0000001', 'fixed_save', {'id': null, 'category': 'Kira',
      'name': 'Dükkan kirası', 'amountCents': 2500000, 'startMonth': month, 'dueDay': 5, 'active': true});
    expect(s1, 200, reason: '$b1');
    Future<Map> monthView() async =>
        ((await call('GET', '/api/yonetici/month?month=$month', cookie: cookie)).$2 as Map)['view'] as Map;
    final fixed = ((await monthView())['monthlyFixed'] as List).single as Map;
    final (s2, b2) = await write('yonetici_fixed_0000002', 'fixed_paid', {'id': fixed['id'], 'month': month,
      'paid': true, 'expectedVersion': fixed['updatedAt'], 'expectedPaidAt': null});
    expect(s2, 200, reason: '$b2');
    final pay = ((await monthView())['fixedPayments'] as List).single as Map;
    expect(pay['paidAt'], isNotNull);
    // A stale client (still thinks it is unpaid) is refused, not applied twice.
    final (s3, _) = await write('yonetici_fixed_0000003', 'fixed_paid', {'id': fixed['id'], 'month': month,
      'paid': true, 'expectedVersion': fixed['updatedAt'], 'expectedPaidAt': null});
    expect(s3, 409);
    final (s4, b4) = await write('yonetici_fixed_0000004', 'fixed_paid', {'id': fixed['id'], 'month': month,
      'paid': false, 'expectedVersion': fixed['updatedAt'], 'expectedPaidAt': pay['paidAt']});
    expect(s4, 200, reason: '$b4');
  });

  test('Gün Sonu report: login required, amounts only with finance gate + sales.view', () async {
    final (u, _, _) = await call('GET', '/api/yonetici/daily?day=$day');
    expect(u, 401);
    final staff = await login('garson', 'staff-pass-1');
    final (f, _, _) = await call('GET', '/api/yonetici/daily?day=$day', cookie: staff);
    expect(f, 403);
    final owner = await login('sahip', 'owner-pass-1');
    final (a, ab, _) = await call('GET', '/api/yonetici/daily?day=$day', cookie: owner);
    expect(a, 200);
    final hidden = (ab as Map)['report'] as Map;
    expect(hidden['amountsHidden'], true);
    expect(hidden.containsKey('sales'), false);
    expect((hidden['orders'] as Map).containsKey('total'), true);
    auth.setSetting('local_finance_http', '1');
    final (b, bb, _) = await call('GET', '/api/yonetici/daily?day=$day', cookie: owner);
    expect(b, 200);
    final full = (bb as Map)['report'] as Map;
    expect(full.containsKey('sales'), true);
    expect(full.containsKey('expenses'), true);
    expect(full['businessDate'], day);
    final (bad, _, _) = await call('GET', '/api/yonetici/daily?day=nope', cookie: owner);
    expect(bad, 422);
  });

  test('Ekip Performansı: staff.view needed, amounts only with finance gate + sales.view', () async {
    final staff = await login('garson', 'staff-pass-1');
    final (f, _, _) = await call('GET', '/api/yonetici/team-performance?range=week', cookie: staff);
    expect(f, 403);
    final owner = await login('sahip', 'owner-pass-1');
    final (a, ab, _) = await call('GET', '/api/yonetici/team-performance?range=week', cookie: owner);
    expect(a, 200, reason: '$ab');
    expect((ab as Map)['amounts'], false);
    final team = ab['team'] as Map;
    expect(team['range'], 'week');
    expect((team['totals'] as Map).containsKey('salesCents'), false);
    for (final p in team['people'] as List) {
      expect((p as Map).containsKey('salesCents'), false);
    }
    auth.setSetting('local_finance_http', '1');
    final (b, bb, _) = await call('GET', '/api/yonetici/team-performance?range=week', cookie: owner);
    expect(b, 200);
    expect((((bb as Map)['team'] as Map)['totals'] as Map).containsKey('salesCents'), true);
  });
}
