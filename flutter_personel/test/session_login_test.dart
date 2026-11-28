// The Android Personel app signs in with an individual account. The session
// cookie is kept in secure storage and sent with every LAN request; the
// server, not a picker, decides who the acting employee is.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter/material.dart';
import 'package:nohut_personel/home.dart';
import 'package:nohut_personel/pos_api.dart';
import 'package:nohut_personel/style.dart';

void main() {
  test('login stores the session, sends it, and logout clears it', () async {
    FlutterSecureStorage.setMockInitialValues({
      'lanUrl': 'http://192.168.1.5:8787', 'deviceToken': 'x' * 40, 'serverId': 'server-1234567890',
    });
    final seen = <http.Request>[];
    var loggedIn = false;
    final client = MockClient((r) async {
      seen.add(r);
      switch (r.url.path) {
        case '/api/auth/login':
          final body = jsonDecode(r.body) as Map;
          if (body['password'] != 'staff-pass-1') {
            return http.Response(jsonEncode({'error': 'invalid_credentials'}), 401);
          }
          loggedIn = true;
          return http.Response(jsonEncode({'session': {'status': 'ok'}}), 200,
              headers: {'set-cookie': 'nohut_lan=abc123; Path=/; HttpOnly; SameSite=Strict'});
        case '/api/auth/session':
          return http.Response(jsonEncode({'required': true, 'session': loggedIn && r.headers['cookie'] == 'nohut_lan=abc123'
              ? {'status': 'ok', 'username': 'personela', 'employeeId': 7} : {'status': 'none'}}), 200);
        case '/api/auth/logout':
          loggedIn = false;
          return http.Response(jsonEncode({'ok': true}), 200,
              headers: {'set-cookie': 'nohut_lan=; Path=/; Max-Age=0'});
        case '/api/mobile/orders':
          return http.Response(jsonEncode({'ok': true, 'orderId': 1}), 200);
      }
      return http.Response('{}', 404);
    });
    final api = NohutApi(client: client);
    await api.restore();
    await expectLater(api.login('personela', 'wrong'), throwsA(isA<FormatException>()
        .having((e) => e.message, 'message', 'Kullanıcı adı veya şifre hatalı.')));
    expect(api.signedIn, false);
    await api.login('personela', 'staff-pass-1');
    expect(api.signedIn, true);
    expect(api.sessionEmployeeId, 7);
    expect(api.employeeId, '7', reason: 'the picker follows the session');
    await api.submitOrder({'requestId': 'r1'});
    final order = seen.lastWhere((r) => r.url.path == '/api/mobile/orders');
    expect(order.headers['cookie'], 'nohut_lan=abc123');
    expect(order.headers['authorization'], startsWith('Bearer '));
    // A restart restores the session from secure storage.
    final again = NohutApi(client: client);
    await again.restore();
    expect(again.session, 'abc123');
    await api.logout();
    expect(api.session, isNull);
    expect(api.signedIn, false);
    final fresh = NohutApi(client: client);
    await fresh.restore();
    expect(fresh.session, isNull);
  });

  testWidgets('PIN Değiştir sends the password and new PIN; a wrong password stays on the sheet', (t) async {
    FlutterSecureStorage.setMockInitialValues({
      'lanUrl': 'http://192.168.1.5:8787', 'deviceToken': 'x' * 40, 'serverId': 'server-1234567890', 'lanSession': 'abc123',
    });
    final pins = <Map>[];
    final client = MockClient((r) async {
      switch (r.url.path) {
        case '/api/auth/session':
          return http.Response(jsonEncode({'session': {'status': 'ok', 'username': 'personela', 'employeeId': 7}}), 200);
        case '/api/auth/pin':
          final b = jsonDecode(r.body) as Map;
          pins.add(b);
          return b['password'] == 'staff-pass-1'
              ? http.Response(jsonEncode({'ok': true}), 200)
              : http.Response(jsonEncode({'error': 'invalid_credentials'}), 403);
      }
      return http.Response('{}', 404);
    });
    final api = NohutApi(client: client);
    await api.restore();
    await api.refreshSession();
    final c = PersonelController(api, StaffNotifications())
      ..state = {'employees': [{'id': 7, 'name': 'Test Personel A', 'active': true}], 'localMenu': [], 'orders': []}
      ..online = true;
    addTearDown(c.dispose);
    t.view.physicalSize = const Size(412, 915) * 2;
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: NohutStyle.theme, home: StaffHome(controller: c, onUnpair: () {})));
    await t.pumpAndSettle();
    await t.tap(find.text('Daha Fazla').last);
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.byKey(const ValueKey('change-pin')), 200, scrollable: find.byType(Scrollable).first);
    await t.tap(find.byKey(const ValueKey('change-pin')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('pin-password')), 'wrong');
    await t.enterText(find.byKey(const ValueKey('pin-new')), '47302');
    await t.tap(find.text('PIN Kaydet'));
    await t.pumpAndSettle();
    expect(find.text('Kullanıcı adı veya şifre hatalı.'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('pin-password')), 'staff-pass-1');
    await t.tap(find.text('PIN Kaydet'));
    await t.pumpAndSettle();
    expect(find.text('PIN kaydedildi.'), findsOneWidget);
    expect(pins.last, allOf(containsPair('pin', '47302'), containsPair('password', 'staff-pass-1')));
    expect(t.takeException(), isNull);
  });
}
