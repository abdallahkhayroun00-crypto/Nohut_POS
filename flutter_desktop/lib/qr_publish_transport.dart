// QR publish transport: the one seam between the Windows-authoritative draft
// and whatever actually writes the public QR repository.
//
// * `local`: today's loopback Nohut QR Publisher (QrPublisherClient).
// * `cloud`: the Supabase Edge "qr-publisher" v2 client (PR #49 contract,
//   docs/contracts/v1/qr-publisher-edge-v2.md). Not deployed; off by default
//   and only reachable with an explicit endpoint and the existing Windows
//   agent token. Tests use a mock HTTP sender only.
//
// Rules that hold for every transport:
// * Only an answer the client can fully validate counts as success. A
//   timeout, a 5xx, a malformed body or a lost connection is `unknown`.
// * An unknown publish is recorded with the transport that sent it and is
//   only ever resolved through that same transport (never retried or
//   "fixed" through the other one).
// * No GitHub key, service key or token is ever put in a body or a log.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'pos_logic.dart';
import 'qr_publisher_client.dart';

enum QrTransportKind { local, cloud }

enum QrPublishStatus {
  committed,
  noChange,
  cancelledBeforeAttempt,
  notFound,
  busy,
  conflict,
  reconciliationRequired,
  /// The server refused before doing anything (400/401/403/405/503 disabled).
  refused,
  /// Anything that may or may not have written: block retries, reconcile.
  unknown,
}

class QrPublishOutcome {
  const QrPublishOutcome(this.status, {
    this.requestId, this.revision, this.commit, this.reason,
  });
  final QrPublishStatus status;
  final String? requestId, revision, commit;
  /// Short machine reason (`unauthorized`, `publisher_disabled`, `timeout`…).
  final String? reason;

  bool get wrote => status == QrPublishStatus.committed;
  bool get mayHaveWritten => status == QrPublishStatus.unknown ||
      status == QrPublishStatus.reconciliationRequired;
}

/// The authority the cloud requires for every call: the claimed remote
/// command (id, lease generation, canonical envelope hash). Issued by the
/// command queue, never invented by the client.
class QrCommandBinding {
  const QrCommandBinding({
    required this.commandId,
    required this.leaseGeneration,
    required this.envelopeSha256,
  });
  final String commandId;
  final int leaseGeneration;
  final String envelopeSha256;

  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
  static final _hex64 = RegExp(r'^[a-f0-9]{64}$');
  bool get valid => _uuid.hasMatch(commandId) && leaseGeneration >= 1 &&
      _hex64.hasMatch(envelopeSha256);
}

class QrPublishRequest {
  const QrPublishRequest({
    required this.draft,
    required this.expectedRevision,
    this.binding,
  });
  /// The authoritative Windows draft, sent exactly as stored.
  final Json draft;
  final String expectedRevision;
  /// Required by the cloud transport; ignored by the local one.
  final QrCommandBinding? binding;

  /// Canonical text of the draft that is sent and fingerprinted.
  String get draftJson => jsonEncode(draft);
  /// Full SHA-256 of [draftJson] (the final confirmation hash under
  /// discussion on #49; recorded locally now, sent once the contract has it).
  String get draftSha256 => sha256.convert(utf8.encode(draftJson)).toString();
  /// Current wire stamp: first 16 hex of the same hash (`qrDraftStamp`).
  String get expectedStamp => draftSha256.substring(0, 16);
}

abstract class QrPublishTransport {
  QrTransportKind get kind;
  Future<QrPublishOutcome> publish(QrPublishRequest request);
  /// Resolve an earlier unknown outcome. Read-only towards GitHub.
  Future<QrPublishOutcome> reconcile(String requestId,
      {QrCommandBinding? binding});
}

/// Today's loopback publisher behind the transport seam.
class LocalQrPublishTransport implements QrPublishTransport {
  LocalQrPublishTransport(this.client, this.endpoint);
  final QrPublisherClient client;
  final String endpoint;
  @override QrTransportKind get kind => QrTransportKind.local;

  @override
  Future<QrPublishOutcome> publish(QrPublishRequest r) async {
    try {
      final a = await client.publish(endpoint, r.expectedRevision, r.draft);
      final rev = a['revision']?.toString();
      if (a['published'] == true && rev != null && rev.isNotEmpty) {
        return QrPublishOutcome(QrPublishStatus.committed,
          revision: rev, commit: a['commit']?.toString());
      }
      return const QrPublishOutcome(QrPublishStatus.unknown,
        reason: 'unexpected_answer');
    } on QrPublisherRefused catch (e) {
      // 5xx may follow a started GitHub write: never treat it as a refusal.
      if (e.statusCode >= 500) {
        return QrPublishOutcome(QrPublishStatus.unknown, reason: e.message);
      }
      return QrPublishOutcome(e.statusCode == 409
          ? QrPublishStatus.conflict : QrPublishStatus.refused,
        reason: e.message);
    } on QrPublisherNoAnswer catch (e) {
      return QrPublishOutcome(QrPublishStatus.unknown, reason: e.message);
    } on FormatException catch (e) {
      // Raised before sending (endpoint/key checks): nothing was written.
      return QrPublishOutcome(QrPublishStatus.refused, reason: e.message);
    }
  }

