import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/market_prices.dart';
import 'package:nohut_falafel_desktop/market_watch_transfer.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';

void main() {
  final a101 = nohutStorePlaces.first;

  Json source() {
    final state = emptyPosState();
    editMarketPriceState(state, (config) {
      config['enabled'] = true;
      config['latitude'] = 40.7650391;
      config['longitude'] = 30.3602224;
      config['distance'] = 4.0;
      config['storeMatches'] = {
        'a101': {
          'confirmed': true,
          'storeId': 'a101',
          'depotId': 'source-a101-4',
          'market': 'A101',
          'name': 'A101 Bağlar',
          'googleMapsFeatureId': a101.googleMapsFeatureId,
          'address': a101.address,
          'matchedAt': '2026-11-21T13:00:00Z',
        },
      };
    });
    addTrackedMarketQuote(state, const MarketQuote(
      productId: 'limon-4',
      title: 'Diyar Baharat Limon Tuzu 100 Gr',
      market: 'A101', depotId: 'source-a101-4',
      depotName: 'A101 Bağlar', unit: '100 Gr',
      observedAt: '2026-11-21T12:00:00Z',
      priceCents: 5450,
      imageUrl: 'https://example.org/limon.png',
    ), storeId: 'a101');
    final tracked = trackedMarketProducts(state);
    tracked.first['category'] = 'Baharat';
    tracked.first['customImageUrl'] = 'https://example.org/my-limon.png';
    editMarketPriceState(state, (config) => config['tracked'] = tracked);
    return state;
  }

  test('categorization defaults; manual category always wins', () {
    expect(marketProductCategory({'title': 'Göbek Salata 1 Adet'}), 'Sebze');
    expect(marketProductCategory({'title': 'Diyar Kimyon 75 Gr'}), 'Baharat');
    expect(marketProductCategory({'title': 'Rençber Beyaz Nohut 1 Kg'}),
      'Bakliyat');
    expect(marketProductCategory({'title': 'Közlenmiş Patlıcan 540 Gr'}),
      'Konserve');
    expect(marketProductCategory({'title': 'Feast Dondurulmuş Patates'}),
      'Dondurulmuş');
    expect(marketProductCategory({'title': 'Ayran 170 ml'}), 'Diğer');
    expect(marketProductCategory({
      'title': 'Közlenmiş Patlıcan', 'category': 'Sebze',
    }), 'Sebze');
  });

  test('newest discounts and price increases precede grouped categories', () {
    final items = <Json>[
      {'key': 's', 'title': 'Göbek Marul'},
      {'key': 'b', 'title': 'Kimyon'},
      {'key': 'k', 'title': 'Nohut'},
      {'key': 'older', 'title': 'Patlıcan',
        'priceCents': 5500, 'previousPriceCents': 6200,
        'change': 'down', 'lastChangedAt': '2026-11-20T12:00:00Z'},
      {'key': 'newer', 'title': 'Limon Tuzu',
        'priceCents': 6500, 'previousPriceCents': 5500,
        'change': 'up', 'lastChangedAt': '2026-11-21T12:00:00Z'},
    ];
    expect(orderedMarketWatchProducts(items)
        .map((item) => item['key']).toList(),
      ['newer', 'older', 's', 'b', 'k']);
  });

  test('portable JSON restores product, photo URL, market depot, prices and category', () {
    final current = source();
    final text = exportMarketWatch(current);
    final backup = parseMarketWatch(text);
    expect(backup.count, 1);
    expect(backup.storeMatches['a101']['depotId'], 'source-a101-4');
    final target = emptyPosState();
    target['customUnrelatedPosSetting'] = {'keep': 'yes'};
    final untouched = jsonEncode(target['orders']);
    final merged = mergeMarketWatchBackup(target, backup);
    expect(merged.added, 1);
    expect(merged.mappingsAdded, 1);
    expect(jsonEncode(target['orders']), untouched);
    expect(target['customUnrelatedPosSetting'], {'keep': 'yes'});
    final watch = trackedMarketProducts(target).single;
    expect(watch['category'], 'Baharat');
    expect(watch['priceCents'], 5450);
    expect(watch['storeId'], 'a101');
    expect(watch['customImageUrl'], 'https://example.org/my-limon.png');
    expect(marketPriceState(target)['enabled'], false);
    expect(marketPriceState(target)['storeMatches']['a101']['confirmed'],
      true);
  });

  test('import adds only and repeated import is idempotent', () {
    final existing = source();
    final backup = parseMarketWatch(exportMarketWatch(existing));
    existing['orders'] = [{'id': 991, 'closed': true}];
    final first = mergeMarketWatchBackup(existing, backup);
    final second = mergeMarketWatchBackup(existing, backup);
    expect(first.added, 0);
    expect(first.duplicates, 1);
    expect(second.added, 0);
    expect(second.duplicates, 1);
    expect(trackedMarketProducts(existing), hasLength(1));
    expect((existing['orders'] as List).single['id'], 991);
  });

  test('merge adds only missing products and keeps local edits and newer prices', () {
    final local = source();
    editMarketPriceState(local, (settings) {
      settings['tracked'] = trackedMarketProducts(local).map((p) => {
        ...p,
        'priceCents': 6200,
        'category': 'Diğer',
        'customImageUrl': 'https://example.org/local-choice.jpg',
      }).toList();
    });
    final importedState = source();
    addTrackedMarketQuote(importedState, const MarketQuote(
      productId: 'sumak-10', title: 'Sumak 100 gr',
      market: 'A101', depotId: 'source-a101-4',
      depotName: 'A101 Bağlar', unit: '100 gr',
      priceCents: 6900, observedAt: '2026-11-21T22:00:00Z',
    ), storeId: 'a101');
    final backup = parseMarketWatch(exportMarketWatch(importedState));
    final preview = planMarketWatchMerge(local, backup);
    expect(preview.added, 1);
    expect(preview.duplicates, 1);
    expect(preview.conflicts, 0);
    expect(trackedMarketProducts(local), hasLength(1)); // preview is pure

    final applied = mergeMarketWatchBackup(local, backup);
    expect(applied.added, 1);
    final products = trackedMarketProducts(local);
    expect(products, hasLength(2));
    final limon = products.firstWhere((p) => p['productId'] == 'limon-4');
    expect(limon['priceCents'], 6200);
    expect(limon['category'], 'Diğer');
    expect(limon['customImageUrl'], 'https://example.org/local-choice.jpg');
    expect(products.where((p) => p['productId'] == 'sumak-10'), hasLength(1));
    expect(marketPriceState(local)['enabled'], true); // preserved locally
    final second = mergeMarketWatchBackup(local, backup);
    expect(second.added, 0);
    expect(second.duplicates, 2);
  });

  test('different verified branch mapping is never silently replaced', () {
    final local = source();
    editMarketPriceState(local, (settings) {
      final mappings = Map<String, dynamic>.from(
        settings['storeMatches'] as Map);
      final store = Map<String, dynamic>.from(mappings['a101'] as Map);
      store['depotId'] = 'local-a101-other-depot';
      mappings['a101'] = store;
      settings['storeMatches'] = mappings;
    });
    final sourceState = source();
    addTrackedMarketQuote(sourceState, const MarketQuote(
      productId: 'new-12', title: 'Diyar Kimyon 75 gr',
      market: 'A101', depotId: 'source-a101-4',
      depotName: 'A101 Bağlar', unit: '75 gr',
      priceCents: 3900, observedAt: '2026-11-21T22:00:00Z',
    ), storeId: 'a101');
    final backup = parseMarketWatch(exportMarketWatch(sourceState));
    final preview = planMarketWatchMerge(local, backup);
    expect(preview.added, 0);
    expect(preview.duplicates, 1);
    expect(preview.conflicts, 2); // 1 branch + 1 new product
    final result = mergeMarketWatchBackup(local, backup);
    expect(result.added, 0);
    expect(trackedMarketProducts(local), hasLength(1));
    expect(marketPriceState(local)['storeMatches']['a101']['depotId'],
      'local-a101-other-depot');
  });

  test('merge keeps other POS state and never imports enabled flag', () {
    final target = emptyPosState();
    target['orders'] = [{'id': 1234, 'paid': true}];
    final backup = parseMarketWatch(exportMarketWatch(source()));
    final result = mergeMarketWatchBackup(target, backup);
    expect(result.added, 1);
    expect(result.mappingsAdded, 1);
    expect(marketPriceState(target)['enabled'], false);
    expect((target['orders'] as List).single['id'], 1234);
    expect(marketPriceState(target)['storeMatches']['a101']['confirmed'], true);
    expect(mergeMarketWatchBackup(target, backup).added, 0);
    expect(trackedMarketProducts(target), hasLength(1));
  });

  test('malformed, wrong version, duplicate, tampered branch and bad category rejected', () {
    final raw = jsonDecode(exportMarketWatch(source())) as Map<String, dynamic>;
    expect(() => parseMarketWatch('not json'), throwsFormatException);
    expect(() => parseMarketWatch(jsonEncode({...raw, 'version': 12})),
      throwsFormatException);
    expect(() => parseMarketWatch(jsonEncode({
      ...raw, 'tracked': [raw['tracked'][0], raw['tracked'][0]]
    })), throwsFormatException);
    final badBranch = jsonDecode(jsonEncode(raw)) as Map<String, dynamic>;
    badBranch['storeMatches']['a101']['googleMapsFeatureId'] = 'wrong';
    expect(() => parseMarketWatch(jsonEncode(badBranch)),
      throwsFormatException);
    final badCategory = jsonDecode(jsonEncode(raw)) as Map<String, dynamic>;
    badCategory['tracked'][0]['category'] = 'Hack';
    expect(() => parseMarketWatch(jsonEncode(badCategory)),
      throwsFormatException);
    final badPhoto = jsonDecode(jsonEncode(raw)) as Map<String, dynamic>;
    badPhoto['tracked'][0]['customImageUrl'] = 'file:///unsafe';
    expect(() => parseMarketWatch(jsonEncode(badPhoto)),
      throwsFormatException);
    expect(() => parseMarketWatch('x' * (1024 * 1024 + 1)),
      throwsFormatException);
  });
}
