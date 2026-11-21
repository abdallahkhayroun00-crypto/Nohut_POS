import 'dart:convert';

import 'market_prices.dart';
import 'pos_logic.dart';

/// Portable, versioned backup for market watchlists ONLY (not POS orders).
const marketWatchBackupFormat = 'nohut-market-watch';
const marketWatchBackupVersion = 1;
const marketWatchCategories = <String>[
  'Tümü', 'Sebze', 'Baharat', 'Bakliyat',
  'Konserve', 'Dondurulmuş', 'Diğer',
];

String _normal(String input) => input.toLowerCase()
    .replaceAll('i\u0307', 'i').replaceAll('ı', 'i')
    .replaceAll('ş', 's').replaceAll('ğ', 'g')
    .replaceAll('ü', 'u').replaceAll('ö', 'o')
    .replaceAll('ç', 'c');

/// Best-effort initial category. Manager choice is always authoritative.
String marketProductCategory(Json item) {
  final manual = item['category'];
  if (manual is String && marketWatchCategories.skip(1).contains(manual)) {
    return manual;
  }
  final name = _normal((item['title'] ?? '').toString());
  if (RegExp(r'dondurul|feast |frozen|parmak patates|citir patates')
      .hasMatch(name)) return 'Dondurulmuş';
  if (RegExp(r'kozlen|konserve|tursu|salca|kavanoz|sos ')
      .hasMatch(name)) return 'Konserve';
  if (RegExp(r'limon tuzu|kimyon|sumak|karabiber|pul biber|'
      r'kekik|zencefil|zerdecal|tarcin|baharat|kuru nane')
      .hasMatch(name)) return 'Baharat';
  if (RegExp(r'nohut|mercimek|fasulye|bakla|bulgur|kuru bezelye')
      .hasMatch(name)) return 'Bakliyat';
  if (RegExp(r'patlican|marul|salata|gobek|domates|salatalik|'
      r'biber|patates|sogan|kabak|maydanoz|limon|havuc')
      .hasMatch(name)) return 'Sebze';
  return 'Diğer';
}

bool hasMarketPriceChange(Json item) =>
    (item['change'] == 'up' || item['change'] == 'down') &&
    item['previousPriceCents'] is int &&
    (item['previousPriceCents'] as int) > 0 &&
    item['priceCents'] is int &&
    item['priceCents'] != item['previousPriceCents'];

/// Returns changed items at the top, then the remaining items in category
/// groups. Within each category, items sort by their displayed title.
List<Json> orderedMarketWatchProducts(List<Json> products) {
  final ordered = [...products];
  const categories = [
    'Sebze', 'Baharat', 'Bakliyat', 'Konserve', 'Dondurulmuş', 'Diğer',
  ];
  int priority(Json item) {
    if (hasMarketPriceChange(item)) return 0;
    return 1 + categories.indexOf(marketProductCategory(item));
  }
  ordered.sort((a, b) {
    final byGroup = priority(a).compareTo(priority(b));
    if (byGroup != 0) return byGroup;
    if (hasMarketPriceChange(a) && hasMarketPriceChange(b)) {
      final aDate = DateTime.tryParse((a['lastChangedAt'] ?? '').toString());
      final bDate = DateTime.tryParse((b['lastChangedAt'] ?? '').toString());
      if (aDate != null && bDate != null) {
        final time = bDate.compareTo(aDate);
        if (time != 0) return time;
      }
    }
    final byName = _normal((a['title'] ?? '').toString())
        .compareTo(_normal((b['title'] ?? '').toString()));
    return byName != 0 ? byName :
        (a['key'] ?? '').toString().compareTo((b['key'] ?? '').toString());
  });
  return ordered;
}

class MarketWatchBackup {
  const MarketWatchBackup(this.tracked, this.storeMatches, this.settings);
  final List<Json> tracked;
  final Json storeMatches;
  final Json settings;
  int get count => tracked.length;
}

const _productFields = <String>[
  'key', 'storeId', 'productId', 'title', 'market', 'depotId',
  'depotName', 'unit', 'priceCents', 'previousPriceCents', 'change',
  'lastChangedAt', 'lastCheckedAt', 'sourceTime', 'discount',
  'imageUrl', 'customImageUrl', 'category',
];

String exportMarketWatch(Json posState) {
  final market = marketPriceState(posState);
  final safeProducts = trackedMarketProducts(posState).map((item) {
    return <String, dynamic>{
      for (final key in _productFields)
        if (item.containsKey(key)) key: item[key],
    };
  }).toList();
  final matches = market['storeMatches'] is Map
      ? Map<String, dynamic>.from(market['storeMatches'] as Map)
      : <String, dynamic>{};
  return const JsonEncoder.withIndent('  ').convert({
    'format': marketWatchBackupFormat,
    'version': marketWatchBackupVersion,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'tracked': safeProducts,
    'storeMatches': matches,
    'settings': {
      'latitude': market['latitude'],
      'longitude': market['longitude'],
      'distance': market['distance'],
      // Local user's explicit opt-in can be transferred intentionally.
      'enabled': market['enabled'] == true,
    },
  });
}

String _string(Map item, String name, {int maxLength = 400}) {
  final value = item[name];
  if (value is! String || value.trim().isEmpty ||
      value.length > maxLength) {
    throw FormatException('$name geçersiz.');
  }
  return value;
}

