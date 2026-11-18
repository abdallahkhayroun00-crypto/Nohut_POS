import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as paths;

import 'pos_logic.dart';
import 'order_reporting.dart';
import 'pos_store.dart';

// Official MEAL GET API ONLY. Never mutates Trendyol Go orders/menu/status.
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

final class _DataBlob extends Struct {
  @Uint32()
  external int length;
  external Pointer<Uint8> bytes;
}

typedef _DpapiNative = Int32 Function(
  Pointer<_DataBlob>, Pointer<Void>, Pointer<_DataBlob>, Pointer<Void>,
  Pointer<Void>, Uint32, Pointer<_DataBlob>,
);
typedef _DpapiDart = int Function(
  Pointer<_DataBlob>, Pointer<Void>, Pointer<_DataBlob>, Pointer<Void>,
  Pointer<Void>, int, Pointer<_DataBlob>,
);

Uint8List _protectForCurrentUser(List<int> data, {required bool decrypt}) {
  if (!Platform.isWindows) {
    throw const FormatException('Windows güvenli kasa gerekli.');
  }
  final crypt32 = DynamicLibrary.open('crypt32.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final transform = crypt32.lookupFunction<_DpapiNative, _DpapiDart>(
    decrypt ? 'CryptUnprotectData' : 'CryptProtectData',
  );
  final localFree = kernel32.lookupFunction<Pointer<Void> Function(Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>)>('LocalFree');
  final input = calloc<_DataBlob>();
  final output = calloc<_DataBlob>();
  final source = calloc<Uint8>(data.length);
  try {
    source.asTypedList(data.length).setAll(0, data);
    input.ref
      ..length = data.length
      ..bytes = source;
    // Current user scope, with system prompts disabled.
    if (transform(input, nullptr, nullptr, nullptr, nullptr, 1, output) == 0) {
      throw const FormatException('Windows güvenli kasa işlemi başarısız.');
    }
    return Uint8List.fromList(output.ref.bytes.asTypedList(output.ref.length));
  } finally {
    if (output.ref.bytes != nullptr) {
      output.ref.bytes.asTypedList(output.ref.length).fillRange(0, output.ref.length, 0);
      localFree(output.ref.bytes.cast<Void>());
    }
    source.asTypedList(data.length).fillRange(0, data.length, 0);
    calloc.free(source);
    calloc.free(output);
    calloc.free(input);
  }
}

class TgoWindowsVault {
  TgoWindowsVault(String databasePath, {File? credentialFile})
    : file = credentialFile ?? File(
        paths.join(
          Platform.environment['APPDATA'] ?? paths.dirname(databasePath),
          'NohutFalafel',
          'trendyol-go-credentials.dpapi',
        ),
      );
  final File file;

  Future<TgoCredentials?> load() async {
    if (!await file.exists()) return null;
    final ciphertext = base64Decode((await file.readAsString()).trim());
    final clear = _protectForCurrentUser(ciphertext, decrypt: true);
    try {
      final fields = jsonDecode(utf8.decode(clear)) as Map;
      return TgoCredentials(
        fields['supplierId'] as String,
        fields['apiKey'] as String,
        fields['apiSecret'] as String,
        fields['email'] as String,
      );
    } finally {
      clear.fillRange(0, clear.length, 0);
    }
  }

