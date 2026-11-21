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
    applyMarketWatchBackup(target, backup);
    expect(jsonEncode(target['orders']), untouched);
    expect(target['customUnrelatedPosSetting'], {'keep': 'yes'});
    final watch = trackedMarketProducts(target).single;
    expect(watch['category'], 'Baharat');
    expect(watch['priceCents'], 5450);
    expect(watch['storeId'], 'a101');
    expect(watch['customImageUrl'], 'https://example.org/my-limon.png');
    expect(marketPriceState(target)['enabled'], true);
    expect(marketPriceState(target)['storeMatches']['a101']['confirmed'],
      true);
  });

  test('import overwrites watchlist only and repeated import is idempotent', () {
    final existing = source();
    final backup = parseMarketWatch(exportMarketWatch(existing));
    existing['orders'] = [{'id': 991, 'closed': true}];
    applyMarketWatchBackup(existing, backup);
    applyMarketWatchBackup(existing, backup);
    expect(trackedMarketProducts(existing), hasLength(1));
    expect((existing['orders'] as List).single['id'], 991);
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
