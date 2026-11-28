import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/cloud_capabilities.dart';
import 'package:nohut_falafel_desktop/supabase_agent_transport.dart';

final _token = 'a' * 64;

AgentCredentials _creds() => AgentCredentials(
    url: Uri.parse('https://example.supabase.co'),
    publishableKey: 'sb_publishable_testtesttesttesttest', token: _token,
    restaurantId: 'r', authorityEpoch: '1');

String _body({bool qr = false, bool tgo = false, bool ys = false}) => jsonEncode({
  'version': 1, 'qrPublish': qr,
  'providers': {'trendyol_go': tgo, 'yemeksepeti': ys, 'migros_yemek': false, 'uber_eats': false},
});

void main() {
  test('strict parse: valid v1, and anything else is fail-closed', () {
    final ok = CloudCapabilities.parse(jsonDecode(_body(qr: true, tgo: true)));
    expect(ok.qrPublish, isTrue);
    expect(ok.has(CloudProvider.trendyolGo), isTrue);
    expect(ok.has(CloudProvider.yemeksepeti), isFalse);
    for (final bad in [null, 'x', {'version': 2}, {'version': 1, 'qrPublish': 'true', 'providers': {}},
        {'version': 1, 'qrPublish': true, 'providers': {'evil': true}},
        {'version': 1, 'qrPublish': true, 'providers': {'trendyol_go': 'yes'}}]) {
      final c = CloudCapabilities.parse(bad);
      expect(c.qrPublish, isFalse);
      expect(c.providers, isEmpty);
    }
  });

  test('source sends only the agent token, caches, and fails closed', () async {
    var calls = 0;
    Map<String, String>? seen;
    final src = CloudCapabilitiesSource(
      credentials: () async => _creds(),
      fetch: (url, headers) async {
        calls++;
        seen = headers;
        expect(url.path, '/functions/v1/cloud-capabilities');
        return (status: 200, body: _body(qr: true));
      },
    );
    expect((await src.load()).qrPublish, isTrue);
    await src.load();
    expect(calls, 1);
    expect(seen!['x-nohut-agent-token'], _token);

    for (final r in [
      CloudCapabilitiesSource(credentials: () async => null),
      CloudCapabilitiesSource(credentials: () async => _creds(),
          fetch: (u, h) async => (status: 503, body: '{}')),
      CloudCapabilitiesSource(credentials: () async => _creds(),
          fetch: (u, h) async => throw Exception('offline')),
      CloudCapabilitiesSource(credentials: () async => _creds(),
          fetch: (u, h) async => (status: 200, body: 'not json')),
    ]) {
      expect((await r.load()).qrPublish, isFalse);
    }
  });

  testWidgets('prompt is replaced only when the cloud holds the secret', (t) async {
    Widget app(bool on) => MaterialApp(home: Scaffold(body: CloudManaged(
      source: CloudCapabilitiesSource(credentials: () async => _creds(),
        fetch: (u, h) async => (status: 200, body: _body(qr: on))),
      title: 'QR Menü yayıncısı (GitHub)',
      isManaged: (c) => c.qrPublish,
      child: const Text('PEM sor'))));
    await t.pumpWidget(app(false));
    await t.pumpAndSettle();
    expect(find.text('PEM sor'), findsOneWidget);
    await t.pumpWidget(app(true));
    await t.pumpAndSettle();
    expect(find.text('PEM sor'), findsNothing);
    expect(find.byKey(const ValueKey('cloud-managed-QR Menü yayıncısı (GitHub)')), findsOneWidget);
  });
}
