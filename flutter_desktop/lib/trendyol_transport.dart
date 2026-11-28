/// Windows side of the Trendyol Cloud Proxy v1 (#50
/// `docs/contracts/v1/trendyol-cloud-proxy.md`). DISABLED: nothing in the
/// app sends to the proxy until a verified, owner-approved cutover.
///
/// * One active polling path: [TrendyolSourceMode] decides local DPAPI or
///   cloud, never both, and cloud is honoured only when the build enables it.
/// * Windows only, with its existing agent token in `x-nohut-agent-token`;
///   phones never call the proxy.
/// * Requests are the exact v1 envelopes; responses are validated strictly.
///   A timeout, lost connection, 5xx other than `proxy_disabled`, or any
///   malformed answer to `execute` is **unknown** and is never retried or
///   sent through another path automatically.
/// * `verify` returns a status only: no packages, counts or customer data.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'pos_logic.dart';
import 'qr_publish_transport.dart' show QrCommandBinding;

enum TrendyolSource { local, cloud }

/// The single polling authority for this restaurant.
class TrendyolSourceMode {
  const TrendyolSourceMode(this.source, this.epoch);
  final TrendyolSource source;
  final int epoch;

  /// Off until the proxy is verified (owner decision 2026-11-28).
  static const cloudBuildEnabled = bool.fromEnvironment(
    'NOHUT_TRENDYOL_CLOUD_PROXY', defaultValue: false);

  /// Reads `settings.trendyolSource` = `{mode, epoch}`. Anything unknown,
  /// malformed, or cloud in a build without the proxy falls back to local,
  /// which is today's behaviour.
  static TrendyolSourceMode of(Map? settings, {bool cloudEnabled = cloudBuildEnabled}) {
    final v = settings?['trendyolSource'];
    if (v is Map && v['mode'] == 'cloud' && cloudEnabled &&
        v['epoch'] is int && (v['epoch'] as int) >= 1) {
      return TrendyolSourceMode(TrendyolSource.cloud, v['epoch'] as int);
    }
    final epoch = v is Map && v['epoch'] is int ? v['epoch'] as int : 0;
    return TrendyolSourceMode(TrendyolSource.local, epoch);
  }

  bool get localPolls => source == TrendyolSource.local;
  bool get cloudPolls => source == TrendyolSource.cloud;
}

enum TrendyolProxyStatus {
  ok,
  authFailed,
  supplierMismatch,
  proxyDisabled,
  unreachable,
  conflict,
  busy,
  reconciliationRequired,
  confirmed,
  noChange,
  cancelledBeforeAttempt,
  refused,
  unknown,
}

class TrendyolProxyResult {
  const TrendyolProxyResult(this.status, {this.reason = '', this.page});
  final TrendyolProxyStatus status;
  final String reason;
  /// Poll only.
  final TrendyolPollPage? page;

  /// True only for the statuses where a write may have happened and the
  /// outcome is not known: these must go to reconcile, never retry.
  bool get mayHaveWritten => status == TrendyolProxyStatus.unknown ||
      status == TrendyolProxyStatus.reconciliationRequired;
}

class TrendyolPollPage {
  const TrendyolPollPage(this.page, this.hasNextPage, this.packages);
  final int page;
  final bool hasNextPage;
  final List<Json> packages;
}

typedef TrendyolHttpSend = Future<({int status, String body})> Function(
    Uri url, Map<String, String> headers, String body);

const _maxResponseBytes = 2 * 1024 * 1024;

Future<({int status, String body})> _send(
    Uri url, Map<String, String> headers, String body) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.postUrl(url).timeout(const Duration(seconds: 15));
    req.followRedirects = false;
    headers.forEach(req.headers.set);
    req.write(body);
    final res = await req.close().timeout(const Duration(seconds: 45));
    final bytes = <int>[];
    await for (final chunk in res.timeout(const Duration(seconds: 45))) {
      bytes.addAll(chunk);
      if (bytes.length > _maxResponseBytes) {
        throw const HttpException('response too large');
      }
    }
    return (status: res.statusCode, body: utf8.decode(bytes));
  } finally {
    client.close(force: true);
  }
}

class CloudTrendyolProxy {
  CloudTrendyolProxy({
    required this.endpoint,
    required this.agentToken,
    TrendyolHttpSend? send,
  }) : send = send ?? _send;

