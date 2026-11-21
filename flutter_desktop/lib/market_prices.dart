import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'market_refresh_schedule.dart' as schedule;
import 'pos_logic.dart';
import 'pos_store.dart';

/// This is NOT an official or licensed market API. The restaurant operator
/// must verify the provider's terms before enabling live use.
const marketPriceTerms = 'https://marketfiyati.org.tr/kullanim-kosullari';

/// Locations supplied by the restaurant from their exact Google Maps pins.
/// Place IDs/coordinates are NOT Market Fiyatı depot IDs. Never query prices
/// against an ID until the user explicitly confirms a nearby API depot.
class MarketStorePlace {
  const MarketStorePlace(this.id, this.market, this.label,
      this.latitude, this.longitude, {
      required this.address,
      required this.googleMapsFeatureId,
      required this.branchName,
  });
  final String id, market, label, address, googleMapsFeatureId, branchName;
  final double latitude, longitude;
}

/// Retailer store/branch identity supplied by the restaurant. A Google Maps
/// feature identifier is NOT a Market Fiyatı depotId. The latter is discovered
/// from the price service and confirmed against the selected retailer/branch.
const nohutStorePlaces = <MarketStorePlace>[
  MarketStorePlace('a101', 'A101', 'A101 Bağlar',
    40.7647916, 30.3604948,
    branchName: 'BAĞLAR / SERDİVAN',
    address: 'Kemalpaşa Mah. Bağlar Cad. No:82, Serdivan / Sakarya',
    googleMapsFeatureId: '0x14ccb3001ac3d21b:0xd4c18ae2a8c14266'),
  MarketStorePlace('bim', 'BİM', 'BİM İstiklal',
    40.7634139, 30.3610601,
    branchName: 'İSTİKLAL / SERDİVAN',
    address: 'İstiklal Mah. Bağlar Cad. Oğuzhan Sk. Bodrum Kat 2, Serdivan / Sakarya',
    googleMapsFeatureId: '0x14ccb29220c5b4a5:0xb2f6cd54c19427b5'),
  MarketStorePlace('hakmar-1', 'Hakmar', 'Hakmar Karadere',
    40.7666496, 30.3589871,
    branchName: 'KARADERE',
    address: 'İstiklal Mah. Karadere Sk. No:9, 54050 Serdivan / Sakarya',
    googleMapsFeatureId: '0x14ccb300337eb5f9:0xf844275840b564d9'),
  MarketStorePlace('hakmar-2', 'Hakmar', 'Hakmar Mavi Durak',
    40.7630785, 30.3568336,
    branchName: 'MAVİ DURAK',
    address: 'Kemalpaşa Mah. Döner Sk. No:29/A, 54050 Serdivan / Sakarya',
    googleMapsFeatureId: '0x14ccb2902b5902ff:0x61bed91bd9283862'),
];

String marketBrandKey(String input) {
  final lower = input.trim().toLowerCase()
      .replaceAll('i\u0307', 'i').replaceAll('ı', 'i');
  if (lower.startsWith('a101')) return 'a101';
  if (lower.startsWith('bim')) return 'bim';
  if (lower.startsWith('hakmar')) return 'hakmar';
  return lower;
}

class MarketDepot {
  const MarketDepot(this.id, this.market, this.name,
      {this.latitude, this.longitude});
  final String id, market, name;
  final double? latitude, longitude;

  static MarketDepot? parse(Object? value) {
    if (value is! Map) return null;
    final id = (value['id'] ?? '').toString().trim();
    final market = (value['marketName'] ?? '').toString().trim();
    if (id.isEmpty || market.isEmpty) return null;
    final location = value['location'];
    final lat = location is Map ? location['lat'] : null;
    final lon = location is Map ? location['lon'] : null;
    return MarketDepot(
      id, market, (value['sellerName'] ?? value['marketName']).toString(),
      latitude: lat is num && lat.isFinite && lat >= -90 && lat <= 90
          ? lat.toDouble() : null,
      longitude: lon is num && lon.isFinite && lon >= -180 && lon <= 180
          ? lon.toDouble() : null,
    );
  }
}

/// Distance is approximate; it is used only to suggest branches for an
/// explicit selection, never to assert two map/provider identities are equal.
double storeDistanceMeters(double lat1, double lon1,
    double lat2, double lon2) {
  const radius = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1 * math.pi / 180) *
      math.cos(lat2 * math.pi / 180) *
      math.pow(math.sin(dLon / 2), 2);
  return radius * 2 * math.asin(math.sqrt(a.clamp(0.0, 1.0).toDouble()));
}

