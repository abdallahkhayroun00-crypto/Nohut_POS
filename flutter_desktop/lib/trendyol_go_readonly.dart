import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as paths;

import 'pos_logic.dart';
import 'order_reporting.dart';
import 'pos_store.dart';
import 'windows_vault.dart';

// Official MEAL order reader, with explicitly gated lifecycle operations.
// Production writes require a verified restaurant API contract and build opt-in.
class TgoCredentials {
  const TgoCredentials(
    this.supplierId,
    this.apiKey,
    this.apiSecret,
    this.email,
  );
  final String supplierId, apiKey, apiSecret, email;
  bool get valid =>
      RegExp(r'^[0-9]+$').hasMatch(supplierId) &&
      apiKey.isNotEmpty &&
      apiSecret.isNotEmpty &&
      email.contains('@');
}

class TgoWindowsVault {
  TgoWindowsVault(String databasePath, {File? credentialFile})
    : file =
          credentialFile ??
          File(
            paths.join(
              Platform.environment['APPDATA'] ?? paths.dirname(databasePath),
              'NohutFalafel',
              'trendyol-go-credentials.dpapi',
            ),
          );
  final File file;

  Future<TgoCredentials?> load() async {
    final fields = await WindowsVault(file).load();
    if (fields == null) return null;
    return TgoCredentials(
      fields['supplierId'] as String,
      fields['apiKey'] as String,
      fields['apiSecret'] as String,
      fields['email'] as String,
    );
  }

  Future<void> save(TgoCredentials value) async {
    if (!value.valid) {
      throw const FormatException(
        'Satıcı ID, API Key, API Secret ve e-posta gerekli.',
      );
    }
    await WindowsVault(file).save({
      'supplierId': value.supplierId,
      'apiKey': value.apiKey,
      'apiSecret': value.apiSecret,
      'email': value.email,
    });
  }
}

int tgoCents(Object? v) =>
    ((v is num ? v : num.tryParse('$v') ?? 0) * 100).round();
String tgoTime(Object? v) {
  final n = v is num ? v.toInt() : int.tryParse('$v') ?? 0;
  return n <= 0
      ? DateTime.now().toUtc().toIso8601String()
      : DateTime.fromMillisecondsSinceEpoch(n, isUtc: true).toIso8601String();
}

List<Json> tgoOrders(Json s) => asMaps(s['trendyolGoOrders']);

Iterable<Json> mutableTgoOrders(Json state) {
  final orders = state['trendyolGoOrders'];
  return orders is List ? orders.whereType<Json>() : const <Json>[];
}

/// Only fully delivered, non-test packages count as completed sales.
bool tgoCountsAsSale(Json o) =>
    o['testPackage'] != true && o['status'] == 'Delivered';
/// Ingredient lists may hold names or objects with a name.
List<String> tgoIngredientNames(Object? raw) => [
  for (final item in raw is List ? raw : const [])
    if ((item is Map ? '${item['name'] ?? ''}' : '$item').trim().isNotEmpty)
      (item is Map ? '${item['name']}' : '$item').trim(),
];

/// One modifier product with its nested choices, removals and extras.
String tgoModifierText(Map m) {
  final nested = [
    for (final n in asMaps(m['modifierProducts'])) tgoModifierText(n),
  ];
  final removed = tgoIngredientNames(m['removedIngredients']);
  final extras = tgoIngredientNames(m['extraIngredients']);
  return [
    '${m['name'] ?? ''}'.trim() +
        (nested.isEmpty ? '' : ' (${nested.join(', ')})'),
    if (removed.isNotEmpty) 'Çıkar: ${removed.join(', ')}',
    if (extras.isNotEmpty) 'Ekstra: ${extras.join(', ')}',
  ].join(' · ');
}