MarketWatchBackup parseMarketWatch(String text) {
  if (utf8.encode(text).length > 1024 * 1024) {
    throw const FormatException('Yedek dosyası 1 MB sınırını aşıyor.');
  }
  final raw = jsonDecode(text);
  if (raw is! Map || raw['format'] != marketWatchBackupFormat ||
      raw['version'] != marketWatchBackupVersion) {
    throw const FormatException('Bu dosya Nohut Market Fiyat Takibi yedeği değil.');
  }
  final list = raw['tracked'];
  if (list is! List || list.length > 500) {
    throw const FormatException('Geçersiz ürün listesi (en fazla 500).');
  }
  final allowedIds = nohutStorePlaces.map((p) => p.id).toSet();
  final ids = <String>{};
  final products = <Json>[];

  for (final entry in list) {
    if (entry is! Map) throw const FormatException('Ürün verisi geçersiz.');
    final productId = _string(entry, 'productId');
    final depotId = _string(entry, 'depotId');
    final key = _string(entry, 'key');
    if (key != '$productId|$depotId' || !ids.add(key)) {
      throw const FormatException('Tekrarlanan veya hatalı ürün kimliği.');
    }
    final price = entry['priceCents'];
    if (price is! int || price <= 0 || price > 1000000000) {
      throw const FormatException('Geçersiz ürün fiyatı.');
    }
    final old = entry['previousPriceCents'];
    if (old != null && (old is! int || old <= 0 || old > 1000000000)) {
      throw const FormatException('Geçersiz eski fiyat.');
    }
    final category = entry['category'];
    if (category != null &&
        (!marketWatchCategories.skip(1).contains(category))) {
      throw const FormatException('Geçersiz ürün kategorisi.');
    }
    final change = entry['change'];
    if (change != null && change != 'up' && change != 'down') {
      throw const FormatException('Geçersiz fiyat değişimi.');
    }
    final storeId = entry['storeId'];
    if (storeId != null && (storeId is! String ||
        !allowedIds.contains(storeId))) {
      throw const FormatException('Bilinmeyen market şubesi.');
    }
    final urls = ['imageUrl', 'customImageUrl'];
    for (final field in urls) {
      if (entry[field] != null &&
          marketImageUrl(entry[field]) == null) {
        throw const FormatException('Geçersiz ürün fotoğrafı URL.');
      }
    }
    final product = <String, dynamic>{
      'key': key, 'productId': productId, 'depotId': depotId,
      'title': _string(entry, 'title', maxLength: 500),
      'market': _string(entry, 'market', maxLength: 100),
      'depotName': _string(entry, 'depotName', maxLength: 500),
      'unit': entry['unit'] is String
          ? (entry['unit'] as String).substring(
              0, ((entry['unit'] as String).length > 200 ? 200 : (entry['unit'] as String).length)) : '',
      'priceCents': price,
      if (storeId != null) 'storeId': storeId,
      for (final field in _productFields)
        if (entry.containsKey(field) &&
            !['key', 'productId', 'depotId', 'title', 'market', 'depotName',
               'unit', 'priceCents', 'storeId'].contains(field))
          field: entry[field],
    };
    products.add(product);
  }

  final sourceMatches = raw['storeMatches'];
  if (sourceMatches is! Map) {
    throw const FormatException('Şube eşleştirmeleri eksik.');
  }
  final matches = <String, dynamic>{};
  for (final store in nohutStorePlaces) {
    final value = sourceMatches[store.id];
    if (value == null) continue;
    if (value is! Map ||
        value['confirmed'] != true ||
        value['googleMapsFeatureId'] != store.googleMapsFeatureId ||
        marketBrandKey((value['market'] ?? '').toString()) !=
            marketBrandKey(store.market)) {
      throw FormatException('Şube eşleşmesi geçersiz.');
    }
    matches[store.id] = <String, dynamic>{
      'storeId': store.id,
      'depotId': _string(value, 'depotId'),
      'market': _string(value, 'market'),
      'name': _string(value, 'name', maxLength: 500),
      'branchName': store.branchName,
      'address': store.address,
      'googleMapsFeatureId': store.googleMapsFeatureId,
      'confirmed': true,
      'matchedAt': (value['matchedAt'] ?? '').toString(),
    };
  }
  for (final item in products) {
    final storeId = item['storeId'];
    if (storeId == null) continue; // Legacy watch without local store mapping.
    final match = matches[storeId];
    if (match is! Map ||
        match['depotId'] != item['depotId'] ||
        marketBrandKey(match['market'].toString()) !=
            marketBrandKey(item['market'].toString())) {
      throw const FormatException(
          'Ürün için kaynak şube eşleştirmesi yok veya tutarsız.');
    }
  }
  final sourceSettings = raw['settings'];
  if (sourceSettings is! Map) {
    throw const FormatException('Yedek ayarları geçersiz.');
  }
  final settings = <String, dynamic>{};
  for (final field in ['latitude', 'longitude', 'distance']) {
    final value = sourceSettings[field];
    if (value != null && (value is! num || !value.isFinite)) {
      throw const FormatException('Konum verisi geçersiz.');
    }
    if (value != null) settings[field] = value;
  }
  if (settings.isNotEmpty &&
      !validMarketCoordinates(settings['latitude'] as num?,
          settings['longitude'] as num?, settings['distance'] as num?)) {
    throw const FormatException('Geçersiz konum ve yarıçap.');
  }
  if (sourceSettings['enabled'] is! bool) {
    throw const FormatException('Fiyat kaynağı ayarı geçersiz.');
  }
  settings['enabled'] = sourceSettings['enabled'];
  return MarketWatchBackup(products, matches, settings);
}

void applyMarketWatchBackup(Json posState, MarketWatchBackup backup) {
  final next = <String, dynamic>{
    'tracked': backup.tracked.map((v) => Map<String, dynamic>.from(v)).toList(),
    'storeMatches': Map<String, dynamic>.from(backup.storeMatches),
    ...backup.settings,
  };
  // Only marketPrices changes. Never overwrite orders, staff, payments, menu.
  posState['marketPrices'] = next;
}
