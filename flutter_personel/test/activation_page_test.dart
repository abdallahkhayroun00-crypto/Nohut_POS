import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nohut_personel/activation_page.dart';
import 'package:nohut_personel/pos_api.dart';
import 'package:nohut_personel/style.dart';

import 'visual/render_harness.dart';

NohutApi activationApi(List<Map> sent) {
  var active = false;
  final a = NohutApi(client: MockClient((r) async {
    switch (r.url.path) {
      case '/api/auth/activate':
        final body = jsonDecode(r.body) as Map;
        sent.add(body);
        if (body['code'] != 'ABCD-EFGH') {
          return http.Response(jsonEncode({'error': 'invalid_activation'}), 403,
              headers: {'content-type': 'application/json'});
        }
        active = true;
        return http.Response(jsonEncode({'session': {'status': 'ok'}}), 200,
            headers: {'set-cookie': 'nohut_lan=abc123; Path=/; HttpOnly; SameSite=Strict'});
      case '/api/auth/session':
        return http.Response(jsonEncode({'required': true, 'session': active
            ? {'status': 'ok', 'username': 'ayse', 'employeeId': 7} : {'status': 'none'}}), 200);
    }
    return http.Response('{}', 404);
  }));
  a..host = 'http://192.168.1.5:8787'..token = 'x' * 40..serverId = 'synthetic';
  return a;
}

void main() {
  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await loadNohutFonts();
  });

  test('code formatter: upper case, XXXX-XXXX, 8 characters', () {
    final f = ActivationCodeFormatter();
    String fmt(String s) => f.formatEditUpdate(TextEditingValue.empty, TextEditingValue(text: s)).text;
    expect(fmt('abcd efgh'), 'ABCD-EFGH');
    expect(fmt('abc'), 'ABC');
    expect(fmt('abcdefghijk'), 'ABCD-EFGH');
  });

  for (final mode in [Brightness.light, Brightness.dark]) {
    testWidgets('activation form (${mode.name})', (t) async {
      await renderScreen(t, 'activation-${mode.name}', MaterialApp(debugShowCheckedModeBanner: false,
          theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
          home: ActivationPage(api: activationApi([]))), brightness: mode);
      expect(find.text('Etkinleştir ve Giriş Yap'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('checks locally, then Windows decides; success signs in', (t) async {
    t.view.physicalSize = const Size(412 * 3, 1400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final sent = <Map>[];
    final api = activationApi(sent);
    bool? result;
    await t.pumpWidget(MaterialApp(home: Builder(builder: (ctx) => TextButton(
      onPressed: () async => result = await Navigator.of(ctx).push<bool>(
          MaterialPageRoute(builder: (_) => ActivationPage(api: api))),
      child: const Text('aç')))));
    await t.tap(find.text('aç'));
    await t.pumpAndSettle();
    Future<void> type(String key, String v) => t.enterText(find.byKey(ValueKey('activation-$key')), v);
    await type('username', 'ayse');
    await type('code', 'abcd-efgh');
    await type('password', 'kendi-sifrem');
    await type('password2', 'baska-sifre');
    await type('pin', '48207');
    await type('pin2', '48207');
    await t.tap(find.byKey(const ValueKey('activation-submit')));
    await t.pumpAndSettle();
    expect(find.text('Şifreler aynı değil.'), findsOneWidget);
    expect(sent, isEmpty);
    await type('password2', 'kendi-sifrem');
    await type('code', 'zzzz-zzzz');
    await t.tap(find.byKey(const ValueKey('activation-submit')));
    await t.pumpAndSettle();
    expect(find.textContaining('aktivasyon kodu hatalı'), findsOneWidget);
    await type('code', 'abcdefgh');
    await t.tap(find.byKey(const ValueKey('activation-submit')));
    await t.pumpAndSettle();
    expect(result, isTrue);
    expect(sent.last['pin'], '48207');
    expect(sent.last['client'], 'personel');
    expect(api.signedIn, isTrue);
  });
}