  /// The loopback publisher has no request ledger; the caller compares the
  /// live GitHub revision (catalog) with the pending marker instead.
  @override
  Future<QrPublishOutcome> reconcile(String requestId,
          {QrCommandBinding? binding}) async =>
      const QrPublishOutcome(QrPublishStatus.refused,
        reason: 'local_reconcile_by_catalog');
}

/// Minimal HTTP seam so tests never open a socket.
typedef QrHttpSend = Future<({int status, String body})> Function(
    Uri url, Map<String, String> headers, String body);

Future<({int status, String body})> _defaultSend(
    Uri url, Map<String, String> headers, String body) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.postUrl(url).timeout(const Duration(seconds: 15));
    req.followRedirects = false;
    headers.forEach(req.headers.set);
    req.write(body);
    final res = await req.close().timeout(const Duration(seconds: 60));
    final text = await utf8.decoder.bind(res).join()
        .timeout(const Duration(seconds: 60));
    return (status: res.statusCode, body: text);
  } finally {
    client.close(force: true);
  }
}

/// Supabase Edge `qr-publisher` v2 client. Mirrors the server dispatcher's
/// exact request keys and its response rules; anything else is unknown.
class CloudQrPublishTransport implements QrPublishTransport {
  CloudQrPublishTransport({
    required this.endpoint,
    required this.agentToken,
    QrHttpSend? send,
  }) : send = send ?? _defaultSend;
  final Uri endpoint;
  /// The existing Windows agent credential (x-nohut-agent-token); 64 hex.
  final Future<String?> Function() agentToken;
  final QrHttpSend send;
  @override QrTransportKind get kind => QrTransportKind.cloud;

  static final _hex40 = RegExp(r'^[a-f0-9]{40}$');
  static final _hex64 = RegExp(r'^[a-f0-9]{64}$');

  /// HTTPS only, no credentials/query in the URL.
  static bool validEndpoint(Uri u) => u.scheme == 'https' &&
      u.host.isNotEmpty && u.userInfo.isEmpty && !u.hasQuery &&
      !u.hasFragment;

  @override
  Future<QrPublishOutcome> publish(QrPublishRequest r) {
    final b = r.binding;
    if (b == null || !b.valid) {
      return Future.value(const QrPublishOutcome(QrPublishStatus.refused,
        reason: 'missing_command_binding'));
    }
    if (!_hex40.hasMatch(r.expectedRevision)) {
      return Future.value(const QrPublishOutcome(QrPublishStatus.refused,
        reason: 'invalid_expected_revision'));
    }
    final draftJson = r.draftJson;
    if (draftJson.length > 800000) {
      return Future.value(const QrPublishOutcome(QrPublishStatus.refused,
        reason: 'draft_too_large'));
    }
    return _call(b.commandId, {
      'operation': 'publish',
      'commandId': b.commandId,
      'leaseGeneration': b.leaseGeneration,
      'envelopeSha256': b.envelopeSha256,
      'expectedRevision': r.expectedRevision,
      'expectedStamp': r.expectedStamp,
      'draftJson': draftJson,
      // First activation is never implicit (contract): always false here.
      'activateConfirmed': false,
    });
  }

  @override
  Future<QrPublishOutcome> reconcile(String requestId,
      {QrCommandBinding? binding}) => _recovery('reconcile', requestId, binding);

  /// Only for a request the server never attempted.
  Future<QrPublishOutcome> cancelBeforeAttempt(String requestId,
      {required QrCommandBinding binding}) =>
      _recovery('cancel_before_attempt', requestId, binding);

  Future<QrPublishOutcome> _recovery(
      String op, String requestId, QrCommandBinding? b) {
    if (b == null || !b.valid ||
        !QrCommandBinding._uuid.hasMatch(requestId)) {
      return Future.value(const QrPublishOutcome(QrPublishStatus.refused,
        reason: 'missing_command_binding'));
    }
    return _call(requestId, {
      'operation': op,
      'commandId': b.commandId,
      'leaseGeneration': b.leaseGeneration,
      'envelopeSha256': b.envelopeSha256,
      'targetRequestId': requestId,
    });
  }

