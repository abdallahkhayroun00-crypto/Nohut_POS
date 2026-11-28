import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/qr_publish_transport.dart';
import 'package:nohut_falafel_desktop/qr_publisher_client.dart';

const cmd = '0f8fad5b-d9cb-469f-a165-70867728950e';
const rev = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const commit = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
final token = 'c' * 64;
const binding = QrCommandBinding(commandId: cmd, leaseGeneration: 3,
  envelopeSha256: 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd');
final draft = <String, dynamic>{'products': [{'id': 1, 'price': 140}]};

class Sent { Uri? url; Map<String, String>? headers; Json? body; int calls = 0; }

CloudQrPublishTransport cloud(Sent s, {int code = 200, Json? answer,
    Object? error, String? agent, Uri? endpoint}) =>
  CloudQrPublishTransport(
    endpoint: endpoint ?? Uri.parse('https://x.supabase.co/functions/v1/qr-publisher'),
    agentToken: () async => agent ?? token,
    send: (url, headers, body) async {
      s
        ..url = url
        ..headers = headers
        ..body = jsonDecode(body) as Json;
      s.calls++;
      if (error != null) throw error;
      return (status: code, body: jsonEncode(answer ?? {}));
    });

class FakeClient extends QrPublisherClient {
  FakeClient(this.behaviour) : super('db', testToken: 'x' * 40);
  final Object behaviour;
  @override
  Future<Map<String, dynamic>> publish(String e, String r, Json m) async {
    if (behaviour is Exception) throw behaviour as Exception;
    return behaviour as Map<String, dynamic>;
  }
}

void main() {
  group('cloud transport request', () {
    test('sends exactly the dispatcher keys, the agent token only in the header', () async {
      final s = Sent();
      final out = await cloud(s, answer: {'requestId': cmd, 'status': 'committed',
        'commit': commit, 'revision': rev, 'pages': 'unverified'})
          .publish(QrPublishRequest(draft: draft, expectedRevision: rev, binding: binding));
      expect(out.status, QrPublishStatus.committed);
      expect(out.revision, rev);
      expect(s.body!.keys.toSet(), {'operation', 'commandId', 'leaseGeneration',
        'envelopeSha256', 'expectedRevision', 'expectedStamp', 'draftJson', 'activateConfirmed'});
      expect(s.body!['activateConfirmed'], isFalse);
      expect(s.body!['draftJson'], jsonEncode(draft), reason: 'original draft, not a projection');
      final full = QrPublishRequest(draft: draft, expectedRevision: rev).draftSha256;
      expect(full, hasLength(64));
      expect(s.body!['expectedStamp'], full.substring(0, 16));
      expect(s.headers!['authorization'], 'Bearer $token');
      expect(jsonEncode(s.body), isNot(contains(token)));
    });

    test('refuses locally (sends nothing) without authority or with bad inputs', () async {
      for (final (t, r) in [
        (cloud(Sent()), QrPublishRequest(draft: draft, expectedRevision: rev)),
        (cloud(Sent()), QrPublishRequest(draft: draft, expectedRevision: 'sha-1', binding: binding)),
        (cloud(Sent(), agent: 'short'), QrPublishRequest(draft: draft, expectedRevision: rev, binding: binding)),
        (cloud(Sent(), endpoint: Uri.parse('http://x.co/qr')), QrPublishRequest(draft: draft, expectedRevision: rev, binding: binding)),
        (cloud(Sent()), QrPublishRequest(draft: draft, expectedRevision: rev,
          binding: const QrCommandBinding(commandId: 'nope', leaseGeneration: 0, envelopeSha256: 'x'))),
      ]) {
        final out = await t.publish(r);
        expect(out.status, QrPublishStatus.refused);
        expect(out.mayHaveWritten, isFalse);
      }
    });

    test('reconcile and cancel carry the target and nothing else', () async {
      final s = Sent();
      const target = '7c9e6679-7425-40de-944b-e07fc1f90ae7';
      await cloud(s, code: 404, answer: {'requestId': target, 'status': 'not_found'})
          .reconcile(target, binding: binding);
      expect(s.body, {'operation': 'reconcile', 'commandId': cmd, 'leaseGeneration': 3,
        'envelopeSha256': binding.envelopeSha256, 'targetRequestId': target});
      final c = Sent();
      final out = await cloud(c, answer: {'requestId': target, 'status': 'cancelled_before_attempt'})
          .cancelBeforeAttempt(target, binding: binding);
      expect(c.body!['operation'], 'cancel_before_attempt');
      expect(out.status, QrPublishStatus.cancelledBeforeAttempt);
    });
  });

  group('cloud transport answers', () {
    QrPublishStatus read(int code, Object body) =>
        CloudQrPublishTransport.interpret(code, jsonEncode(body), cmd).status;
    test('only a fully valid answer is success', () {
      expect(read(200, {'requestId': cmd, 'status': 'committed', 'commit': commit, 'revision': rev}),
        QrPublishStatus.committed);
      expect(read(200, {'requestId': cmd, 'status': 'no_change', 'revision': rev}),
        QrPublishStatus.noChange);
      expect(read(200, {'requestId': cmd, 'status': 'committed', 'commit': 'abc', 'revision': rev}),
        QrPublishStatus.unknown);
      expect(read(200, {'requestId': 'other', 'status': 'committed', 'commit': commit, 'revision': rev}),
        QrPublishStatus.unknown);
      expect(CloudQrPublishTransport.interpret(200, 'not json', cmd).status, QrPublishStatus.unknown);
    });
    test('conflict family, refusals and server failures', () {
      expect(read(409, {'requestId': cmd, 'status': 'busy'}), QrPublishStatus.busy);
      expect(read(409, {'requestId': cmd, 'status': 'conflict'}), QrPublishStatus.conflict);
      expect(read(409, {'requestId': cmd, 'status': 'reconciliation_required'}),
        QrPublishStatus.reconciliationRequired);
      for (final c in [400, 401, 403, 405]) {
        expect(read(c, {'error': 'x'}), QrPublishStatus.refused);
      }
      expect(read(503, {'error': 'publisher_disabled'}), QrPublishStatus.refused);
      expect(read(503, {'error': 'publisher_unavailable'}), QrPublishStatus.unknown);
      expect(read(500, {}), QrPublishStatus.unknown);
      expect(read(502, {}), QrPublishStatus.unknown);
    });
    test('lost connection and timeout are unknown, never refused', () async {
      for (final e in [TimeoutException('t'), const SocketException('reset')]) {
        final out = await cloud(Sent(), error: e)
            .publish(QrPublishRequest(draft: draft, expectedRevision: rev, binding: binding));
        expect(out.status, QrPublishStatus.unknown);
        expect(out.mayHaveWritten, isTrue);
      }
    });
  });

  group('local transport', () {
    Future<QrPublishStatus> run(Object b) async => (await LocalQrPublishTransport(
      FakeClient(b), 'http://127.0.0.1:18787')
        .publish(QrPublishRequest(draft: draft, expectedRevision: 'sha-1'))).status;
    test('5xx after sending is unknown; 4xx is a refusal; 409 a conflict', () async {
      expect(await run({'published': true, 'revision': 'sha-2', 'commit': 'c1'}),
        QrPublishStatus.committed);
      expect(await run({'published': false}), QrPublishStatus.unknown);
      expect(await run(const QrPublisherRefused('GitHub HTTP 502', 502)), QrPublishStatus.unknown);
      expect(await run(const QrPublisherRefused('Yayın hizmeti başarısız', 503)), QrPublishStatus.unknown);
      expect(await run(const QrPublisherRefused('İçerik değişti', 409)), QrPublishStatus.conflict);
      expect(await run(const QrPublisherRefused('Geçersiz', 422)), QrPublishStatus.refused);
      expect(await run(const QrPublisherNoAnswer('down')), QrPublishStatus.unknown);
    });
  });

  group('router', () {
    final local = LocalQrPublishTransport(FakeClient(const {}), 'http://127.0.0.1:18787');
    test('local by default; cloud only when chosen and configured', () {
      final r = QrPublishRouter(local: local);
      expect(r.forNew({}, null).transport, same(local));
      expect(r.forNew({'qrPublishTransport': 'cloud'}, null).transport, isNull);
      final c = cloud(Sent());
      final both = QrPublishRouter(local: local, cloud: c);
      expect(both.forNew({'qrPublishTransport': 'cloud'}, null).transport, same(c));
    });
    test('an unresolved publish blocks new ones and stays with its transport', () {
      final c = cloud(Sent());
      final r = QrPublishRouter(local: local, cloud: c);
      expect(r.forNew({}, {'transport': 'cloud'}).transport, isNull);
      expect(r.forPending({'transport': 'cloud'}), same(c));
      expect(r.forPending({'transport': 'local'}), same(local));
      expect(QrPublishRouter(local: local).forPending({'transport': 'cloud'}), isNull,
        reason: 'never resolved through the local publisher');
    });
  });
}
