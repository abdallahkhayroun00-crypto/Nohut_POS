/// Trendyol Go (Uber Eats Trendyol Go) review + store discovery API client.
///
/// Only documented, read-only endpoints (developers.tgoapps.com, checked
/// 2026-11-27, spec §23.6.2):
/// * `GET /integrator/store/meal/suppliers/{supplierId}/stores` (size ≤ 50)
/// * `GET /integrator/review/meal/suppliers/{supplierId}/stores/{storeId}/reviews/filter`
///   with `page`, `size`, `startDate`, `endDate` (epoch ms on `createdDate`).
///
/// Migrated (Uber Eats) restaurants get 403 `endpoint.not-available.error`
/// and later a plain-text `404 page not found` (never parsed as JSON).
/// Transport is injectable so every behaviour is tested with synthetic data.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'pos_logic.dart';
import 'trendyol_go_readonly.dart';

typedef TgoHttpGet = Future<({int status, String body})> Function(Uri uri);

enum TgoApiOutcome {
  ok,
  /// 403 endpoint.not-available.error: store migrated to Uber Eats.
  notAvailable,
  /// Plain-text `404 page not found`: endpoint removed for this store.
  removed,
  /// Other 404: unknown store / path (e.g. a wrong store ID).
  notFound,
  unauthorized,
  rateLimited,
  network,
  error,
}

class TgoApiFailure {
  const TgoApiFailure(this.outcome, this.httpStatus, this.detail);
  final TgoApiOutcome outcome;
  final int httpStatus;
  /// Sanitized: never contains credentials or response bodies with data.
  final String detail;
  bool get migrated =>
      outcome == TgoApiOutcome.notAvailable || outcome == TgoApiOutcome.removed;
  bool get retryable =>
      outcome == TgoApiOutcome.rateLimited ||
      outcome == TgoApiOutcome.network ||
      (outcome == TgoApiOutcome.error && (httpStatus >= 500 || httpStatus <= 0));
  @override
  String toString() => '${outcome.name} (HTTP $httpStatus) $detail';
}

class TgoStore {
  const TgoStore({required this.id, required this.name, this.supplierId,
      this.workingStatus = ''});
  final String id, name, workingStatus;
  final String? supplierId;
}

class TgoStoresResult {
  const TgoStoresResult.ok(this.stores) : failure = null;
  const TgoStoresResult.failed(TgoApiFailure this.failure) : stores = const [];
  final List<TgoStore> stores;
  final TgoApiFailure? failure;
  bool get ok => failure == null;
}

class TgoReviewPage {
  const TgoReviewPage.ok(this.rows, {this.totalPages, this.totalElements})
      : failure = null;
  const TgoReviewPage.failed(TgoApiFailure this.failure)
      : rows = const [], totalPages = null, totalElements = null;
  final List<Json> rows;
  final int? totalPages, totalElements;
  final TgoApiFailure? failure;
  bool get ok => failure == null;
}

TgoApiFailure? classifyTgoResponse(int status, String body) {
  if (status >= 200 && status < 300) return null;
  if (status == 403 && body.contains('endpoint.not-available')) {
    return TgoApiFailure(TgoApiOutcome.notAvailable, status,
        'endpoint.not-available.error');
  }
  if (status == 404) {
    return body.trimLeft().startsWith('404 page not found')
        ? TgoApiFailure(TgoApiOutcome.removed, status, '404 page not found')
        : TgoApiFailure(TgoApiOutcome.notFound, status, 'not found');
  }
  if (status == 401 || status == 403) {
    return TgoApiFailure(TgoApiOutcome.unauthorized, status, 'unauthorized');
  }
  if (status == 429) {
    return TgoApiFailure(TgoApiOutcome.rateLimited, status, 'rate limited');
  }
  return TgoApiFailure(TgoApiOutcome.error, status, 'HTTP $status');
}

class TgoReviewApi {
  TgoReviewApi(this.supplierId, this._get, {this.host = 'api.tgoapis.com'});

  final String supplierId;
  final String host;
  final TgoHttpGet _get;
  static final _numeric = RegExp(r'^[0-9]{1,20}$');

  Future<({int status, String body})?> _call(Uri uri) async {
    try {
      return await _get(uri);
    } on TimeoutException {
      return null;
    } on SocketException {
      return null;
    } on HttpException {
      return null;
    } on HandshakeException {
      return null;
    }
  }