  Future<void> save(TgoCredentials value) async {
    if (!value.valid) {
      throw const FormatException('Satıcı ID, API Key, API Secret ve e-posta gerekli.');
    }
    final clear = utf8.encode(jsonEncode({
      'supplierId': value.supplierId,
      'apiKey': value.apiKey,
      'apiSecret': value.apiSecret,
      'email': value.email,
    }));
    final String encrypted;
    try {
      encrypted = base64Encode(_protectForCurrentUser(clear, decrypt: false));
    } finally {
      clear.fillRange(0, clear.length, 0);
    }
    await file.parent.create(recursive: true);
    final staging = await file.parent.createTemp('.trendyol-go-');
    try {
      final pending = File(paths.join(staging.path, 'credentials.dpapi'));
      await pending.writeAsString(encrypted, flush: true);
      await pending.rename(file.path);
    } finally {
      await staging.delete(recursive: true);
    }
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

List<Json> tgoOrders(Json s) => asMaps(s['trendyolGoOrders']).toList();

/// Only fully delivered, non-test packages count as completed sales.
bool tgoCountsAsSale(Json o) =>
    o['testPackage'] != true && o['status'] == 'Delivered';
Json normalizeTgoPackage(Json p) {
  final id = '${p['id'] ?? ''}',
      number = '${p['orderNumber'] ?? p['orderId'] ?? ''}';
  if (id.isEmpty || number.isEmpty)
    throw const FormatException('Geçersiz platform paketi.');
  final lines = <Json>[];
  for (final l in asMaps(p['lines'])) {
    final items = asMaps(l['items']);
    final qty = items.isEmpty
        ? 1
        : items.where((e) => e['isCancelled'] != true).length;
    if (qty <= 0) continue;
    lines.add({
      'name': '${l['name'] ?? ''}',
      'qty': qty,
      'unitPriceCents': tgoCents(l['unitSellingPrice'] ?? l['price']),
      'options': [
        for (final m in asMaps(l['modifierProducts'])) '${m['name'] ?? ''}',
      ],
    });
  }
  final payment = p['payment'] is Map
      ? p['payment'] as Map
      : <String, dynamic>{};
  return {
    'source': 'Trendyol Go',
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
    'pickup': p['storePickupSelected'] == true,
    'testPackage': p['testPackage'] == true,
    'lines': lines,
  };
}

class TrendyolGoReadonly extends ChangeNotifier {
  TrendyolGoReadonly(this.store) : vault = TgoWindowsVault(store.filePath);
  static const liveSyncEnabled = bool.fromEnvironment('NOHUT_TRENDYOL_LIVE_SYNC');
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
    if (credentials?.valid == true) unawaited(sync());
    _timer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (credentials?.valid == true) unawaited(sync());
    });
  }

  Future<void> save(TgoCredentials c) async {
    await vault.save(c);
    credentials = c;
    status = liveSyncEnabled ? 'Kaydedildi' : pausedStatus;
    error = '';
    if (!_closed) notifyListeners();
  }

  Future<void> sync() async {
    if (!liveSyncEnabled || _closed || syncing || credentials?.valid != true) return;
    syncing = true;
    status = 'Senkronize ediliyor';
    error = '';
    notifyListeners();
    try {
      final c = credentials!, meta = store.read().data['tgoSyncInfo'];
      final last = meta is Map
          ? DateTime.tryParse('${meta['lastSync'] ?? ''}')
          : null;
      final start = DateTime.now().toUtc().subtract(
        last == null ? const Duration(days: 7) : const Duration(hours: 24),
      );
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
            },
          );
          final req = await client.getUrl(uri);
          req.headers.set(
            HttpHeaders.authorizationHeader,
            'Basic ' + base64Encode(utf8.encode(c.apiKey + ':' + c.apiSecret)),
          );
          req.headers.set(
            HttpHeaders.userAgentHeader,
            c.supplierId + ' - SelfIntegration',
          );
          req.headers.set('x-agentname', 'NohutFalafelPOS');
          req.headers.set('x-executor-user', c.email);
          req.headers.set(HttpHeaders.acceptHeader, 'application/json');
          final res = await req.close().timeout(const Duration(seconds: 20));
          final payload = await utf8.decoder.bind(res).join();
          if (res.statusCode != 200) {
            throw FormatException('Trendyol API HTTP ${res.statusCode}');
          }
          final result = jsonDecode(payload);
          if (result is! Map || result['content'] is! List) {
            throw const FormatException('Sipariş yanıtı geçersiz.');
          }
          for (final raw in result['content'] as List) {
            if (raw is Map) fresh.add(normalizeTgoPackage(Json.from(raw)));
          }
          final pages = (result['totalPages'] as num?)?.toInt() ?? 1;
          if (page + 1 >= pages) break;
          if (page == 9)
            throw const FormatException('API sayfa sınırı; veri kısmi.');
        }
      } finally {
        client.close(force: true);
      }
      var saved = false;
      for (var i = 0; i < 4 && !saved; i++) {
        final snapshot = store.read(), next = copyJson(snapshot.data);
        final merged = <String, Json>{};
        for (final o in tgoOrders(next)) {
          merged['${o['supplierId']}:${o['storeId']}:${o['orderNumber']}'] = o;
        }
        for (final o in fresh) {
          final key = '${o['supplierId']}:${o['storeId']}:${o['orderNumber']}';
          final prior = merged[key];
          // Do not allocate a different display number when platform status changes.
          merged[key] = prior == null
              ? o
              : {
                  ...o,
                  if (prior['dailyNumber'] is int)
                    'dailyNumber': prior['dailyNumber'],
                  if (prior['numberDay'] is String)
                    'numberDay': prior['numberDay'],
                };
        }
        next['trendyolGoOrders'] = merged.values.toList();
        assignDailyNumbers(next);
        next['tgoSyncInfo'] = {
          'lastSync': DateTime.now().toUtc().toIso8601String(),
        };
        saved = store.replace(next, snapshot.revision).ok;
      }
      if (!saved)
        throw const FormatException('Veritabanı güncellemesi çakıştı.');
      lastSync = DateTime.now().toLocal().toIso8601String();
      status = 'Bağlı · Salt okunur';
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