  final Uri endpoint;
  final Future<String?> Function() agentToken;
  final TrendyolHttpSend send;

  static final _hex64 = RegExp(r'^[a-f0-9]{64}$');
  /// Exactly the top-level package fields `normalizeTgoPackage` reads (the
  /// proposed fixture for #50). Customer e-mail is not among them (V5.1
  /// §19.4); a page carrying any other field is refused.
  static const packageKeys = {
    'id', 'orderId', 'orderNumber', 'orderCode', 'supplierId', 'storeId',
    'packageStatus', 'packageCreationDate', 'packageModificationDate',
    'lastModifiedDate', 'totalPrice', 'lines', 'customerNote', 'customer',
    'address', 'payment', 'userInformation', 'deliveryType', 'eta',
    'preparationTime', 'cancelInfo', 'estimatedPickupTimeMin',
    'estimatedPickupTimeMax', 'isCourierNearby', 'pickupEtaState',
    'storePickupSelected', 'testPackage',
  };

  /// Fixed HTTPS path; no query, fragment or credentials in the URL.
  static bool validEndpoint(Uri u) => u.scheme == 'https' && u.host.isNotEmpty &&
      u.userInfo.isEmpty && !u.hasQuery && !u.hasFragment &&
      u.path == '/functions/v1/trendyol-proxy';

  Future<TrendyolProxyResult> verify(QrCommandBinding b) =>
      _bound('verify', b, _interpretVerify);
  Future<TrendyolProxyResult> execute(QrCommandBinding b) =>
      _bound('execute', b, _interpretExecute);
  Future<TrendyolProxyResult> reconcile(QrCommandBinding b) =>
      _bound('reconcile', b, _interpretExecute);

  Future<TrendyolProxyResult> poll({
    required DateTime start, required DateTime end, required int page,
  }) async {
    if (page < 0 || page > 9 || !end.isAfter(start) ||
        end.difference(start) > const Duration(days: 7)) {
      return const TrendyolProxyResult(TrendyolProxyStatus.refused,
        reason: 'invalid_window');
    }
    return _call({
      'version': 1, 'action': 'poll',
      'startMs': start.millisecondsSinceEpoch,
      'endMs': end.millisecondsSinceEpoch,
      'page': page, 'size': 50,
    }, (code, m) => interpretPoll(code, m, page));
  }

  Future<TrendyolProxyResult> _bound(String action, QrCommandBinding b,
      TrendyolProxyResult Function(int, Map) read) {
    if (!b.valid) {
      return Future.value(const TrendyolProxyResult(
        TrendyolProxyStatus.refused, reason: 'missing_command_binding'));
    }
    return _call({
      'version': 1, 'action': action,
      'commandId': b.commandId,
      'leaseGeneration': b.leaseGeneration,
      'envelopeSha256': b.envelopeSha256,
    }, read, mutating: action == 'execute');
  }

  Future<TrendyolProxyResult> _call(Json body,
      TrendyolProxyResult Function(int, Map) read, {bool mutating = false}) async {
    if (!validEndpoint(endpoint)) {
      return const TrendyolProxyResult(TrendyolProxyStatus.refused,
        reason: 'invalid_endpoint');
    }
    final token = await agentToken();
    if (token == null || !_hex64.hasMatch(token)) {
      return const TrendyolProxyResult(TrendyolProxyStatus.refused,
        reason: 'agent_not_activated');
    }
    final TrendyolProxyStatus lost =
        mutating ? TrendyolProxyStatus.unknown : TrendyolProxyStatus.unreachable;
    final ({int status, String body}) res;
    try {
      res = await send(endpoint, {
        'x-nohut-agent-token': token,
        'content-type': 'application/json',
        'accept': 'application/json',
      }, jsonEncode(body));
    } on TimeoutException {
      return TrendyolProxyResult(lost, reason: 'timeout');
    } catch (_) {
      return TrendyolProxyResult(lost, reason: 'connection_lost');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(res.body);
    } catch (_) {
      decoded = null;
    }
    final m = decoded is Map && decoded['version'] == 1 ? decoded : const {};
    if (m.isEmpty && res.status == 200) {
      return TrendyolProxyResult(mutating ? TrendyolProxyStatus.unknown
          : TrendyolProxyStatus.unreachable, reason: 'malformed');
    }
    return read(res.status, m);
  }

