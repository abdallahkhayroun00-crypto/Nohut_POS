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
}
