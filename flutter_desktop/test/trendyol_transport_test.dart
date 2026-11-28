// Trendyol Cloud Proxy v1 Windows client (#50), mock HTTP only.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/qr_publish_transport.dart' show QrCommandBinding;
import 'package:nohut_falafel_desktop/trendyol_transport.dart';

final token = 'a' * 64;
const binding = QrCommandBinding(
  commandId: '3f2b8c1e-9d4a-4b6e-8f1a-2c3d4e5f6a7b',
  leaseGeneration: 2,
  envelopeSha256: 'b2f1c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90');
final url = Uri.parse('https://example.supabase.co/functions/v1/trendyol-proxy');

class Sent { Map<String, String>? headers; Map? body; int calls = 0; }

CloudTrendyolProxy proxy(Sent s, {int code = 200, Object? answer, Object? error, Uri? at, String? agent}) =>
    CloudTrendyolProxy(
      endpoint: at ?? url,
      agentToken: () async => agent ?? token,
      send: (u, h, b) async {
        s..calls += 1..headers = h..body = jsonDecode(b) as Map;
        if (error != null) throw error;
        return (status: code, body: answer is String ? answer : jsonEncode(answer));
      });

void main() {
  group('source mode', () {
    test('local unless cloud is chosen AND the build enables the proxy', () {
      expect(TrendyolSourceMode.of(null).localPolls, isTrue);
      final cloud = {'trendyolSource': {'mode': 'cloud', 'epoch': 3}};
      expect(TrendyolSourceMode.of(cloud).localPolls, isTrue, reason: 'build default off');
      final on = TrendyolSourceMode.of(cloud, cloudEnabled: true);
      expect((on.cloudPolls, on.localPolls, on.epoch), (true, false, 3));
      expect(TrendyolSourceMode.of({'trendyolSource': {'mode': 'cloud', 'epoch': 0}},
          cloudEnabled: true).localPolls, isTrue, reason: 'no epoch, no authority');
      expect(TrendyolSourceMode.cloudBuildEnabled, isFalse);
    });
  });

  group('requests', () {
    test('verify sends the exact envelope; token only in its header', () async {
      final s = Sent();
      final r = await proxy(s, answer: {'version': 1, 'status': 'ok'}).verify(binding);
      expect(r.status, TrendyolProxyStatus.ok);
      expect(s.body, {'version': 1, 'action': 'verify', 'commandId': binding.commandId,
        'leaseGeneration': 2, 'envelopeSha256': binding.envelopeSha256});
      expect(s.headers!['x-nohut-agent-token'], token);
      expect(s.headers!.containsKey('authorization'), isFalse);
      expect(jsonEncode(s.body), isNot(contains(token)));
    });
    test('poll window and page are bounded; nothing sent otherwise', () async {
      final s = Sent();
      final now = DateTime.utc(2026, 11, 28);
      for (final (a, b, p) in [
        (now, now.subtract(const Duration(hours: 1)), 0),
        (now.subtract(const Duration(days: 8)), now, 0),
        (now.subtract(const Duration(hours: 1)), now, 10),
      ]) {
        expect((await proxy(s).poll(start: a, end: b, page: p)).status, TrendyolProxyStatus.refused);
      }
      expect(s.calls, 0);
      await proxy(s, answer: {'version': 1, 'status': 'ok', 'page': 0, 'hasNextPage': false, 'packages': []})
          .poll(start: now.subtract(const Duration(hours: 1)), end: now, page: 0);
      expect(s.body!.keys.toSet(), {'version', 'action', 'startMs', 'endMs', 'page', 'size'});
      expect(s.body!['size'], 50);
    });
    test('refuses locally without authority or with a bad endpoint', () async {
      final s = Sent();
      expect((await proxy(s, agent: 'short').verify(binding)).status, TrendyolProxyStatus.refused);
      expect((await proxy(s, at: Uri.parse('https://x.co/other')).verify(binding)).status, TrendyolProxyStatus.refused);
      expect((await proxy(s, at: Uri.parse('http://x.co/functions/v1/trendyol-proxy')).verify(binding)).status, TrendyolProxyStatus.refused);
      expect((await proxy(s).execute(const QrCommandBinding(commandId: 'x', leaseGeneration: 0, envelopeSha256: 'y'))).status,
        TrendyolProxyStatus.refused);
      expect(s.calls, 0);
    });
  });

  group('answers', () {
    Future<TrendyolProxyStatus> v(int code, Object body) async =>
        (await proxy(Sent(), code: code, answer: body).verify(binding)).status;
    Future<TrendyolProxyResult> x(int code, Object body, {Object? error}) =>
        proxy(Sent(), code: code, answer: body, error: error).execute(binding);

    test('verify is status only; extra data is never accepted as ok', () async {
      expect(await v(200, {'version': 1, 'status': 'ok'}), TrendyolProxyStatus.ok);
      expect(await v(200, {'version': 1, 'status': 'ok', 'packages': []}), TrendyolProxyStatus.unknown);
      expect(await v(200, {'status': 'ok'}), TrendyolProxyStatus.unreachable, reason: 'no version');
      expect(await v(401, {'version': 1, 'status': 'auth_failed'}), TrendyolProxyStatus.authFailed);
      expect(await v(503, {'version': 1, 'status': 'proxy_disabled'}), TrendyolProxyStatus.proxyDisabled);
      expect(await v(503, {'version': 1, 'status': 'unreachable'}), TrendyolProxyStatus.unreachable);
      expect(await v(200, {'version': 1, 'status': 'supplier_mismatch'}), TrendyolProxyStatus.supplierMismatch);
    });

    test('execute: only proven outcomes succeed; anything ambiguous is unknown', () async {
      expect((await x(200, {'version': 1, 'status': 'confirmed'})).status, TrendyolProxyStatus.confirmed);
      expect((await x(200, {'version': 1, 'status': 'no_change'})).status, TrendyolProxyStatus.noChange);
      for (final r in [
        await x(200, {'version': 1, 'status': 'done'}),
        await x(200, 'not json'),
        await x(500, {'version': 1}),
        await x(502, 'bad gateway'),
        await x(503, {'version': 1, 'status': 'unknown'}),
        await x(0, '', error: TimeoutException('t')),
        await x(0, '', error: StateError('reset')),
      ]) {
        expect(r.status, TrendyolProxyStatus.unknown);
        expect(r.mayHaveWritten, isTrue);
      }
      final busy = await x(409, {'version': 1, 'status': 'busy'});
      expect((busy.status, busy.mayHaveWritten), (TrendyolProxyStatus.busy, false));
      expect((await x(409, {'version': 1, 'status': 'reconciliation_required'})).mayHaveWritten, isTrue);
      expect((await x(503, {'version': 1, 'status': 'proxy_disabled'})).mayHaveWritten, isFalse);
      expect((await x(403, {'version': 1})).status, TrendyolProxyStatus.authFailed);
    });

    test('poll pages carry only the normalizer fields', () {
      final ok = CloudTrendyolProxy.interpretPoll(200, {'version': 1, 'status': 'ok', 'page': 1,
        'hasNextPage': true, 'packages': [{'id': 'p1', 'orderNumber': '42', 'lines': []}]}, 1);
      expect(ok.status, TrendyolProxyStatus.ok);
      expect(ok.page!.packages.single['id'], 'p1');
      for (final bad in [
        {'version': 1, 'status': 'ok', 'page': 2, 'hasNextPage': false, 'packages': []},
        {'version': 1, 'status': 'ok', 'page': 1, 'hasNextPage': false,
          'packages': [{'id': 'p1', 'customerEmail': 'x@y.z'}]},
        {'version': 1, 'status': 'ok', 'page': 1, 'hasNextPage': false,
          'packages': List.generate(51, (i) => {'id': '$i'})},
      ]) {
        expect(CloudTrendyolProxy.interpretPoll(200, bad, 1).status, TrendyolProxyStatus.unreachable);
      }
    });
  });
}