  /// Shared non-200 mapping. `mutating` decides what an unexplained server
  /// failure means.
  static TrendyolProxyResult _common(int code, Map m, {required bool mutating}) {
    final s = '${m['status'] ?? ''}';
    if (code == 503 && s == 'proxy_disabled') {
      return const TrendyolProxyResult(TrendyolProxyStatus.proxyDisabled);
    }
    if (code == 409) {
      return TrendyolProxyResult(switch (s) {
        'busy' => TrendyolProxyStatus.busy,
        'reconciliation_required' => TrendyolProxyStatus.reconciliationRequired,
        _ => TrendyolProxyStatus.conflict,
      }, reason: s);
    }
    if (code == 401 || code == 403) {
      return const TrendyolProxyResult(TrendyolProxyStatus.authFailed);
    }
    if (code == 400 || code == 405 || code == 404) {
      return TrendyolProxyResult(TrendyolProxyStatus.refused, reason: s);
    }
    return TrendyolProxyResult(
      mutating ? TrendyolProxyStatus.unknown : TrendyolProxyStatus.unreachable,
      reason: 'http_$code');
  }

  static TrendyolProxyResult _interpretVerify(int code, Map m) {
    if (code == 200) {
      // Status only: any extra field means the server leaked data.
      if (m.keys.toSet().difference({'version', 'status'}).isNotEmpty) {
        return const TrendyolProxyResult(TrendyolProxyStatus.unknown,
          reason: 'unexpected_fields');
      }
      return switch (m['status']) {
        'ok' => const TrendyolProxyResult(TrendyolProxyStatus.ok),
        'supplier_mismatch' =>
          const TrendyolProxyResult(TrendyolProxyStatus.supplierMismatch),
        _ => const TrendyolProxyResult(TrendyolProxyStatus.unknown),
      };
    }
    if (code == 401 || code == 403) {
      return const TrendyolProxyResult(TrendyolProxyStatus.authFailed);
    }
    if (code == 503 && m['status'] != 'proxy_disabled') {
      return const TrendyolProxyResult(TrendyolProxyStatus.unreachable);
    }
    return _common(code, m, mutating: false);
  }

  static TrendyolProxyResult _interpretExecute(int code, Map m) {
    if (code == 200) {
      return switch (m['status']) {
        'confirmed' => const TrendyolProxyResult(TrendyolProxyStatus.confirmed),
        'no_change' => const TrendyolProxyResult(TrendyolProxyStatus.noChange),
        'cancelled_before_attempt' =>
          const TrendyolProxyResult(TrendyolProxyStatus.cancelledBeforeAttempt),
        _ => const TrendyolProxyResult(TrendyolProxyStatus.unknown,
          reason: 'unexpected_status'),
      };
    }
    return _common(code, m, mutating: true);
  }

  static TrendyolProxyResult interpretPoll(int code, Map m, int askedPage) {
    if (code != 200) return _common(code, m, mutating: false);
    final packages = m['packages'];
    if (m['status'] != 'ok' || m['page'] != askedPage ||
        m['hasNextPage'] is! bool || packages is! List || packages.length > 50 ||
        !packages.every((p) => p is Map &&
            p.keys.every(packageKeys.contains) && p['id'] != null)) {
      return const TrendyolProxyResult(TrendyolProxyStatus.unreachable,
        reason: 'malformed_page');
    }
    return TrendyolProxyResult(TrendyolProxyStatus.ok, page: TrendyolPollPage(
      askedPage, m['hasNextPage'] as bool,
      [for (final p in packages) Json.from(p as Map)]));
  }
}

/// Owner-facing text for a verification result (no data, no secrets).
String trendyolVerifyText(TrendyolProxyStatus s) => switch (s) {
  TrendyolProxyStatus.ok => 'Bağlantı doğrulandı.',
  TrendyolProxyStatus.authFailed => 'Yetki reddedildi. Bulut bilgileri veya cihaz izni kontrol edilmeli.',
  TrendyolProxyStatus.supplierMismatch => 'Satıcı kimliği bu restoranla eşleşmiyor.',
  TrendyolProxyStatus.proxyDisabled => 'Bulut bağlantısı kapalı.',
  TrendyolProxyStatus.unreachable => 'Bulut bağlantısına ulaşılamadı.',
  TrendyolProxyStatus.busy => 'Bulut meşgul; biraz sonra tekrar deneyin.',
  _ => 'Sonuç bilinmiyor; bağlantı doğrulanmış sayılmadı.',
};
