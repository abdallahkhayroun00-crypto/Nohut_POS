import 'dart:convert';
import 'dart:io';

import 'pos_logic.dart';
import 'trendyol_go_readonly.dart';

typedef TgoTransport = Future<TgoResponse> Function(
  String method, Uri uri, Json? body,
);

class TgoResponse {
  const TgoResponse(this.status, this.body);
  final int status;
  final Json body;
}

class TgoAdminResult {
  const TgoAdminResult({
    required this.message,
    this.confirmed = false,
    this.pendingBatchId,
  });
  final String message;
  final bool confirmed;
  final String? pendingBatchId;
}

/// A narrow, allowlisted implementation of published Trendyol Go MEAL
/// management endpoints. No OAuth tokens or keys are persisted here.
/// Production calls occur only after an explicit operator confirmation.
class TgoMealAdmin {
  TgoMealAdmin(
    this.credentials, {
    this.stage = false,
    TgoTransport? transport,
  }) : _transport = transport;

  final TgoCredentials credentials;
  final bool stage;
  final TgoTransport? _transport;

  Uri _url(String path) {
    final baseHost = stage ? 'stageapi.tgoapis.com' : 'api.tgoapis.com';
    return Uri.https(baseHost, '/integrator/' + path);
  }

  static void _positive(int id, String name) {
    if (id <= 0 || id > 2147483647) {
      throw FormatException('Geçersiz ' + name);
    }
  }

