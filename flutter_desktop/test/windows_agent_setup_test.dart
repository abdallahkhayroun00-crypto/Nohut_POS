import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/supabase_agent_transport.dart';
import 'package:nohut_falafel_desktop/sync_worker.dart';
import 'package:nohut_falafel_desktop/windows_agent_setup.dart';
import 'package:nohut_falafel_desktop/windows_vault.dart';

import 'support/synthetic_agent_secrets.dart';

void main() {
  test(
    'production secrets use DPAPI, exclude plaintext and serialize setup',
    () async {
      final folder = Directory.systemTemp.createTempSync(
        'nohut-agent-setup-vault',
      );
      try {
        final vault = WindowsVault(
          File('${folder.path}/synthetic-agent.dpapi'),
        );
        final secrets = WindowsAgentSecrets(vault),
            second = WindowsAgentSecrets(vault);
        const token = 'synthetic-token-not-a-live-credential';
        await secrets.exclusively(() async {
          await secrets.save({
            'pendingEnrollment': {'token': token},
          });
          await expectLater(
            second.exclusively(() async {}),
            throwsA(isA<AgentTransportException>()),
          );
        });
        expect((await secrets.load())!['pendingEnrollment']['token'], token);
        expect(await vault.file.readAsString(), isNot(contains(token)));
        expect(
          await AgentCredentials.load(vault),
          null,
          reason: 'pending setup cannot become an active credential',
        );
        await secrets.exclusively(() async {});
      } finally {
        folder.deleteSync(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
  const restaurant = '10000000-0000-4000-8000-000000000001',
      epoch = '20000000-0000-4000-8000-000000000001',
      device = '30000000-0000-4000-8000-000000000001',
      agent = '40000000-0000-4000-8000-000000000001';
  final at = DateTime.utc(2026, 11, 27, 12);
  late HttpServer server;
  late WindowsAgentSetup setup;
  late SyntheticAgentSecrets secrets;
  final bodies = <Map<String, dynamic>>[];
  var loseAck = false, foreign = false, owner = true;
  setUp(() async {
    bodies.clear();
    loseAck = false;
    foreign = false;
    owner = true;
    secrets = SyntheticAgentSecrets();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(
        request.headers.value('authorization'),
        'Bearer synthetic-access-token',
      );
      final body = Map<String, dynamic>.from(
        jsonDecode(await utf8.decoder.bind(request).join()) as Map,
      );
      if (request.uri.path.endsWith('nohut_enroll_agent')) {
        expect(
          secrets.persisted?['pendingEnrollment'],
          isNotNull,
          reason: 'save before network',
        );
        bodies.add(body);
        if (loseAck) {
          loseAck = false;
          request.response.statusCode = 503;
          await request.response.close();
          return;
        }
      }
      final reply = request.uri.path.endsWith('nohut_windows_owner_session')
          ? {
              'status': owner ? 'ok' : 'mfa_required',
              'restaurant_id': restaurant,
              'device_id': device,
              'aal': 'aal2',
              'permission_version': 1,
              'user_id': '50000000-0000-4000-8000-000000000001',
              'session_id': '60000000-0000-4000-8000-000000000001',
            }
          : request.uri.path.endsWith('nohut_revoke_agent')
          ? {'status': 'revoked', 'agent_id': agent}
          : {
              'status': 'enrolled',
              'restaurant_id': foreign ? 'foreign' : restaurant,
              'authority_epoch': epoch,
              'windows_device_id': device,
              'agent_id': agent,
              'expires_at': at.add(const Duration(days: 30)).toIso8601String(),
              'schema_version': 1,
            };
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(reply));
      await request.response.close();
    });
    setup = WindowsAgentSetup(
      url: Uri.parse('http://127.0.0.1:${server.port}'),
      publishableKey: 'sb_publishable_synthetic_test_key',
      deviceId: device,
      restaurantId: restaurant,
      authorityEpoch: epoch,
      accessToken: () async => 'synthetic-access-token',
      secrets: secrets,
      allowLoopbackHttpForTests: true,
      clock: () => at,
    );
  });
  tearDown(() async {
    setup.close();
    await server.close(force: true);
  });
  test(
    'lost enrollment ACK retains one durable request; raw token never enters HTTP',
    () async {
      loseAck = true;
      await expectLater(
        setup.enrollOrRotate(permissionVersion: 1),
        throwsA(isA<SyncNetworkException>()),
      );
      final pending = secrets.persisted!['pendingEnrollment'] as Map;
      final token = pending['token'] as String;
      expect(token, hasLength(64));
      expect(
        bodies.single['p_token_sha256'],
        hash.sha256.convert(utf8.encode(token)).toString(),
      );
      expect(jsonEncode(bodies), isNot(contains(token)));
      final credentials = await setup.enrollOrRotate(permissionVersion: 1);
      expect(bodies, hasLength(2));
      expect(bodies[0], bodies[1]);
      expect(credentials.token, token);
      expect(secrets.persisted!.containsKey('pendingEnrollment'), false);
      expect(
        jsonEncode(secrets.persisted),
        isNot(contains('synthetic-access-token')),
      );
      await setup.revoke(permissionVersion: 1);
      expect(secrets.persisted!['token'], null);
      expect(secrets.persisted!['revoked'], true);
    },
  );
  test(
    'malformed or foreign confirmation never activates a pending credential',
    () async {
      foreign = true;
      await expectLater(
        setup.enrollOrRotate(permissionVersion: 1),
        throwsA(isA<AgentTransportException>()),
      );
      expect(secrets.persisted!['pendingEnrollment'], isNotNull);
      expect(secrets.persisted!['token'], null);
      foreign = false;
      await setup.enrollOrRotate(permissionVersion: 1);
      expect(bodies[0], bodies[1]);
    },
  );
  test('MFA or permission mismatch cannot create a pending token', () async {
    owner = false;
    await expectLater(
      setup.enrollOrRotate(permissionVersion: 1),
      throwsA(isA<AgentTransportException>()),
    );
    owner = true;
    await expectLater(
      setup.enrollOrRotate(permissionVersion: 2),
      throwsA(isA<AgentTransportException>()),
    );
    expect(secrets.saves, 0);
    expect(bodies, isEmpty);
  });
  test(
    'project/epoch change is fenced and concurrent setup is refused',
    () async {
      secrets.persisted = {
        'url': 'https://other.invalid',
        'restaurantId': restaurant,
        'authorityEpoch': epoch,
      };
      await expectLater(
        setup.enrollOrRotate(permissionVersion: 1),
        throwsA(isA<AgentTransportException>()),
      );
      secrets.busy = true;
      await expectLater(
        setup.enrollOrRotate(permissionVersion: 1),
        throwsA(isA<AgentTransportException>()),
      );
      expect(bodies, isEmpty);
    },
  );
}
