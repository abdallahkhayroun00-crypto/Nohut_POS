import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as paths;

import 'pos_logic.dart';
import 'order_reporting.dart';
import 'pos_store.dart';

// Official MEAL GET API ONLY. Never mutates Trendyol Go orders/menu/status.
class TgoCredentials {
  const TgoCredentials(this.supplierId, this.apiKey, this.apiSecret, this.email);
  final String supplierId, apiKey, apiSecret, email;
  bool get valid => RegExp(r'^[0-9]+$').hasMatch(supplierId) &&
      apiKey.isNotEmpty && apiSecret.isNotEmpty && email.contains('@');
}

class TgoWindowsVault {
  TgoWindowsVault(String databasePath) : file = File(paths.join(
      Platform.environment['APPDATA'] ?? paths.dirname(databasePath),
      'NohutFalafel', 'trendyol-go-credentials.dpapi'));
  final File file;
  Future<String> _run(String script, String input) async {
    if (!Platform.isWindows) throw const FormatException('Windows güvenli kasa gerekli.');
    final bytes = <int>[];
    for (final unit in script.codeUnits) { bytes.addAll([unit & 255, unit >> 8]); }
    final p = await Process.start('powershell.exe',
        ['-NoProfile', '-NonInteractive', '-EncodedCommand', base64Encode(bytes)]);
    final output = p.stdout.transform(utf8.decoder).join();
    final errors = p.stderr.transform(utf8.decoder).join();
    p.stdin.write(input);
    await p.stdin.close();
    final result = await output;
    await errors; // Never disclose process stderr; it might contain a secret.
    if (await p.exitCode != 0) throw const FormatException('Güvenli kasa çalışmadı.');
    return result.trim();
  }
  Future<TgoCredentials?> load() async {
    if (!file.existsSync()) return null;
    const ps = r'''$ErrorActionPreference='Stop'
$raw=[Console]::In.ReadToEnd().Trim()
$plain=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($raw),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
[Console]::Out.Write([Text.Encoding]::UTF8.GetString($plain))''';
    final v = jsonDecode(await _run(ps, await file.readAsString())) as Map;
    return TgoCredentials(v['supplierId'] as String, v['apiKey'] as String,
        v['apiSecret'] as String, v['email'] as String);
  }
  Future<void> save(TgoCredentials value) async {
    if (!value.valid) throw const FormatException('Satıcı ID, API Key, API Secret ve e-posta gerekli.');
    const ps = r'''$ErrorActionPreference='Stop'
$raw=[Console]::In.ReadToEnd()
$protected=[Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($raw),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
[Console]::Out.Write([Convert]::ToBase64String($protected))''';
    final encrypted = await _run(ps, jsonEncode({
      'supplierId': value.supplierId, 'apiKey': value.apiKey,
      'apiSecret': value.apiSecret, 'email': value.email,
    }));
    await file.parent.create(recursive: true);
    await file.writeAsString(encrypted, flush: true);
  }
}

int tgoCents(Object? v) => ((v is num ? v : num.tryParse('$v') ?? 0) * 100).round();
String tgoTime(Object? v) {
  final n = v is num ? v.toInt() : int.tryParse('$v') ?? 0;
  return n <= 0 ? DateTime.now().toUtc().toIso8601String()
      : DateTime.fromMillisecondsSinceEpoch(n, isUtc: true).toIso8601String();
}
List<Json> tgoOrders(Json s) => asMaps(s['trendyolGoOrders']).toList();
/// Only fully delivered, non-test packages count as completed sales.
bool tgoCountsAsSale(Json o) =>
    o['testPackage'] != true && o['status'] == 'Delivered';