Json normalizeTgoPackage(Json p) {
  final id = '${p['id'] ?? ''}',
      number = '${p['orderNumber'] ?? p['orderId'] ?? ''}';
  if (id.isEmpty || number.isEmpty)
    throw const FormatException('Geçersiz platform paketi.');
  final lines = <Json>[],lineFacts=<Json>[];
  for (final l in asMaps(p['lines'])) {
    final items = asMaps(l['items']);
    final qty = items.isEmpty
        ? 1
        : items.where((e) => e['isCancelled'] != true).length;
    final commercial=<String,dynamic>{
      'name': '${l['name'] ?? ''}',
      'qty': qty,
      'unitPriceCents': tgoCents(l['unitSellingPrice'] ?? l['price']),
      // Chosen sub-products, each with its own removals/extras and nested
      // choices, e.g. "Patates (Büyük) · Çıkar: Ketçap".
      'options': [
        for (final m in asMaps(l['modifierProducts'])) tgoModifierText(m),
      ],
      'removed': tgoIngredientNames(l['removedIngredients']),
      'extras': tgoIngredientNames(l['extraIngredients']),
    };
    // Additive durable commercial facts. Existing active lines and all
    // printing/financial behavior below remain unchanged.
    lineFacts.add({...commercial,
      'originalQty':items.isEmpty?null:items.length,'quantityKnown':items.isNotEmpty,
      'unitPriceKnown':num.tryParse('${l['unitSellingPrice']??l['price']}')?.isFinite==true,
      'itemIds':[for(final item in items)if('${item['packageItemId']??''}'.trim().isNotEmpty)'${item['packageItemId']}'.trim()],
      'cancelledItemIds':[for(final item in items)if(item['isCancelled']==true&&'${item['packageItemId']??''}'.trim().isNotEmpty)'${item['packageItemId']}'.trim()],
    });
    if(qty>0)lines.add(commercial);
  }
  final payment = p['payment'] is Map
      ? p['payment'] as Map
      : <String, dynamic>{};
  final customer = p['customer'] is Map
      ? p['customer'] as Map
      : <String, dynamic>{};
  final address = p['address'] is Map
      ? p['address'] as Map
      : <String, dynamic>{};
  final sourceApp = p['userInformation'] is Map
      ? p['userInformation'] as Map
      : <String, dynamic>{};
  String clean(Object? field) => '${field ?? ''}'.trim();
  final customerName = [
    clean(customer['firstName']),
    clean(customer['lastName']),
  ].where((name) => name.isNotEmpty).join(' ');
  // Marketplace courier deliveries may deliberately mask the full address.
  final addressText = [
    clean(address['address1']),
    clean(address['address2']),
    clean(address['district']),
    clean(address['city']),
    clean(address['addressDescription']),
  ].where((part) =>
      part.isNotEmpty &&
      !part.toLowerCase().contains('trendyol go - yemek') &&
      !part.toLowerCase().contains('tgo yemek')).join(' · ');
  return {
    'source': 'Trendyol Go',
    'orderId': clean(p['orderId']),
    'packageItemIds': [
      for (final line in asMaps(p['lines']))
        for (final item in asMaps(line['items']))
          if (clean(item['packageItemId']).isNotEmpty)
            clean(item['packageItemId']),
    ],
    if (customerName.isNotEmpty) 'customerName': customerName,
    // Owner decision (V5.1 §19.4): customer e-mail is never collected; the
    // restaurant has no operational use for it. Already stored values are
    // left untouched pending the approved retention clean-up.
    if (clean(address['phone']).isNotEmpty)
      'customerPhone': clean(address['phone']),
    if (addressText.isNotEmpty) 'deliveryAddress': addressText,
    if (clean(sourceApp['appName']).isNotEmpty)
      'appName': clean(sourceApp['appName']),
    if (clean(p['deliveryType']).isNotEmpty)
      'deliveryType': clean(p['deliveryType']),
    if (clean(p['eta']).isNotEmpty) 'deliveryEta': clean(p['eta']),
    if (p['preparationTime'] is num)
      'preparationMinutes': (p['preparationTime'] as num).toInt(),
    if (p['pickupEtaState'] != null)
      'pickupEtaState': clean(p['pickupEtaState']),
    'supplierId': '${p['supplierId'] ?? ''}',
    'storeId': '${p['storeId'] ?? ''}',
    'packageId': id,
    'orderNumber': number,
    'orderCode': '${p['orderCode'] ?? ''}',
    'status': '${p['packageStatus'] ?? ''}',
    'createdAt': tgoTime(p['packageCreationDate']),
    'modifiedAt': tgoTime(
      p['packageModificationDate'] ?? p['lastModifiedDate'],
    ),
    'totalCents': tgoCents(p['totalPrice']),
    'paymentType': '${payment['paymentType'] ?? ''}',
    'customerNote': '${p['customerNote'] ?? ''}',
    'cancelReason':
        '${p['cancelInfo'] is Map ? (p['cancelInfo'] as Map)['reason'] ?? '' : ''}',
    if (p['isCourierNearby'] is bool)
      'courierNearby': p['isCourierNearby'],
    if (p['estimatedPickupTimeMin'] is num &&
        (p['estimatedPickupTimeMin'] as num) > 0)
      'courierEtaFrom': tgoTime(p['estimatedPickupTimeMin']),
    if (p['estimatedPickupTimeMax'] is num &&
        (p['estimatedPickupTimeMax'] as num) > 0)
      'courierEtaTo': tgoTime(p['estimatedPickupTimeMax']),
    'pickup': p['storePickupSelected'] == true,
    'testPackage': p['testPackage'] == true,
    'lines': lines,
    'lineFacts':lineFacts,
    'totalKnown':num.tryParse('${p['totalPrice']}')?.isFinite==true,
  };
}

