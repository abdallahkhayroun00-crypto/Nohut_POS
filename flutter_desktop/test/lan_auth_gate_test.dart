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
  late LanAuthGate gate;
  late PosLanServer server;
  final received = <Map<String, dynamic>>[];
  const device = 'phone-device-0001-abcdef';

  setUp(() async {
    received.clear();
    dir = Directory.systemTemp.createTempSync('nohut-lan-auth');
    store = PosStore(databaseFile: '${dir.path}/db');
    auth = LocalAuth(store.authDatabase, iterations: 1000);
    await auth.createUser(username: 'sahip', password: 'owner-pass-1', role: 'Yönetici', isOwner: true);
    final ayse = await auth.createUser(
        username: 'ayse', password: 'staff-pass-1', role: 'Personel', employeeId: 7);
    auth.setGrant(ayse, 'online.act', false);
    gate = LanAuthGate(auth);
    server = PosLanServer(store, port: 0, staffHtml: '<h1>P</h1>', authGate: gate,
        platformAction: (r) async {
          received.add(r);
          return {'ok': true};
        });
    await server.start();
  });
  tearDown(() async {
    await server.stop();
    server.dispose();
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<(int, Map, String?)> call(String method, String path,
      {Object? body, String? cookie, String? origin, String? bearer}) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${server.port}$path'));
      if (cookie != null) req.headers.set(HttpHeaders.cookieHeader, cookie);
      if (bearer != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      if (origin != null) req.headers.set('origin', origin);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      return (res.statusCode, jsonDecode(text) as Map, res.headers.value(HttpHeaders.setCookieHeader));
    } finally {
      client.close(force: true);
    }
  }

  String cookieOf(String? setCookie) => setCookie!.split(';').first;

  test('legacy mode keeps the shared panel working until the owner opts in', () async {
    final (status, _, _) = await call('GET', '/api/state');
    expect(status, 200);
    final (s, session, _) = await call('GET', '/api/auth/session');
    expect(s, 200);
    expect(session['required'], false);
    expect(session['configured'], true);
    expect((session['session'] as Map)['status'], 'none');
  });

  test('required mode: login sets an HttpOnly cookie; state needs a session', () async {
    auth.setSetting('lan_login_required', '1');
    expect((await call('GET', '/api/state')).$1, 401);

    final (bad, badBody, _) = await call('POST', '/api/auth/login',
        body: {'username': 'ayse', 'password': 'wrong-pass', 'deviceId': device});
    expect(bad, 401);
    expect(badBody['error'], 'invalid_credentials');

    final (ok, body, setCookie) = await call('POST', '/api/auth/login',
        body: {'username': 'ayse', 'password': 'staff-pass-1', 'deviceId': device, 'label': 'iPhone'});
    expect(ok, 200);
    expect(setCookie, contains('HttpOnly'));
    expect(setCookie, contains('SameSite=Strict'));
    expect(jsonEncode(body), isNot(contains(cookieOf(setCookie).split('=').last)),
        reason: 'token is never in the JSON body');
    final session = body['session'] as Map;
    expect(session['username'], 'ayse');
    expect(session['employeeId'], 7);
    expect((session['grants'] as List), isNot(contains('sync.view')), reason: 'windows-only hidden');

    final cookie = cookieOf(setCookie);
    expect((await call('GET', '/api/state', cookie: cookie)).$1, 200);

    // Per-operation check: online.act was removed for this user.
    final (denied, deniedBody, _) = await call('POST', '/api/staff/platform',
        cookie: cookie, body: {'packageId': 'p', 'action': 'accept'});
    expect(denied, 403);
    expect(deniedBody['error'], 'forbidden');
    expect(received, isEmpty);

    // Logout revokes the server session and clears the cookie.
    final (_, _, cleared) = await call('POST', '/api/auth/logout', cookie: cookie);
    expect(cleared, contains('Max-Age=0'));
    expect((await call('GET', '/api/state', cookie: cookie)).$1, 401);
  });

  test('signed-in identity overrides the staffId a phone claims', () async {
    auth.setSetting('lan_login_required', '1');
    final (_, _, setCookie) = await call('POST', '/api/auth/login',
        body: {'username': 'sahip', 'password': 'owner-pass-1', 'deviceId': device});
    final ownerId = auth.users().firstWhere((u) => u['isOwner'] == true)['userId'] as String;
    expect(ownerId, isNotEmpty);
    // A linked user is always stamped with their own employee id.
    expect(LanAuthGate.withIdentity({'staffId': 3},
        const AuthContext(status: 'ok', employeeId: 7)), {'staffId': 7});
    // No session (legacy shared panel, login not required): unchanged.
    expect(LanAuthGate.withIdentity({'staffId': 3}, null), {'staffId': 3});
    // Signed in but not linked to an employee (here the owner): the phone's
    // staffId is never trusted, so the action is refused before it runs.
    final (status, body, _) = await call('POST', '/api/staff/platform',
        cookie: cookieOf(setCookie), body: {'staffId': 3, 'packageId': 'p', 'action': 'accept'});
    expect(status, 422);
    expect('${body['message']}', contains('personele bağlı değil'));
    expect(received, isEmpty);
  });

  test('Android paired-device writes obey individual login and never trust staffId', () async {
    final (ps, pb, _) = await call('POST', '/api/mobile/pair',
        body: {'pin': server.pairing.pin, 'deviceName': 'Test Android'});
    expect(ps, 200, reason: '$pb');
    final token = pb['token'] as String;
    final order = {'requestId': 'mobile-order-0001', 'expectedRevision': 0, 'staffId': 1,
      'source': 'Masa', 'table': 1, 'lines': []};
    // Legacy shared mode (owner has not required login): the domain decides.
    final (legacy, _, _) = await call('POST', '/api/mobile/orders', bearer: token, body: order);
    expect(legacy, isNot(401));
    // With Bireysel giriş zorunlu, a paired device alone is not a person.
    auth.setSetting('lan_login_required', '1');
    final (noSession, nb, _) = await call('POST', '/api/mobile/orders', bearer: token, body: order);
    expect(noSession, 401, reason: '$nb');
    // A session that is not linked to an employee cannot pick one.
    final (_, _, setCookie) = await call('POST', '/api/auth/login',
        body: {'username': 'sahip', 'password': 'owner-pass-1', 'deviceId': device});
    final (unlinked, ub, _) = await call('POST', '/api/mobile/orders', bearer: token,
        cookie: cookieOf(setCookie), body: order);
    expect(unlinked, 422);
    expect('${ub['message']}', contains('personele bağlı değil'));
    expect(asMaps(store.read().data['orders']), isEmpty);
  });

  test('Android bootstrap follows required login; staff session opens it', () async {
    final (_, pb, _) = await call('POST', '/api/mobile/pair',
        body: {'pin': server.pairing.pin, 'deviceName': 'Test Android'});
    final token = pb['token'] as String;
    final (open, _, _) = await call('GET', '/api/mobile/bootstrap', bearer: token);
    expect(open, 200);
    auth.setSetting('lan_login_required', '1');
    final (closed, cb, _) = await call('GET', '/api/mobile/bootstrap', bearer: token);
    expect(closed, 401);
    expect(cb['error'], 'auth_required');
    final (_, _, setCookie) = await call('POST', '/api/auth/login',
        body: {'username': 'ayse', 'password': 'staff-pass-1', 'deviceId': device});
    final (signed, sb, _) = await call('GET', '/api/mobile/bootstrap', bearer: token, cookie: cookieOf(setCookie));
    expect(signed, 200, reason: '$sb');
  });

  test('cross-origin auth requests and repeated failures are refused', () async {
    final (cross, _, _) = await call('POST', '/api/auth/login', origin: 'http://evil.example',
        body: {'username': 'ayse', 'password': 'staff-pass-1', 'deviceId': device});
    expect(cross, 403);
    for (var i = 0; i < LanAuthGate.maxFailuresPerIp; i++) {
      await call('POST', '/api/auth/login',
          body: {'username': 'nobody$i', 'password': 'wrong-pass', 'deviceId': device});
    }
    final (throttled, _, _) = await call('POST', '/api/auth/login',
        body: {'username': 'ayse', 'password': 'staff-pass-1', 'deviceId': device});
    expect(throttled, 429);
  });

  test('idle lock: polling does not count as activity; PIN unlocks', () async {
    var now = DateTime.utc(2026, 11, 27, 12);
    final a = LocalAuth(store.authDatabase, iterations: 1000, clock: () => now);
    final g = LanAuthGate(a, clock: () => now);
    a.setSetting('lan_login_required', '1');
    final login = await g.handle('POST', 'login',
        {'username': 'ayse', 'password': 'staff-pass-1', 'deviceId': device}, ip: '10.0.0.2');
    final token = login.setToken!;
    expect((await g.handle('POST', 'pin', {'pin': '48291'}, token: token, ip: '10.0.0.2')).status, 200);
    for (var i = 0; i < 40; i++) {
      now = now.add(const Duration(minutes: 1));
      g.guard(token: token, client: 'personel', operation: 'tables.view', touch: false);
    }
    final locked = g.guard(token: token, client: 'personel', operation: 'tables.view', touch: false);
    expect(locked.status, 401);
    expect(locked.error, 'locked');
    final wrong = await g.handle('POST', 'unlock', {'pin': '00001'}, token: token, ip: '10.0.0.2');
    expect(wrong.body['error'], 'invalid_pin');
    final unlocked = await g.handle('POST', 'unlock', {'pin': '48291'}, token: token, ip: '10.0.0.2');
    expect(unlocked.status, 200);
    expect(g.guard(token: token, client: 'personel', operation: 'tables.view').allowed, true);
  });

  test('PIN change later needs the password; a wrong one is refused and throttled like login', () async {
    var now = DateTime.utc(2026, 11, 27, 12);
    final a = LocalAuth(store.authDatabase, iterations: 1000, clock: () => now);
    final g = LanAuthGate(a, clock: () => now);
    final login = await g.handle('POST', 'login',
        {'username': 'ayse', 'password': 'staff-pass-1', 'deviceId': device}, ip: '10.0.0.2');
    final token = login.setToken!;
    expect((await g.handle('POST', 'pin', {'pin': '48291'}, token: token, ip: '10.0.0.2')).status, 200);
    now = now.add(const Duration(minutes: 10));
    final bare = await g.handle('POST', 'pin', {'pin': '37162'}, token: token, ip: '10.0.0.2');
    expect(bare.body['error'], 'password_required');
    final wrong = await g.handle('POST', 'pin', {'pin': '37162', 'password': 'nope'}, token: token, ip: '10.0.0.2');
    expect(wrong.body['error'], 'invalid_credentials');
    expect(wrong.status, 403); // the session stays; the page keeps the PIN form
    final ok = await g.handle('POST', 'pin', {'pin': '37162', 'password': 'staff-pass-1'}, token: token, ip: '10.0.0.2');
    expect(ok.status, 200);
  });

  test('action to operation mapping is decided on the server', () {
    expect(LanAuthGate.operationForAction({'action': 'pay'}), 'payments.take');
    expect(LanAuthGate.operationForAction({'action': 'move'}), 'orders.move');
    expect(LanAuthGate.operationForAction({'action': 'printProductPayment'}), 'receipts.print');
    expect(LanAuthGate.operationForAction({'action': 'whatever'}), 'orders.edit');
    expect(LanAuthGate.tokenFrom(cookie: 'a=b; nohut_lan=xyz'), 'xyz');
    expect(LanAuthGate.tokenFrom(authorization: 'Bearer pairing-token'), isNull);
  });
}