  Future<TgoResponse> _call(String method, String path, [Json? body]) async {
    if (!credentials.valid) {
      throw const FormatException('Trendyol Go API bilgilerini kontrol edin.');
    }
    final uri = _url(path);
    if (_transport != null) return _check(await _transport(method, uri, body));
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await (method == 'GET'
          ? client.getUrl(uri)
          : method == 'POST'
          ? client.postUrl(uri)
          : client.putUrl(uri)).timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Basic ' +
            base64Encode(utf8.encode(
              credentials.apiKey + ':' + credentials.apiSecret)))
        ..set(HttpHeaders.userAgentHeader,
          credentials.supplierId + ' - SelfIntegration')
        ..set('x-agentname', 'NohutFalafelPOS')
        ..set('x-executor-user', credentials.email)
        ..set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
          const Duration(seconds: 25));
      final raw = await utf8.decoder.bind(response).join().timeout(
          const Duration(seconds: 25));
      Json decoded = <String, dynamic>{};
      if (raw.isNotEmpty) {
        try {
          final obj = jsonDecode(raw);
          if (obj is Map) decoded = Json.from(obj);
        } on FormatException {
          // Do not surface arbitrary HTML or sensitive upstream response.
        }
      }
      return _check(TgoResponse(response.statusCode, decoded));
    } on SocketException {
      throw const FormatException('Platform bağlantısı kurulamadı.');
    } on HttpException {
      throw const FormatException('Platform bağlantısı kesildi.');
    } finally {
      client.close(force: true);
    }
  }

  TgoResponse _check(TgoResponse response) {
    if (response.status >= 200 && response.status < 300) return response;
    final code = response.status;
    if (code == 401 || code == 403) {
      throw const FormatException('Trendyol Go yetkisi veya API anahtarı uygun değil.');
    }
    if (code == 404) {
      throw const FormatException('Trendyol Go servisi bu şubede mevcut değil (404).');
    }
    if (code == 409) {
      throw const FormatException('Platformda eşzamanlı değişiklik var. Yenileyin.');
    }
    if (code == 429) {
      throw const FormatException('Trendyol hız sınırına ulaşıldı.');
    }
    throw FormatException('Trendyol Go API işlemi kabul etmedi (HTTP ' +
        code.toString() + ').');
  }

  String get supplier => credentials.supplierId;

  /// Required restaurantId prevents accidental changes to every branch.
  Future<TgoAdminResult> updatePrice({
    required int restaurantId,
    required int productId,
    required int sellingPriceCents,
  }) async {
    _positive(restaurantId, 'restaurantId');
    _positive(productId, 'productId');
    if (sellingPriceCents <= 0 || sellingPriceCents > 100000000) {
      throw const FormatException('Geçerli ürün fiyatı gerekli.');
    }
    final response = await _call(
      'POST', 'product/meal/suppliers/' + supplier + '/products/price',
      {'items': [
        {
          'restaurantId': restaurantId,
          'productId': productId,
          'sellingPrice': sellingPriceCents / 100.0,
        }
      ]},
    );
    final batch = (response.body['batchRequestId'] ?? '').toString();
    if (batch.isEmpty) {
      throw const FormatException('Batch ID alınamadı. İşlemi tekrar göndermeyin; Partner Paneli kontrol edin.');
    }
    // Queue acceptance is NOT confirmation. Poll the batch using GET.
    return TgoAdminResult(
      message: 'Fiyat talebi alındı. Batch sonucu doğrulanmalı.',
      pendingBatchId: batch,
    );
  }

  /// Checking an async batch is safe. Never resend an identical price update.
  Future<TgoAdminResult> checkPriceBatch(String batchId) async {
    if (!RegExp(r'^[A-Za-z0-9-]{8,160}$').hasMatch(batchId)) {
      throw const FormatException('Batch ID geçersiz.');
    }
    final response = await _call(
      'GET', 'product/meal/suppliers/' + supplier +
             '/batch-requests/' + batchId,
    );
    final status = (response.body['status'] ?? '').toString().toUpperCase();
    if (status == 'COMPLETED') {
      final failed = response.body['failedItemCount'];
      final items = asMaps(response.body['items']);
      final good = failed is num && failed == 0 &&
          items.isNotEmpty && items.every((item) =>
              (item['status'] ?? '').toString().toUpperCase() == 'SUCCESS');
      if (!good) {
        throw const FormatException(
          'Fiyat gönderildi ancak toplu işlemde başarısız ürün var. Partner Paneli kontrol edin.');
      }
      return const TgoAdminResult(
        message: 'Fiyat güncellemesi Trendyol batch sonucunda başarılı.',
        confirmed: true,
      );
    }
    if (status == 'FAILED' || status == 'REJECTED') {
      throw const FormatException('Trendyol fiyat güncellemesini reddetti.');
    }
    return TgoAdminResult(
      message: 'Fiyat değişikliği işleniyor; batch sonucunu tekrar kontrol edin.',
      pendingBatchId: batchId,
    );
  }

  Future<TgoAdminResult> updateProductStatus({
    required int storeId,
    required int productId,
    required bool active,
  }) async {
    _positive(storeId, 'storeId');
    _positive(productId, 'productId');
    await _call(
      'PUT', 'product/meal/suppliers/' + supplier + '/stores/' +
      storeId.toString() + '/products/' + productId.toString() + '/status',
      {'status': active ? 'ACTIVE' : 'PASSIVE'},
    );
    return const TgoAdminResult(
      message: 'Platform ürün durumunu kabul etti. Partner menüsünden doğrulayın.',
    );
  }

  Future<TgoAdminResult> updateSectionStatus({
    required int storeId,
    required int sectionId,
    required bool active,
  }) async {
    _positive(storeId, 'storeId');
    _positive(sectionId, 'sectionId');
    await _call(
      'PUT', 'product/meal/suppliers/' + supplier + '/stores/' +
      storeId.toString() + '/sections/' + sectionId.toString() + '/status',
      {'status': active ? 'ACTIVE' : 'PASSIVE'},
    );
    return const TgoAdminResult(
      message: 'Platform kategori durumunu kabul etti. Menüyü doğrulayın.',
    );
  }

  Future<TgoAdminResult> updateWorkingHours({
    required int storeId,
    required List<Json> hours,
  }) async {
    _positive(storeId, 'storeId');
    const weekdays = {
      'MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY',
      'FRIDAY', 'SATURDAY', 'SUNDAY',
    };
    final format = RegExp(r'^([01]\d|2[0-3]):[0-5]\d:[0-5]\d$');
    if (hours.isEmpty || hours.length > 30 || hours.any((h) =>
        !weekdays.contains(h['dayOfWeek']) ||
        !format.hasMatch((h['openingTime'] ?? '').toString()) ||
        !format.hasMatch((h['closingTime'] ?? '').toString()) ||
        h['openingTime'] == h['closingTime'])) {
      throw const FormatException('Çalışma saatleri geçersiz.');
    }
    await _call(
      'PUT', 'store/meal/suppliers/' + supplier + '/stores/' +
      storeId.toString() + '/working-hours',
      {'workingHours': hours},
    );
    return const TgoAdminResult(
      message: 'Çalışma saatleri API tarafından kabul edildi. Partner panelini kontrol edin.',
    );
  }
}