String tgoOrderKey(Json order) {
  // Package ID is the immutable platform identity; the human-facing order
  // number may be reused across split packages.
  final packageId = '${order['packageId'] ?? ''}'.trim();
  return '${order['supplierId']}:${order['storeId']}:${packageId.isNotEmpty ? packageId : order['orderNumber']}';
}

/// Trendyol kitchen tickets print once, when the order is accepted
/// (Created → Picking, from the POS, a phone or the partner panel), under
/// the same printer and auto-print rules as Masa / Gel-Al tickets.
/// [settings] is kept for callers; older manual/arrival choices are retired.
String tgoKitchenTiming(Object? settings) => 'accepted';

bool tgoKitchenActive(Json order) =>
    order['testPackage'] != true &&
    const ['Created', 'Picking', 'Invoiced'].contains(order['status']);

/// Same layout as the Masa / Gel-Al kitchen ticket (see receiptText), plus
/// the platform name and the platform order number.
String tgoKitchenTicket(Json order) {
  final note = '${order['customerNote'] ?? ''}'.trim();
  final code = '${order['orderCode'] ?? ''}'.trim();
  final type = order['pickup'] == true ? 'Gel-Al' : 'Paket Servis';
  final lines = asMaps(order['lines']);
  List<String> named(Object? value) => [
    for (final v in value is List ? value : const []) '$v'.trim(),
  ].where((v) => v.isNotEmpty).toList();
  int unit(Map l) => l['unitPriceCents'] as int? ?? 0;
  final sum = lines.fold<int>(
    0, (n, l) => n + unit(l) * (l['qty'] as int? ?? 0));
  final total = order['totalCents'] is int && order['totalCents'] as int > 0
      ? order['totalCents'] as int
      : sum;
  final customer = '${order['customerName'] ?? ''}'.trim();
  return [
    'NOHUT FALAFEL · SİPARİŞ FİŞİ',
    'MALİ FİŞ DEĞİLDİR',
    '#${displayOrderNumber(order)} · Trendyol Go · $type',
    'Platform no: ${order['orderNumber']}${code.isEmpty ? '' : ' · Kod: $code'}',
    if (customer.isNotEmpty) 'Müşteri: $customer',
    receiptStamp(order['createdAt']),
    for (final line in lines) ...[
      unit(line) > 0
          ? '${line['qty']} × ${line['name']} · '
                '${formatTry(unit(line) * (line['qty'] as int? ?? 0))}'
          : '${line['qty']} × ${line['name']}',
      if (unit(line) > 0 && (line['qty'] as int? ?? 1) > 1)
        '  ${line['qty']} × ${formatTry(unit(line))}',
      for (final option in named(line['options'])) '  + $option',
      if (named(line['removed']).isNotEmpty)
        '  Çıkar: ${named(line['removed']).join(', ')}',
      if (named(line['extras']).isNotEmpty)
        '  Ekstra: ${named(line['extras']).join(', ')}',
    ],
    if (note.isNotEmpty) 'Not: $note',
    if (total > 0) 'Toplam ${formatTry(total)}',
    if ('${order['paymentType'] ?? ''}'.isNotEmpty)
      'Ödeme: ${switch ('${order['paymentType']}') {
        'PAY_WITH_CARD' => 'Kart',
        'PAY_WITH_CASH' => 'Nakit',
        final other => other.replaceAll('_', ' '),
      }}',
  ].join('\n');
}