  /// All restaurants of the supplier (paginated, size 50, at most 10 pages).
  Future<TgoStoresResult> stores() async {
    if (!_numeric.hasMatch(supplierId)) {
      return const TgoStoresResult.failed(
          TgoApiFailure(TgoApiOutcome.unauthorized, 0, 'invalid supplier'));
    }
    final out = <TgoStore>[];
    for (var page = 0; page < 10; page++) {
      final res = await _call(Uri.https(host,
          '/integrator/store/meal/suppliers/$supplierId/stores',
          {'page': '$page', 'size': '50'}));
      if (res == null) {
        return const TgoStoresResult.failed(
            TgoApiFailure(TgoApiOutcome.network, -1, 'network'));
      }
      final failure = classifyTgoResponse(res.status, res.body);
      if (failure != null) return TgoStoresResult.failed(failure);
      final Object? payload;
      try {
        payload = jsonDecode(res.body);
      } on FormatException {
        return const TgoStoresResult.failed(
            TgoApiFailure(TgoApiOutcome.error, 200, 'unexpected body'));
      }
      final rows = payload is Map && payload['restaurants'] is List
          ? (payload['restaurants'] as List).whereType<Map>()
          : const <Map>[];
      for (final r in rows) {
        final id = '${r['id'] ?? ''}'.trim();
        if (!_numeric.hasMatch(id)) continue;
        out.add(TgoStore(
          id: id,
          name: '${r['name'] ?? ''}'.trim(),
          supplierId: r['supplierId'] == null ? null : '${r['supplierId']}',
          workingStatus: '${r['workingStatus'] ?? ''}',
        ));
      }
      final pages = payload is Map ? payload['totalPages'] : null;
      if (pages is! num || page + 1 >= pages) break;
    }
    return TgoStoresResult.ok(out);
  }

  Future<TgoReviewPage> reviews(
    String storeId, {
    required int page,
    int size = 50,
    int? startMs,
    int? endMs,
  }) async {
    if (!_numeric.hasMatch(supplierId) || !_numeric.hasMatch(storeId)) {
      return const TgoReviewPage.failed(
          TgoApiFailure(TgoApiOutcome.notFound, 0, 'invalid store'));
    }
    final res = await _call(Uri.https(host,
        '/integrator/review/meal/suppliers/$supplierId/stores/$storeId/reviews/filter',
        {
          'page': '$page',
          'size': '$size',
          if (startMs != null) 'startDate': '$startMs',
          if (endMs != null) 'endDate': '$endMs',
        }));
    if (res == null) {
      return const TgoReviewPage.failed(
          TgoApiFailure(TgoApiOutcome.network, -1, 'network'));
    }
    final failure = classifyTgoResponse(res.status, res.body);
    if (failure != null) return TgoReviewPage.failed(failure);
    final Object? payload;
    try {
      payload = jsonDecode(res.body);
    } on FormatException {
      return const TgoReviewPage.failed(
          TgoApiFailure(TgoApiOutcome.error, 200, 'unexpected body'));
    }
    final List items;
    if (payload is List) {
      items = payload;
    } else if (payload is Map && payload['content'] is List) {
      items = payload['content'] as List;
    } else if (payload is Map && payload['reviewId'] != null) {
      items = [payload];
    } else {
      return const TgoReviewPage.failed(
          TgoApiFailure(TgoApiOutcome.error, 200, 'unexpected body'));
    }
    int? asInt(Object? v) => v is num ? v.toInt() : null;
    return TgoReviewPage.ok(
      items.whereType<Map>().map(Json.from).toList(),
      totalPages: payload is Map ? asInt(payload['totalPages']) : null,
      totalElements: payload is Map ? asInt(payload['totalElements']) : null,
    );
  }
}

/// Production transport: same headers as the order poller, GET only,
/// no redirects, bounded time and size.
TgoHttpGet tgoHttpGet(TgoCredentials account) => (Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    request.headers
      ..set(HttpHeaders.authorizationHeader,
          'Basic ${base64Encode(utf8.encode('${account.apiKey}:${account.apiSecret}'))}')
      ..set(HttpHeaders.userAgentHeader, '${account.supplierId} - SelfIntegration')
      ..set('x-agentname', 'NohutFalafelPOS')
      ..set('x-executor-user', account.email)
      ..set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(const Duration(seconds: 20));
    final body = await utf8.decoder.bind(response).join()
        .timeout(const Duration(seconds: 20));
    return (status: response.statusCode, body: body);
  } finally {
    client.close(force: true);
  }
};