List<MarketDepot> matchMarketDepots(MarketStorePlace place,
    List<MarketDepot> all, {double maximumDistanceMeters = 300}) {
  final candidates = all.where((depot) =>
      marketBrandKey(depot.market) == marketBrandKey(place.market) &&
      depot.latitude != null && depot.longitude != null &&
      storeDistanceMeters(place.latitude, place.longitude,
          depot.latitude!, depot.longitude!) <= maximumDistanceMeters).toList();
  candidates.sort((a, b) => storeDistanceMeters(
      place.latitude, place.longitude, a.latitude!, a.longitude!).compareTo(
      storeDistanceMeters(
          place.latitude, place.longitude, b.latitude!, b.longitude!)));
  return candidates;
}

/// Only direct HTTPS image URLs supplied by the product source or manager.
String? marketImageUrl(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  if (text.isEmpty || text.length > 2048) return null;
  final uri = Uri.tryParse(text);
  if (uri == null || uri.scheme.toLowerCase() != 'https' ||
      !uri.hasAuthority || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.toString();
}

class MarketQuote {
  const MarketQuote({
    required this.productId, required this.title, required this.market,
    required this.depotId, required this.depotName, required this.priceCents,
    required this.unit, required this.observedAt, this.discount, this.sourceTime,
    this.imageUrl,
  });
  final String productId, title, market, depotId, depotName, unit, observedAt;
  final int priceCents;
  final bool? discount;
  final String? sourceTime;
  final String? imageUrl;

  String get key => '$productId|$depotId';

  static MarketQuote? parse(Object? product, Object? offer, String now) {
    if (product is! Map || offer is! Map) return null;
    final id = (product['id'] ?? '').toString().trim();
    final title = (product['title'] ?? '').toString().trim();
    final depot = (offer['depotId'] ?? '').toString().trim();
    final market = (offer['marketAdi'] ?? '').toString().trim();
    final amount = offer['price'];
    if (id.isEmpty || title.isEmpty || depot.isEmpty || market.isEmpty ||
        amount is! num || !amount.isFinite || amount <= 0) return null;
    final cents = (amount * 100).round();
    if (cents <= 0) return null;
    return MarketQuote(
      productId: id, title: title, market: market,
      depotId: depot, depotName: (offer['depotName'] ?? '').toString(),
      priceCents: cents,
      unit: (product['refinedVolumeOrWeight'] ??
        product['refinedQuantityUnit'] ?? '').toString(),
      observedAt: now,
      discount: offer['discount'] is bool ? offer['discount'] as bool : null,
      sourceTime: offer['indexTime']?.toString(),
      imageUrl: marketImageUrl(product['imageUrl']),
    );
  }
}

/// Hours between automatic checks. Twelve hours is the default. Values are
/// whitelisted so a malformed setting cannot overload the unofficial source.
const marketPriceRefreshChoices = <int>[24, 12, 6, 1];

int marketPriceRefreshHours(Object? value) =>
    value is int && marketPriceRefreshChoices.contains(value) ? value : 12;

Json marketPriceState(Json state) => state['marketPrices'] is Map
  ? Map<String, dynamic>.from(state['marketPrices'] as Map)
  : <String, dynamic>{};

List<Json> trackedMarketProducts(Json state) {
  final source = marketPriceState(state)['tracked'];
  if (source is! List) return <Json>[];
  return [
    for (final v in source)
      if (v is Map) Map<String, dynamic>.from(v),
  ];
}

bool validMarketCoordinates(num? lat, num? lon, num? radius) =>
    lat != null && lon != null && radius != null &&
    lat.isFinite && lon.isFinite && radius.isFinite &&
    lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180 &&
    radius > 0 && radius <= 50;

void editMarketPriceState(Json state, void Function(Json) update) {
  final settings = marketPriceState(state);
  update(settings);
  state['marketPrices'] = settings;
}

void addTrackedMarketQuote(Json state, MarketQuote quote, {String? storeId}) {
  final products = trackedMarketProducts(state);
  if (products.any((p) => p['key'] == quote.key)) return;
  products.add({
    'key': quote.key, 'productId': quote.productId,
    if (storeId != null && nohutStorePlaces.any((p) => p.id == storeId))
      'storeId': storeId,
    'title': quote.title, 'market': quote.market, 'depotId': quote.depotId,
    'depotName': quote.depotName, 'unit': quote.unit,
    'priceCents': quote.priceCents, 'lastCheckedAt': quote.observedAt,
    'sourceTime': quote.sourceTime, 'discount': quote.discount,
    if (quote.imageUrl != null) 'imageUrl': quote.imageUrl,
  });
  editMarketPriceState(state, (s) => s['tracked'] = products);
}

/// Do not silently replace missing products with similar items or other shops.
/// Preserve the last change alert until the next actual price change.
bool applyMarketQuote(Json state, MarketQuote quote) {
  var changed = false;
  final products = trackedMarketProducts(state);
  for (final item in products) {
    if (item['key'] != quote.key || item['productId'] != quote.productId ||
        item['depotId'] != quote.depotId ||
        marketBrandKey(item['market'].toString()) !=
            marketBrandKey(quote.market)) continue;
    final old = item['priceCents'];
    if (old is int && old > 0 && old != quote.priceCents) {
      item['previousPriceCents'] = old;
      item['change'] = quote.priceCents < old ? 'down' : 'up';
      item['lastChangedAt'] = quote.observedAt;
      changed = true;
    }
    item['priceCents'] = quote.priceCents;
    item['lastCheckedAt'] = quote.observedAt;
    item['sourceTime'] = quote.sourceTime;
    item['discount'] = quote.discount;
    if (quote.imageUrl != null) item['imageUrl'] = quote.imageUrl;
    editMarketPriceState(state, (s) => s['tracked'] = products);
    break;
  }
  return changed;
}

class MarketPriceClient {
  MarketPriceClient({HttpClient? client}) : _client = client ?? HttpClient();
  final HttpClient _client;
  static final Uri _api = Uri.parse('https://api.marketfiyati.org.tr');

  Future<Object?> _post(String path, Json payload) async {
    if (!const [
      '/api/v2/nearest', '/api/v2/search', '/api/v2/searchByIdentity',
    ].contains(path)) throw const FormatException('Geçersiz fiyat isteği.');
    final request = await _client.postUrl(_api.replace(path: path))
      .timeout(const Duration(seconds: 12));
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.write(jsonEncode(payload));
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw HttpException('Market fiyat yanıtı: HTTP ' +
          response.statusCode.toString());
    }
    if (response.contentLength > 1024 * 1024) {
      throw const FormatException('Fiyat verisi çok büyük.');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final part in response.timeout(const Duration(seconds: 15))) {
      bytes.add(part);
      if (bytes.length > 1024 * 1024) {
        throw const FormatException('Fiyat verisi çok büyük.');
      }
    }
    return jsonDecode(utf8.decode(bytes.takeBytes()));
  }

  /// Experimental source endpoint. There is no guaranteed list of all shops.
  Future<List<MarketDepot>> nearby(
      double latitude, double longitude, double distance) async {
    if (!validMarketCoordinates(latitude, longitude, distance)) {
      throw const FormatException('Geçerli konum gerekli.');
    }
    final raw = await _post('/api/v2/nearest', {
      'latitude': latitude, 'longitude': longitude, 'distance': distance,
    });
    if (raw is! List) throw const FormatException('Şube yanıtı geçersiz.');
    final depots = <MarketDepot>[];
    for (final item in raw) {
      final depot = MarketDepot.parse(item);
      if (depot != null) depots.add(depot);
    }
    return depots;
  }

  Future<List<MarketQuote>> search({
    required String keywords, required String depotId, required String market,
    required double latitude, required double longitude,
    required double distance,
  }) async {
    if (keywords.trim().length < 2 || depotId.isEmpty ||
        !validMarketCoordinates(latitude, longitude, distance)) {
      throw const FormatException('Ürün, şube ve konumu kontrol edin.');
    }
    final raw = await _post('/api/v2/search', {
      'keywords': keywords.trim(), 'pages': 0, 'size': 25,
      'latitude': latitude, 'longitude': longitude, 'distance': distance,
      'depots': [depotId], 'market_names': [market],
    });
    return _quotes(raw, depotId, market);
  }

  Future<MarketQuote?> lookup({
    required String productId, required String depotId,
    required String market, required double latitude,
    required double longitude, required double distance,
  }) async {
    if (productId.isEmpty || depotId.isEmpty ||
        !validMarketCoordinates(latitude, longitude, distance)) return null;
    final raw = await _post('/api/v2/searchByIdentity', {
      'identity': productId, 'identityType': 'id',
      'pages': 0, 'size': 1,
      'latitude': latitude, 'longitude': longitude, 'distance': distance,
      'depots': [depotId],
    });
    for (final quote in _quotes(raw, depotId, market)) {
      if (quote.productId == productId) return quote;
    }
    return null;
  }

  List<MarketQuote> _quotes(Object? response, String depotId, String market) {
    if (response is! Map || response['content'] is! List) {
      throw const FormatException('Ürün verisi geçersiz.');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final results = <MarketQuote>[];
    for (final item in response['content'] as List) {
      if (item is! Map || item['productDepotInfoList'] is! List) continue;
      for (final offer in item['productDepotInfoList'] as List) {
        final quote = MarketQuote.parse(item, offer, now);
        if (quote != null && quote.depotId == depotId &&
            marketBrandKey(quote.market) == marketBrandKey(market) &&
            !results.any((entry) => entry.key == quote.key)) {
          results.add(quote);
        }
      }
    }
    return results;
  }

  void close() => _client.close(force: true);
}

class MarketPriceRefresh {
  const MarketPriceRefresh(this.updated, this.unavailable, this.failed);
  final int updated, unavailable, failed;
}

Future<MarketPriceRefresh> refreshMarketPrices(
  PosStore store, MarketPriceClient client, {bool force = false}) async {
  final settings = marketPriceState(store.read().data);
  if (settings['enabled'] != true) return const MarketPriceRefresh(0, 0, 0);
  final lat = settings['latitude'], lon = settings['longitude'];
  final distance = settings['distance'];
  if (lat is! num || lon is! num || distance is! num ||
      !validMarketCoordinates(lat, lon, distance)) {
    return const MarketPriceRefresh(0, 0, 0);
  }
  final entries = trackedMarketProducts(store.read().data).take(50).toList();
  if (entries.isEmpty) return const MarketPriceRefresh(0, 0, 0);
  if (!schedule.marketRefreshIsDue(settings, DateTime.now(), force: force)) {
    return const MarketPriceRefresh(0, 0, 0);
  }

  // Throttle before requests; concurrent retries cannot accidentally hammer
  // the unofficial upstream service.
  final first = store.read();
  final pending = copyJson(first.data);
  editMarketPriceState(pending, (s) {
    s['lastRefreshAttempt'] = DateTime.now().toUtc().toIso8601String();
  });
  if (!store.replace(pending, first.revision).ok) {
    return const MarketPriceRefresh(0, 0, 0);
  }

  var unavailable = 0, failed = 0;
  final fetched = <MarketQuote>[];
  for (var index = 0; index < entries.length; index++) {
    // The third-party reference requests at least 1 second between calls.
    if (index > 0) await Future<void>.delayed(const Duration(seconds: 1));
    final item = entries[index];
    // Every observed price belongs to its confirmed physical branch, not a
    // generic Serdivan query. Legacy watch records retain the older context.
    final watchStoreId = (item['storeId'] ?? '').toString();
    final stores = nohutStorePlaces.where((p) => p.id == watchStoreId).toList();
    final watchedStore = stores.isEmpty ? null : stores.single;
    if (watchedStore != null) {
      final matches = settings['storeMatches'];
      final saved = matches is Map ? matches[watchStoreId] : null;
      if (saved is! Map ||
          (saved['depotId'] ?? '').toString() !=
              (item['depotId'] ?? '').toString() ||
          marketBrandKey((saved['market'] ?? '').toString()) !=
              marketBrandKey(watchedStore.market)) {
        unavailable++;
        continue;
      }
    }
    try {
      final quote = await client.lookup(
        productId: (item['productId'] ?? '').toString(),
        depotId: (item['depotId'] ?? '').toString(),
        market: (item['market'] ?? '').toString(),
        latitude: watchedStore?.latitude ?? lat.toDouble(),
        longitude: watchedStore?.longitude ?? lon.toDouble(),
        distance: distance.toDouble(),
      );
      if (quote == null) {
        unavailable++;
      } else {
        fetched.add(quote);
      }
    } catch (_) {
      failed++;
    }
  }
  for (var attempt = 0; attempt < 3; attempt++) {
    final current = store.read();
    final next = copyJson(current.data);
    for (final quote in fetched) {
      applyMarketQuote(next, quote);
    }
    editMarketPriceState(next, (s) {
      s['lastRefreshResult'] = DateTime.now().toUtc().toIso8601String();
      s['lastRefreshError'] = failed > 0
          ? '$failed ürün kontrol edilemedi; önceki fiyatlar korundu.'
          : unavailable > 0
              ? '$unavailable ürün/şube için fiyat bulunamadı.'
              : '';
    });
    if (store.replace(next, current.revision).ok) break;
  }
  return MarketPriceRefresh(fetched.length, unavailable, failed);
}