/// Restaurant-caused cancellation reasons accepted by the MEAL API.
const tgoCancelReasons = <int, String>{
  621: 'Tedarik problemi',
  622: 'Mağaza kapalı',
  623: 'Sipariş hazırlanamadı',
  627: 'Sipariş karışıklığı',
};

/// Builds a documented Trendyol Go Yemek order write
/// (developers.tgoapps.com → Yemek Entegrasyonu → Sipariş Entegrasyonu):
///
/// * Kabul Et → `PUT …/suppliers/{supplierId}/packages/picked`
///   `{"packageId", "preparationTime"}`
/// * Hazır → `PUT …/suppliers/{supplierId}/packages/invoiced`
///   `{"packageId"}` (`actualDate` is optional and omitted)
/// * İptal → `PUT …/suppliers/{supplierId}/packages/unsupplied`
///   `{"packageId", "itemIdList", "reasonId"}`
///
/// The package ID belongs in the JSON body, never in the URL path.
({String path, Map<String, dynamic> body}) tgoWriteRequest({
  required String supplierId,
  required Json order,
  required String action,
  int? preparationMinutes,
  int? reasonId,
}) {
  if (!RegExp(r'^[0-9]{1,20}$').hasMatch(supplierId)) {
    throw const FormatException('Satıcı kimliği geçersiz.');
  }
  final packageId = '${order['packageId'] ?? ''}';
  if (!RegExp(r'^[A-Za-z0-9-]{1,80}$').hasMatch(packageId)) {
    throw const FormatException('Paket kimliği geçersiz.');
  }
  final base = '/integrator/order/meal/suppliers/$supplierId/packages';
  switch (action) {
    case 'accept':
      if (preparationMinutes == null ||
          preparationMinutes < 1 || preparationMinutes > 120) {
        throw const FormatException(
          'Hazırlama süresi 1-120 dakika arasında olmalı.',
        );
      }
      return (
        path: '$base/picked',
        body: {'packageId': packageId, 'preparationTime': preparationMinutes},
      );
    case 'ready':
      return (path: '$base/invoiced', body: {'packageId': packageId});
    case 'cancel':
      if (!tgoCancelReasons.containsKey(reasonId)) {
        throw const FormatException('Geçerli restoran iptal nedenini seçin.');
      }
      final ids = (order['packageItemIds'] as List? ?? [])
          .map((v) => '$v').where((v) => v.isNotEmpty).toList();
      if (ids.isEmpty) {
        throw const FormatException(
          'İptal için paket ürün kimlikleri bulunamadı.',
        );
      }
      return (
        path: '$base/unsupplied',
        body: {'packageId': packageId, 'itemIdList': ids, 'reasonId': reasonId},
      );
  }
  throw const FormatException('Desteklenmeyen işlem.');
}

class TrendyolGoReadonly extends ChangeNotifier {
  TrendyolGoReadonly(this.store, {this.onNewOrders, this.onOrdersSynced})
    : vault = TgoWindowsVault(store.filePath);

