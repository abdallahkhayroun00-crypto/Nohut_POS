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

/// Custom categories live in the market-watch slice, not the restaurant menu.
bool validMarketCategoryName(Object? value) {
  if (value is! String || value.trim() != value ||
      value.length < 2 || value.length > 32) return false;
  return !value.runes.any((code) => code < 32 || code == 127) &&
      !value.contains('<') && !value.contains('>');
}

List<String> marketWatchCustomCategories(Json state) {
  final raw = marketPriceState(state)['customCategories'];
  if (raw is! List) return <String>[];
  final result = <String>[];
  final seen = marketWatchCategories.map((e) => e.toLowerCase()).toSet();
  for (final value in raw) {
    if (!validMarketCategoryName(value)) continue;
    final name = value as String;
    if (seen.add(name.toLowerCase()) && result.length < 20) {
      result.add(name);
    }
  }
  return result;
}

List<String> marketWatchCategoryOptions(Json state) => [
  ...marketWatchCategories.take(marketWatchCategories.length - 1),
  ...marketWatchCustomCategories(state),
  'Diğer',
];

void addMarketWatchCategory(Json state, String rawName) {
  final name = rawName.trim();
  if (!validMarketCategoryName(name)) {
    throw const FormatException('Kategori adı 2–32 karakter olmalı.');
  }
  final all = marketWatchCategoryOptions(state);
  if (all.any((x) => x.toLowerCase() == name.toLowerCase())) {
    throw const FormatException('Bu kategori zaten mevcut.');
  }
  final custom = marketWatchCustomCategories(state);
  if (custom.length >= 20) {
    throw const FormatException('En fazla 20 özel kategori eklenebilir.');
  }
  editMarketPriceState(state, (settings) {
    settings['customCategories'] = [...custom, name];
  });
}

String _normal(String input) => input.toLowerCase()
    .replaceAll('i\u0307', 'i').replaceAll('ı', 'i')
    .replaceAll('ş', 's').replaceAll('ğ', 'g')
    .replaceAll('ü', 'u').replaceAll('ö', 'o')
    .replaceAll('ç', 'c');

