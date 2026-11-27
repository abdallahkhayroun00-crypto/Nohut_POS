import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/remote_commands.dart';
import 'package:nohut_falafel_desktop/supabase_agent_transport.dart';
import 'package:nohut_falafel_desktop/sync_worker.dart';

void main() {
  final at = DateTime.utc(2026, 11, 27, 12);
  const restaurant = '10000000-0000-4000-8000-000000000001';
  const epoch = '20000000-0000-4000-8000-000000000001';
  late HttpServer server;
  late SupabaseAgentTransport transport;
  final requests = <Map<String, dynamic>>[];
  Object? reply;
  int status = 200;
  AgentCredentials credentials(Uri url, {String key = 'sb_publishable_synthetic_test_key'}) =>
      AgentCredentials(url: url, publishableKey: key, token: 'a' * 64,
          restaurantId: restaurant, authorityEpoch: epoch);

  setUp(() async {
    requests.clear();
    reply = null;
    status = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add({'path': request.uri.path, 'key': request.headers.value('apikey'),
        'body': jsonDecode(await utf8.decoder.bind(request).join())});
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(reply));
      await request.response.close();
    });
    transport = SupabaseAgentTransport(credentials(Uri.parse('http://127.0.0.1:${server.port}')),
        allowLoopbackHttpForTests: true, clock: () => at);
  });
  tearDown(() async { transport.close(); await server.close(force: true); });

  test('only TLS and publishable credentials are accepted', () {
    for (final url in ['http://example.com', 'https://user:pass@example.com', 'https://example.com/?token=x']) {
      expect(() => SupabaseAgentTransport(credentials(Uri.parse(url))), throwsA(isA<AgentTransportException>()));
    }
    expect(() => SupabaseAgentTransport(credentials(Uri.parse('https://example.com'), key: 'sb_secret_forbidden')),
        throwsA(isA<AgentTransportException>()));
  });

  test('ingest preserves exact event bytes and only accepts a durable checkpoint', () async {
    final tx = SyncTransaction(authorityEpoch: epoch, sourceRevision: 1, events: [
      const SyncEvent(seq: 1, eventId: 'e1', entityType: 'employees', entityId: 'core',
        op: 'upsert', payloadJson: '[]', payloadSha256: 'synthetic', ordinal: 0),
    ]);
    reply = {'status': 'accepted', 'acked_through_seq': 1};
    expect((await transport.ingest(tx)).status, IngestStatus.accepted);
    final body = requests.single['body'] as Map;
    expect(body['p_tx'], tx.toJson());
    expect(body['p_token'], 'a' * 64);
    expect(requests.single['key'], 'sb_publishable_synthetic_test_key');
    reply = {'status': 'accepted'};
    await expectLater(transport.ingest(tx), throwsA(isA<AgentTransportException>()));
  });

  test('claims carry generations, authority and conservative lease deadlines', () async {
    final envelope = {'request_id': 'synthetic-request', 'restaurant_id': restaurant,
      'authority_epoch': epoch, 'schema_version': 1};
    reply = {'restaurant_id': restaurant, 'authority_epoch': epoch, 'server_now': at.toIso8601String(),
      'claims': [{'envelope': envelope, 'lease_generation': 3,
        'lease_until': at.add(const Duration(minutes: 1)).toIso8601String()}]};
    final claim = (await transport.claim(max: 1)).single;
    expect(claim.generation, 3);
    expect(claim.leaseUntil, at.add(const Duration(seconds: 55)));
    reply = true;
    expect(await transport.validate(claim), true);
    expect((requests.last['body'] as Map)['p_generation'], 3);
    reply = 'accepted';
    await transport.complete(claim, {'state': 'confirmed'});
    expect((requests.last['body'] as Map)['p_envelope_sha256'], envelopeSha256(envelope));
    reply = 'stale_claim';
    await expectLater(transport.complete(claim, {'state': 'confirmed'}), throwsA(isA<AgentTransportException>()));
  });

  test('foreign authority, clock skew and malformed responses fail closed', () async {
    reply = {'restaurant_id': 'foreign', 'authority_epoch': epoch, 'claims': []};
    await expectLater(transport.claim(max: 1), throwsA(isA<AgentTransportException>()));
    reply = {'restaurant_id': restaurant, 'authority_epoch': epoch, 'claims': [],
      'server_now': at.subtract(const Duration(minutes: 1)).toIso8601String()};
    await expectLater(transport.claim(max: 1), throwsA(isA<AgentTransportException>()));
  });

  test('temporary network failures retry; refused credentials require intervention', () async {
    status = 503;
    await expectLater(transport.checkpoint(), throwsA(isA<SyncNetworkException>()));
    status = 403;
    await expectLater(transport.checkpoint(), throwsA(predicate((e) => e.toString() == 'Cloud agent: authentication_denied')));
  });
}