  Future<QrPublishOutcome> _call(String expectedId, Json body) async {
    if (!validEndpoint(endpoint)) {
      return const QrPublishOutcome(QrPublishStatus.refused,
        reason: 'invalid_endpoint');
    }
    final token = await agentToken();
    if (token == null || !_hex64.hasMatch(token)) {
      return const QrPublishOutcome(QrPublishStatus.refused,
        reason: 'agent_not_activated');
    }
    final ({int status, String body}) res;
    try {
      res = await send(endpoint, {
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
        'accept': 'application/json',
      }, jsonEncode(body));
    } on TimeoutException {
      return QrPublishOutcome(QrPublishStatus.unknown,
        requestId: expectedId, reason: 'timeout');
    } catch (_) {
      // The request may have reached the server before the connection broke.
      return QrPublishOutcome(QrPublishStatus.unknown,
        requestId: expectedId, reason: 'connection_lost');
    }
    return interpret(res.status, res.body, expectedId);
  }

  /// The server's `safe()` rules, applied again on the client.
  static QrPublishOutcome interpret(int code, String raw, String expectedId) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      decoded = null;
    }
    final m = decoded is Map ? decoded : const {};
    final status = m['status'];
    final idOk = m['requestId'] == expectedId;
    QrPublishOutcome unknown(String why) => QrPublishOutcome(
      QrPublishStatus.unknown, requestId: expectedId, reason: why);
    switch (code) {
      case 200:
        if (!idOk) return unknown('mismatched_request');
        if (status == 'committed' &&
            _hex40.hasMatch('${m['commit']}') &&
            _hex40.hasMatch('${m['revision']}')) {
          return QrPublishOutcome(QrPublishStatus.committed,
            requestId: expectedId, revision: '${m['revision']}',
            commit: '${m['commit']}');
        }
        if (status == 'no_change' && _hex40.hasMatch('${m['revision']}')) {
          return QrPublishOutcome(QrPublishStatus.noChange,
            requestId: expectedId, revision: '${m['revision']}');
        }
        if (status == 'cancelled_before_attempt') {
          return QrPublishOutcome(QrPublishStatus.cancelledBeforeAttempt,
            requestId: expectedId);
        }
        return unknown('malformed_success');
      case 404:
        return idOk && status == 'not_found'
            ? QrPublishOutcome(QrPublishStatus.notFound, requestId: expectedId)
            : unknown('malformed_not_found');
      case 409:
        if (!idOk) return unknown('malformed_conflict');
        return switch (status) {
          'busy' => QrPublishOutcome(QrPublishStatus.busy, requestId: expectedId),
          'conflict' => QrPublishOutcome(QrPublishStatus.conflict,
              requestId: expectedId),
          'reconciliation_required' => QrPublishOutcome(
              QrPublishStatus.reconciliationRequired, requestId: expectedId),
          _ => unknown('malformed_conflict'),
        };
      // Refused before any side effect (dispatcher validates first).
      case 400 || 401 || 403 || 405:
        return QrPublishOutcome(QrPublishStatus.refused,
          requestId: expectedId, reason: '${m['error'] ?? 'http_$code'}');
      case 503:
        // "publisher_disabled" is checked before anything else; any other
        // 503 may follow a started write.
        return m['error'] == 'publisher_disabled'
            ? QrPublishOutcome(QrPublishStatus.refused, requestId: expectedId,
                reason: 'publisher_disabled')
            : unknown('publisher_unavailable');
      default:
        return unknown('http_$code');
    }
  }
}

/// Settings → transport. Cloud only when explicitly chosen and configured;
/// an unknown publish stays bound to the transport that sent it.
class QrPublishRouter {
  QrPublishRouter({required this.local, this.cloud});
  final QrPublishTransport local;
  final QrPublishTransport? cloud;

  static QrTransportKind configured(Json settings) =>
      settings['qrPublishTransport'] == 'cloud'
          ? QrTransportKind.cloud : QrTransportKind.local;

  /// The transport for a new publish, or null with a reason.
  ({QrPublishTransport? transport, String? blocked}) forNew(
      Json settings, Json? pending) {
    if (pending != null) {
      return (transport: null,
        blocked: 'Önceki yayının sonucu bilinmiyor; önce doğrulanmalı.');
    }
    final kind = configured(settings);
    if (kind == QrTransportKind.cloud && cloud == null) {
      return (transport: null,
        blocked: 'Bulut yayınlama seçili ama yapılandırılmamış.');
    }
    return (transport: kind == QrTransportKind.cloud ? cloud : local,
      blocked: null);
  }

  /// The transport that must resolve [pending]: the one that sent it.
  QrPublishTransport? forPending(Json pending) {
    final kind = pending['transport'] == 'cloud'
        ? QrTransportKind.cloud : QrTransportKind.local;
    return kind == QrTransportKind.cloud ? cloud : local;
  }
}