/// Best-effort initial category. Manager choice is always authoritative.
String marketProductCategory(Json item) {
  final manual = item['category'];
  if (validMarketCategoryName(manual)) {
    return manual as String;
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
List<Json> orderedMarketWatchProducts(List<Json> products,
    {List<String>? categories}) {
  final ordered = [...products];
  final groups = categories ?? marketWatchCategories.skip(1).toList();
  int priority(Json item) {
    if (hasMarketPriceChange(item)) return 0;
    final position = groups.indexOf(marketProductCategory(item));
    return position < 0 ? groups.length + 1 : position + 1;
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
  const MarketWatchBackup(
      this.tracked, this.storeMatches, this.settings, this.customCategories);
  final List<Json> tracked;
  final Json storeMatches;
  final Json settings;
  final List<String> customCategories;
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
    'customCategories': marketWatchCustomCategories(posState),
    'settings': {
      'latitude': market['latitude'],
      'longitude': market['longitude'],
      'distance': market['distance'],
      'refreshIntervalHours': marketPriceRefreshHours(market['refreshIntervalHours']),
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
  final rawCategories = raw['customCategories'];
  if (rawCategories != null && rawCategories is! List) {
    throw const FormatException('Kategori listesi geçersiz.');
  }
  final customCategories = <String>[];
  final seenCategories = marketWatchCategories
      .map((name) => name.toLowerCase()).toSet();
  for (final entry in (rawCategories is List ? rawCategories : const [])) {
    if (!validMarketCategoryName(entry) ||
        !seenCategories.add((entry as String).toLowerCase()) ||
        customCategories.length >= 20) {
      throw const FormatException('Yedekte geçersiz veya yinelenen kategori.');
    }
    customCategories.add(entry);
  }
  final allowedCategories = {...marketWatchCategories, ...customCategories};
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
        (!allowedCategories.contains(category) || category == 'Tümü')) {
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
  final hours = sourceSettings['refreshIntervalHours'];
  if (hours != null &&
      (hours is! int || !marketPriceRefreshChoices.contains(hours))) {
    throw const FormatException('Geçersiz otomatik kontrol sıklığı.');
  }
  settings['refreshIntervalHours'] = marketPriceRefreshHours(hours);
  return MarketWatchBackup(products, matches, settings, customCategories);
}

/// A non-destructive preview. Existing products and branch mappings win.
/// Mismatched physical-branch identities are reported but never applied.
class MarketWatchMergePlan {
  const MarketWatchMergePlan({
    required this.added,
    required this.duplicates,
    required this.conflicts,
    required this.mappingsAdded,
    required this.mappingsKept,
    required this.categoriesAdded,
    required this.categories,
    required this.products,
    required this.matches,
  });

  final int added;
  final int duplicates;
  final int conflicts;
  final int mappingsAdded;
  final int mappingsKept;
  final int categoriesAdded;
  final List<String> categories;
  final List<Json> products;
  final Json matches;
  int get total => products.length;
}

/// Product identity is the verified productId + source depotId (key).
/// Preserve local prices, alert state, manual category and custom photo for
/// duplicates. Only new products and compatible missing mappings are added.
MarketWatchMergePlan planMarketWatchMerge(
    Json posState, MarketWatchBackup backup) {
  final currentConfig = marketPriceState(posState);
  final products = trackedMarketProducts(posState);
  final existingKeys = products.map((p) => (p['key'] ?? '').toString()).toSet();
  final oldMatches = currentConfig['storeMatches'];
  final matches = oldMatches is Map
      ? Map<String, dynamic>.from(oldMatches)
      : <String, dynamic>{};
  var mappingsAdded = 0;
  var mappingsKept = 0;
  var conflicts = 0;
  var duplicates = 0;
  var added = 0;
  final conflictingStores = <String>{};
  final categories = marketWatchCustomCategories(posState);
  var categoriesAdded = 0;
  for (final incoming in backup.customCategories) {
    if ([...marketWatchCategories, ...categories]
        .any((name) => name.toLowerCase() == incoming.toLowerCase())) {
      continue;
    }
    if (categories.length >= 20) {
      conflicts++;
      continue;
    }
    categories.add(incoming);
    categoriesAdded++;
  }

  for (final store in nohutStorePlaces) {
    final incoming = backup.storeMatches[store.id];
    if (incoming is! Map) continue;
    final current = matches[store.id];
    if (current is Map) {
      final sameDepot = current['depotId'] == incoming['depotId'];
      final sameBrand = marketBrandKey(
          (current['market'] ?? '').toString()) ==
          marketBrandKey((incoming['market'] ?? '').toString());
      final sameGooglePlace = current['googleMapsFeatureId'] ==
          store.googleMapsFeatureId;
      if (current['confirmed'] != true || !sameDepot ||
          !sameBrand || !sameGooglePlace) {
        conflictingStores.add(store.id);
        conflicts++;
      } else {
        mappingsKept++;
      }
      continue;
    }
    matches[store.id] = Map<String, dynamic>.from(incoming);
    mappingsAdded++;
  }

  for (final incoming in backup.tracked) {
    final key = (incoming['key'] ?? '').toString();
    if (existingKeys.contains(key)) {
      // Deliberately keep the original watch record; do not override its
      // price or customizations with a backup that may be older.
      duplicates++;
      continue;
    }
    final storeId = incoming['storeId'];
    if (storeId is String) {
      if (conflictingStores.contains(storeId)) {
        conflicts++;
        continue;
      }
      final linked = matches[storeId];
      if (linked is! Map || linked['confirmed'] != true ||
          linked['depotId'] != incoming['depotId'] ||
          marketBrandKey((linked['market'] ?? '').toString()) !=
              marketBrandKey((incoming['market'] ?? '').toString())) {
        conflicts++;
        continue;
      }
    }
    if (products.length >= 500) {
      conflicts++;
      continue;
    }
    final newEntry = Map<String, dynamic>.from(incoming);
    final requestedCategory = newEntry['category'];
    if (requestedCategory is String &&
        backup.customCategories.any(
          (name) => name.toLowerCase() == requestedCategory.toLowerCase())) {
      final compatible = categories.where((name) =>
          name.toLowerCase() == requestedCategory.toLowerCase()).toList();
      if (compatible.isEmpty) {
        conflicts++;
        continue;
      }
      // Preserve the receiving computer's spelling if case differs.
      newEntry['category'] = compatible.first;
    }
    products.add(newEntry);
    existingKeys.add(key);
    added++;
  }

  return MarketWatchMergePlan(
    added: added, duplicates: duplicates, conflicts: conflicts,
    mappingsAdded: mappingsAdded, mappingsKept: mappingsKept,
    categoriesAdded: categoriesAdded, categories: categories,
    products: products, matches: matches,
  );
}

/// Uses the current POS snapshot, so a file never replaces orders, payment
/// state, menu, staff or existing market-watch entries.
/// Source-enabled preference stays specific to the receiving computer.
MarketWatchMergePlan mergeMarketWatchBackup(
    Json posState, MarketWatchBackup backup) {
  final result = planMarketWatchMerge(posState, backup);
  final current = marketPriceState(posState);
  current['tracked'] = result.products;
  current['storeMatches'] = result.matches;
  current['customCategories'] = result.categories;
  // Frequency is a personal PC preference. Import it only for a new setup.
  current['refreshIntervalHours'] ??=
      marketPriceRefreshHours(backup.settings['refreshIntervalHours']);

  // A new receiving PC needs the locality to refresh imported watches.
  // Do not replace existing local settings or turn a data source on.
  final hasLocation = validMarketCoordinates(
      current['latitude'] is num ? current['latitude'] as num : null,
      current['longitude'] is num ? current['longitude'] as num : null,
      current['distance'] is num ? current['distance'] as num : null);
  if (!hasLocation) {
    for (final key in ['latitude', 'longitude', 'distance']) {
      if (backup.settings.containsKey(key)) {
        current[key] = backup.settings[key];
      }
    }
  }
  // Never transfer opt-in implicitly: local enablement controls live queries.
  current['enabled'] = current['enabled'] == true;
  posState['marketPrices'] = current;
  return result;
}
