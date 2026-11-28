import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nohut_personel/cloud_command_channel.dart';

void main() {
  const id = '10000000-0000-4000-8000-000000000001';
  CloudCommandChannel channel(http.Client client, {bool online = true}) => CloudCommandChannel(
    url: Uri.parse('https://synthetic.supabase.co'), publishableKey: 'sb_publishable_synthetic_test_key',
    session: () async => const CloudCommandSession(accessToken: 'synthetic-jwt', deviceId: id,
      client: 'personel', permissionVersion: 1), authorityAvailable: () => online, client: client);

  test('enqueue stays pending, status requires authoritative confirmation', () async {
    final c = channel(MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      expect(body['p_request_id'], id);
      expect(body.containsKey('p_user_id'), false);
      expect(request.headers['Authorization'], 'Bearer synthetic-jwt');
      return http.Response(request.url.path.endsWith('nohut_enqueue_command')
        ? '{"status":"accepted"}' : '{"state":"confirmed","result":{"ok":true}}', 200);
    }));
    expect((await c.enqueue(id, 'clock_in_out', {'action':'clockIn'})).state, CloudCommandState.pending);
    expect((await c.status(id)).state, CloudCommandState.confirmed);
    c.close();
  });
  test('offline never sends, lost ACK never generates a new request identity', () async {
    var calls = 0;
    final client = MockClient((request) async { calls++; throw http.ClientException('synthetic failure'); });
    final offline = channel(client, online: false);
    await expectLater(offline.enqueue(id, 'clock_in_out', {'action':'clockIn'}), throwsA(isA<CloudCommandException>()));
    expect(calls, 0);
    final online = channel(client);
    final result = await online.enqueue(id, 'clock_in_out', {'action':'clockIn'});
    expect(result.requestId, id);
    expect(result.state, CloudCommandState.pending);
    expect(calls, 1);
    online.close();
  });
  test('revocation and uncertain platform outcomes never become success', () async {
    final c = channel(MockClient((r) async => http.Response('{"state":"reconciliation_required"}', 200)));
    expect((await c.status(id)).state, CloudCommandState.reconciliationRequired);
    c.close();
    final denied = channel(MockClient((r) async => http.Response('{}', 403)));
    await expectLater(denied.enqueue(id, 'clock_in_out', {'action':'clockIn'}), throwsA(isA<CloudCommandException>()));
    denied.close();
  });
}