  final void Function(List<Json>)? onNewOrders;
  /// Only invoked after the remote API succeeded and SQLite committed.
  final void Function(List<Json>)? onOrdersSynced;
  static const liveSyncEnabled = bool.fromEnvironment(
    'NOHUT_TRENDYOL_LIVE_SYNC',
    defaultValue: true,
  );
  /// Kabul Et / Hazır / İptal requests follow the documented MEAL order
  /// endpoints. Build with --dart-define=NOHUT_TRENDYOL_WRITE_ACTIONS=false
  /// to ship a read-only POS.
  static const writeEnabled = bool.fromEnvironment(
    'NOHUT_TRENDYOL_WRITE_ACTIONS',
    defaultValue: true,
  );
  bool get canWrite => writeEnabled &&
      liveSyncEnabled && credentials?.valid == true &&
      status.startsWith('Bağlı ·');
  bool writing = false;
  static const pausedStatus = 'Senkronizasyon geçici olarak kapalı';
  final PosStore store;
  final TgoWindowsVault vault;
  TgoCredentials? credentials;
  Timer? _timer;
  bool syncing = false, _closed = false;
  String status = liveSyncEnabled ? 'Bağlı değil' : pausedStatus;
  String lastSync = '', error = '';
  Future<void> start() async {
    try {
      credentials = await vault.load();
      if (liveSyncEnabled) {
        status = credentials == null ? 'API bilgileri bekleniyor' : 'Hazır';
      }
    } catch (_) {
      status = 'Güvenli kasa okunamadı';
    }
    if (_closed) return;
    notifyListeners();
    if (!liveSyncEnabled) return;
    final meta = store.read().data['tgoSyncInfo'];
    if (meta is Map && meta['supplierId'] == credentials?.supplierId) {
      lastSync = '${meta['lastSync'] ?? ''}';
    }
    if (credentials?.valid == true) unawaited(sync());
    _timer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (credentials?.valid == true) unawaited(sync());
    });
  }

  Future<void> save(TgoCredentials c) async {
    await vault.save(c);
    credentials = c;
    status = liveSyncEnabled ? 'Bilgiler kaydedildi · bağlantı doğrulanıyor' : pausedStatus;
    error = '';
    if (_closed) return;
    notifyListeners();
    if (liveSyncEnabled) unawaited(sync());
  }

  Future<HttpClientRequest> _authorizedGet(
    HttpClient client,
    Uri uri,
    TgoCredentials account,
  ) async {
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    final auth = base64Encode(
      utf8.encode('${account.apiKey}:${account.apiSecret}'),
    );
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Basic $auth')
      ..set(
        HttpHeaders.userAgentHeader,
        '${account.supplierId} - SelfIntegration',
      )
      ..set('x-agentname', 'NohutFalafelPOS')
      ..set('x-executor-user', account.email)
      ..set(HttpHeaders.acceptHeader, 'application/json');
    return request;
  }

  /// Operator-initiated lifecycle action. Never performs an optimistic state
  /// change in SQLite; the next successful GET remains the source of truth.
  /// Enabled only after the MEAL write endpoints/permissions are validated.
  Future<bool> updateOrder(
    Json order,
    String action, {
    int? reasonId,
    String? explanation,
    int? preparationMinutes,
  }) async {
    if (!canWrite || writing) {
      throw const FormatException(
        'Yazma erişimi etkin değil. Restoran API yetkilerini doğrulayın.',
      );
    }
    final account = credentials!;
    if (order['source'] != 'Trendyol Go' ||
        order['testPackage'] == true ||
        '${order['supplierId']}' != account.supplierId) {
      throw const FormatException('Geçersiz platform siparişi.');
    }
    final packageId = '${order['packageId'] ?? ''}';
    if (!RegExp(r'^[A-Za-z0-9-]{1,80}$').hasMatch(packageId)) {
      throw const FormatException('Paket kimliği geçersiz.');
    }
    final current = '${order['status']}';
    final expected = switch (action) {
      'accept' => 'Created',
      'ready' => 'Picking',
      'cancel' => 'Created',
      _ => '',
    };
    if (action != 'cancel' && current != expected ||
        action == 'cancel' && !['Created', 'Picking'].contains(current)) {
      throw const FormatException('Sipariş durumu değişmiş. Yeniden kontrol edin.');
    }
    // Validates every field before any network call.
    final write = tgoWriteRequest(
      supplierId: account.supplierId,
      order: order,
      action: action,
      preparationMinutes: preparationMinutes,
      reasonId: reasonId,
    );
    writing = true;
    notifyListeners();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final basePath =
        '/integrator/order/meal/suppliers/${account.supplierId}/packages/$packageId';
      final latestUri = Uri.https('api.tgoapis.com', basePath);
      final preflight = await _authorizedGet(client, latestUri, account);
      final checked = await preflight.close().timeout(const Duration(seconds: 20));
      final checkedBody = await utf8.decoder.bind(checked).join()
          .timeout(const Duration(seconds: 20));
      if (checked.statusCode != 200) {
        throw FormatException('Sipariş doğrulanamadı (HTTP ${checked.statusCode}).');
      }
      final latest = jsonDecode(checkedBody);
      final latestStatus = latest is Map ? latest['packageStatus'] : null;
      if (latestStatus != current) {
        throw const FormatException('Sipariş durumu platformda değişmiş. Yenileyin.');
      }

      final uri = Uri.https('api.tgoapis.com', write.path);
      final request = await client.openUrl('PUT', uri);
      request.followRedirects = false;
      request.headers
        ..set(HttpHeaders.authorizationHeader,
          'Basic ${base64Encode(utf8.encode('${account.apiKey}:${account.apiSecret}'))}')
        ..set(HttpHeaders.userAgentHeader,
          '${account.supplierId} - SelfIntegration')
        ..set('x-agentname', 'NohutFalafelPOS')
        ..set('x-executor-user', account.email)
        ..set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(write.body));
      final result = await request.close().timeout(const Duration(seconds: 20));
      final responseBody = await utf8.decoder.bind(result).join()
          .timeout(const Duration(seconds: 20));
      if (result.statusCode < 200 || result.statusCode >= 300) {
        throw FormatException(
          'Platform işlemi onaylamadı (HTTP ${result.statusCode}). '
          '${responseBody.length > 160 ? responseBody.substring(0, 160) : responseBody}',
        );
      }
    } catch (_) {
      try { _recordAction(order, action, 'HATA'); } catch (_) {}
      rethrow;
    } finally {
      client.close(force: true);
      writing = false;
      if (!_closed) notifyListeners();
    }
    // A successful write HTTP response is not necessarily a confirmed status.
    await sync();
    final expectedStatuses = switch (action) {
      'accept' => const {'Picking', 'Invoiced', 'Shipped', 'Delivered'},
      'ready' => const {'Invoiced', 'Shipped', 'Delivered'},
      'cancel' => const {'UnSupplied', 'Cancelled'},
      _ => const <String>{},
    };
    final updated = tgoOrders(store.read().data).where(
      (o) => tgoOrderKey(o) == tgoOrderKey(order),
    );
    final verified = updated.isNotEmpty &&
        expectedStatuses.contains('${updated.first['status']}');
    _recordAction(order, action, verified ? 'DOĞRULANDI' : 'DOĞRULAMA BEKLENİYOR');
    return verified;
  }

  void _recordAction(Json order, String action, String result) {
    for (var attempt = 0; attempt < 3; attempt++) {
      final snapshot = store.read();
      final next = copyJson(snapshot.data);
      final raw = next['tgoOperationAudit'];
      final events = raw is List ? List<dynamic>.from(raw) : <dynamic>[];
      events.add({
        'platform': 'Trendyol Go',
        'packageId': order['packageId'],
        'orderNumber': order['orderNumber'],
        'action': action,
        'result': result,
        'at': DateTime.now().toUtc().toIso8601String(),
      });
      if (events.length > 200) events.removeRange(0, events.length - 200);
      next['tgoOperationAudit'] = events;
      if (store.replace(next, snapshot.revision).ok) return;
    }
  }

  /// Explicit operator-submitted answer using the published MEAL endpoint.
  /// Unlike order status mutations this endpoint is documented, but restaurants
  /// migrated to Uber Eats can receive HTTP 403 or 404.
  Future<void> answerReview({
    required String storeId,
    required String reviewId,
    required String text,
  }) async {
    final account = credentials;
    if (!liveSyncEnabled || account == null || !account.valid) {
      throw const FormatException('Önce Trendyol Go API bağlantısını kurun.');
    }
    if (storeId.isEmpty ||
        storeId.codeUnits.any((unit) => unit < 48 || unit > 57) ||
        reviewId.isEmpty ||
        reviewId.contains('/') ||
        reviewId.contains('..')) {
      throw const FormatException('Yorum veya şube kimliği geçersiz.');
    }
    final answer = text.trim();
    if (answer.isEmpty) {
      throw const FormatException('Yanıt metni boş olamaz.');
    }
    final uri = Uri.https(
      'api.tgoapis.com',
      '/integrator/review/meal/suppliers/' + account.supplierId +
        '/stores/' + storeId + '/reviews/' + reviewId + '/answer',
    );
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.postUrl(uri);
      request.followRedirects = false;
      request.headers
        ..set(HttpHeaders.authorizationHeader,
          'Basic ' + base64Encode(utf8.encode(
            account.apiKey + ':' + account.apiSecret)))
        ..set(HttpHeaders.userAgentHeader,
          account.supplierId + ' - SelfIntegration')
        ..set('x-agentname', 'NohutFalafelPOS')
        ..set('x-executor-user', account.email)
        ..set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'text': answer}));
      final response = await request.close().timeout(
        const Duration(seconds: 20));
      final body = await utf8.decoder.bind(response).join().timeout(
        const Duration(seconds: 20));
      if ((response.statusCode == 403 &&
              body.contains('endpoint.not-available.error')) ||
          response.statusCode == 404) {
        throw const FormatException(
          'Bu restoranın yorum yanıtlama servisi kullanılamıyor. '
          'Uber Eats geçişi nedeniyle reddedilebilir; Partner Paneli kullanın.',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw FormatException(
          'Trendyol yanıtı kabul etmedi (HTTP ' +
          response.statusCode.toString() + '). Partner Paneli’nden kontrol edin.',
        );
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<({List<Json> reviews, bool hasNextPage})> readReviews(
    String storeId,
    int page,
  ) async {
    final account = credentials;
    if (!liveSyncEnabled || account == null || !account.valid) {
      throw const FormatException('Önce Trendyol Go API bilgilerini kaydedin.');
    }
    if (!RegExp(r'^[0-9]+$').hasMatch(storeId)) {
      throw const FormatException('Geçerli bir şube ID girin.');
    }
    final uri = Uri(
      scheme: 'https',
      host: 'api.tgoapis.com',
      pathSegments: [
        'integrator',
        'review',
        'meal',
        'suppliers',
        account.supplierId,
        'stores',
        storeId,
        'reviews',
        'filter',
      ],
      queryParameters: {'page': '$page', 'size': '20'},
    );
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await _authorizedGet(client, uri, account);
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 404 ||
          response.statusCode == 403 &&
              body.contains('endpoint.not-available.error')) {
        throw const FormatException(
          'Bu şube için yorum servisi kullanılamıyor. Yorumları GO Yemek panelinden kontrol edin.',
        );
      }
      if (response.statusCode != 200) {
        throw FormatException(
          'Trendyol yorum servisi HTTP ${response.statusCode}.',
        );
      }
      final payload = jsonDecode(body);
      final List items;
      if (payload is List) {
        items = payload;
      } else if (payload is Map && payload['content'] is List) {
        items = payload['content'] as List;
      } else if (payload is Map && payload['reviewId'] != null) {
        items = [payload];
      } else {
        throw const FormatException(
          'Yorum servisi beklenmeyen bir yanıt verdi.',
        );
      }
      final pages = payload is Map ? payload['totalPages'] : null;
      return (
        reviews: items.whereType<Map>().map(Json.from).toList(),
        hasNextPage: pages is num ? page + 1 < pages : items.length == 20,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<void> sync() async {
    if (!liveSyncEnabled || _closed || syncing || credentials?.valid != true)
      return;
    syncing = true;
    status = 'Senkronize ediliyor';
    error = '';
    notifyListeners();
    try {
      final c = credentials!, meta = store.read().data['tgoSyncInfo'];
      final last = meta is Map
          ? DateTime.tryParse('${meta['lastSync'] ?? ''}')
          : null;
      final end = DateTime.now().toUtc();
      // Resume from the last successful checkpoint (with overlap). Never
      // drop changes during a long internet/power outage.
      final start = last == null
          ? end.subtract(const Duration(days: 7))
          : last.subtract(const Duration(hours: 24));
      final fresh = <Json>[];
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 12);
      try {
        for (var page = 0; page < 10; page++) {
          final uri = Uri.https(
            'api.tgoapis.com',
            '/integrator/order/meal/suppliers/' + c.supplierId + '/packages',
            {
              'page': '$page',
              'size': '50',
              'packageModificationStartDate': '${start.millisecondsSinceEpoch}',
              'packageModificationEndDate': '${end.millisecondsSinceEpoch}',
            },
          );
          final req = await _authorizedGet(client, uri, c);
          final res = await req.close().timeout(const Duration(seconds: 20));
          if (res.statusCode != 200) {
            throw FormatException('Trendyol API HTTP ${res.statusCode}');
          }
          final payload = await utf8.decoder
              .bind(res)
              .join()
              .timeout(const Duration(seconds: 20));
          final result = jsonDecode(payload);
          if (result is! Map || result['content'] is! List) {
            throw const FormatException('Sipariş yanıtı geçersiz.');
          }
          final packages = result['content'] as List;
          for (final raw in packages) {
            if (raw is Map) fresh.add(normalizeTgoPackage(Json.from(raw)));
          }
          final pages = (result['totalPages'] as num?)?.toInt();
          if (pages != null ? page + 1 >= pages : packages.length < 50) break;
          if (page == 9)
            throw const FormatException('API sayfa sınırı; veri kısmi.');
        }
      } finally {
        client.close(force: true);
      }
      if (_closed) return;
      var saved = false;
      var newOrders = <Json>[];
      for (var i = 0; i < 4 && !saved; i++) {
        final snapshot = store.read(), next = copyJson(snapshot.data);
        final merged = {for (final o in tgoOrders(next)) tgoOrderKey(o): o};
        final previouslyKnown = merged.keys.toSet();
        final sameAccount = meta is Map && meta['supplierId'] == c.supplierId;
        final kitchenTiming = tgoKitchenTiming(next['settings']);
        for (final o in fresh) {
          final key = tgoOrderKey(o);
          final prior = merged[key];
          final changedAt = o['modifiedAt'];
          // Record when the POS first *observed* courier stages. This is not
          // an authoritative platform event timestamp.
          final courierTimeline = asMaps(prior?['courierTimeline']);
          if (o['pickup'] != true) {
            void observed(String stage, bool reached) {
              if (reached && !courierTimeline.any((e) => e['stage'] == stage)) {
                courierTimeline.add({
                  'stage': stage,
                  'observedAt': end.toUtc().toIso8601String(),
                });
              }
            }
            observed('nearby', o['courierNearby'] == true);
            observed('picked_up', ['Shipped', 'Delivered'].contains(o['status']));
            observed('delivered', o['status'] == 'Delivered');
          }
          // Do not allocate a different display number when platform status changes.
          merged[key] = {
            ...o,
            'courierTimeline': courierTimeline,
            if (prior?['dailyNumber'] is int)
              'dailyNumber': prior!['dailyNumber'],
            if (prior?['numberDay'] is String) 'numberDay': prior!['numberDay'],
            if (prior?['serviceStartedAt'] != null)
              'serviceStartedAt': prior!['serviceStartedAt']
            else if (prior?['status'] == 'Created' && o['status'] == 'Picking')
              'serviceStartedAt': changedAt,
            if (prior?['readyAt'] != null)
              'readyAt': prior!['readyAt']
            else if (prior?['status'] == 'Picking' &&
                o['status'] == 'Invoiced' &&
                prior?['serviceStartedAt'] != null)
              'readyAt': changedAt,
            if (prior?['kitchenPrintState'] is String)
              'kitchenPrintState': prior!['kitchenPrintState']
            else if (last != null &&
                sameAccount &&
                kitchenTiming == 'accepted' &&
                prior?['status'] == 'Created' &&
                o['status'] == 'Picking' &&
                tgoKitchenActive(o) &&
                onIstanbulDay(o['createdAt'], istanbulDay(end))) ...{
              'kitchenPrintState': 'Bekliyor',
              'kitchenQueuedAt': end.toUtc().toIso8601String(),
            },
            if (prior?['kitchenQueuedAt'] is String)
              'kitchenQueuedAt': prior!['kitchenQueuedAt'],
          };
        }
        newOrders = [
          if (last != null && sameAccount)
            for (final entry in merged.entries)
              if (!previouslyKnown.contains(entry.key) &&
                  tgoKitchenActive(entry.value) &&
                  onIstanbulDay(entry.value['createdAt'], istanbulDay(end)))
                entry.value,
        ];
        next['trendyolGoOrders'] = merged.values.toList();
        assignDailyNumbers(next);
        next['tgoSyncInfo'] = {
          'supplierId': c.supplierId,
          'lastSync': end.toIso8601String(),
        };
        saved = store.replace(next, snapshot.revision).ok;
      }
      if (!saved)
        throw const FormatException('Veritabanı güncellemesi çakıştı.');
      lastSync = DateTime.now().toLocal().toIso8601String();
      status = 'Bağlı · Salt okunur';
      if (newOrders.isNotEmpty) onNewOrders?.call(newOrders);
      onOrdersSynced?.call(tgoOrders(store.read().data));
    } on FormatException catch (e) {
      error = e.message;
      status = 'Bağlantı hatası';
    } catch (_) {
      error = 'Ağ veya yetki hatası. Ayarları kontrol edin.';
      status = 'Bağlantı hatası';
    } finally {
      syncing = false;
      if (!_closed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    super.dispose();
  }
}