Json normalizeTgoPackage(Json p) {
  final id = '${p['id'] ?? ''}', number = '${p['orderNumber'] ?? p['orderId'] ?? ''}';
  if (id.isEmpty || number.isEmpty) throw const FormatException('Geçersiz platform paketi.');
  final lines = <Json>[];
  for (final l in asMaps(p['lines'])) {
    final items = asMaps(l['items']);
    final qty = items.isEmpty ? 1 : items.where((e) => e['isCancelled'] != true).length;
    if (qty <= 0) continue;
    lines.add({
      'name': '${l['name'] ?? ''}', 'qty': qty,
      'unitPriceCents': tgoCents(l['unitSellingPrice'] ?? l['price']),
      'options': [for (final m in asMaps(l['modifierProducts'])) '${m['name'] ?? ''}'],
    });
  }
  final payment = p['payment'] is Map ? p['payment'] as Map : <String, dynamic>{};
  return {
    'source': 'Trendyol Go', 'supplierId': '${p['supplierId'] ?? ''}',
    'storeId': '${p['storeId'] ?? ''}', 'packageId': id,
    'orderNumber': number, 'orderCode': '${p['orderCode'] ?? ''}',
    'status': '${p['packageStatus'] ?? ''}',
    'createdAt': tgoTime(p['packageCreationDate']),
    'modifiedAt': tgoTime(p['packageModificationDate'] ?? p['lastModifiedDate']),
    'totalCents': tgoCents(p['totalPrice']),
    'paymentType': '${payment['paymentType'] ?? ''}',
    'customerNote': '${p['customerNote'] ?? ''}',
    'pickup': p['storePickupSelected'] == true,
    'testPackage': p['testPackage'] == true, 'lines': lines,
  };
}

class TrendyolGoReadonly extends ChangeNotifier {
  TrendyolGoReadonly(this.store) : vault = TgoWindowsVault(store.filePath);
  final PosStore store;
  final TgoWindowsVault vault;
  TgoCredentials? credentials;
  Timer? _timer;
  bool syncing = false, _closed = false;
  String status = 'Bağlı değil', lastSync = '', error = '';
  Future<void> start() async {
    try {
      credentials = await vault.load();
      status = credentials == null ? 'API bilgileri bekleniyor' : 'Hazır';
    } catch (_) { status = 'Güvenli kasa okunamadı'; }
    if (!_closed) notifyListeners();
    if (credentials?.valid == true) unawaited(sync());
    _timer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (credentials?.valid == true) unawaited(sync());
    });
  }
  Future<void> save(TgoCredentials c) async {
    await vault.save(c);
    credentials = c; status = 'Kaydedildi'; error = '';
    if (!_closed) notifyListeners();
  }
  Future<void> sync() async {
    if (_closed || syncing || credentials?.valid != true) return;
    syncing = true; status = 'Senkronize ediliyor'; error = '';
    notifyListeners();
    try {
      final c = credentials!, meta = store.read().data['tgoSyncInfo'];
      final last = meta is Map ? DateTime.tryParse('${meta['lastSync'] ?? ''}') : null;
      final start = DateTime.now().toUtc().subtract(
          last == null ? const Duration(days: 7) : const Duration(hours: 24));
      final fresh = <Json>[];
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
      try {
        for (var page = 0; page < 10; page++) {
          final uri = Uri.https('api.tgoapis.com',
              '/integrator/order/meal/suppliers/' + c.supplierId + '/packages', {
            'page': '$page', 'size': '50',
            'packageModificationStartDate': '${start.millisecondsSinceEpoch}',
          });
          final req = await client.getUrl(uri);
          req.headers.set(HttpHeaders.authorizationHeader,
              'Basic ' + base64Encode(utf8.encode(c.apiKey + ':' + c.apiSecret)));
          req.headers.set(HttpHeaders.userAgentHeader, c.supplierId + ' - SelfIntegration');
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
          if (page == 9) throw const FormatException('API sayfa sınırı; veri kısmi.');
        }
      } finally { client.close(force: true); }
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
          merged[key] = prior == null ? o : {
            ...o,
            if (prior['dailyNumber'] is int) 'dailyNumber': prior['dailyNumber'],
            if (prior['numberDay'] is String) 'numberDay': prior['numberDay'],
          };
        }
        next['trendyolGoOrders'] = merged.values.toList();
        assignDailyNumbers(next);
        next['tgoSyncInfo'] = {'lastSync': DateTime.now().toUtc().toIso8601String()};
        saved = store.replace(next, snapshot.revision).ok;
      }
      if (!saved) throw const FormatException('Veritabanı güncellemesi çakıştı.');
      lastSync = DateTime.now().toLocal().toIso8601String();
      status = 'Bağlı · Salt okunur';
    } on FormatException catch (e) {
      error = e.message; status = 'Bağlantı hatası';
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
    _closed = true; _timer?.cancel(); super.dispose();
  }
}
