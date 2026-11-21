import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/market_prices.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';

void main() {
  MarketQuote quote({
    String branch = 'hakmar-1',
    String market = 'Hakmar',
    int price = 4200,
    String at = '2026-11-21T12:00:00Z',
  }) => MarketQuote(
    productId: 'marul-1', title: 'Göbek Marul',
    market: market, depotId: branch, depotName: 'Hakmar Serdivan',
    unit: 'Adet', priceCents: price, observedAt: at,
  );

  test('validates input coordinates, radius and absent values', () {
    expect(validMarketCoordinates(40.75, 30.35, 4), isTrue);
    expect(validMarketCoordinates(null, 30.35, 4), isFalse);
    expect(validMarketCoordinates(92, 30.35, 4), isFalse);
    expect(validMarketCoordinates(40.75, 30.35, 0), isFalse);
    expect(validMarketCoordinates(40.75, 30.35, 51), isFalse);
  });

  test('untrusted response cannot produce missing or zero prices', () {
    final product = {
      'id': '123', 'title': 'Limon Tuzu',
      'refinedVolumeOrWeight': '100 GR',
    };
    final offer = {
      'marketAdi': 'A101', 'depotId': 'a101-1',
      'depotName': 'A101 Merkez', 'price': 32.50,
      'discount': true,
    };
    final item = MarketQuote.parse(product, offer, '2026-11-21T10:00:00Z');
    expect(item, isNotNull);
    expect(item!.priceCents, 3250);
    expect(item.unit, '100 GR');
    expect(item.discount, true);
    expect(MarketQuote.parse(product, {...offer, 'price': 0}, ''), isNull);
    expect(MarketQuote.parse(product, {...offer, 'price': -1}, ''), isNull);
    expect(MarketQuote.parse(product, {...offer, 'depotId': ''}, ''), isNull);
  });

  test('watch key is product AND branch; initial observation is not a discount', () {
    final state = emptyPosState();
    addTrackedMarketQuote(state, quote());
    addTrackedMarketQuote(state, quote());
    expect(trackedMarketProducts(state), hasLength(1));
    expect(trackedMarketProducts(state).single['change'], isNull);
    expect(applyMarketQuote(state, quote(
      branch: 'hakmar-2', price: 1500,
    )), isFalse);
    expect(trackedMarketProducts(state).single['priceCents'], 4200);
  });

  test('falling and rising prices use exact previous observation', () {
    final state = emptyPosState();
    addTrackedMarketQuote(state, quote(price: 5500));
    expect(applyMarketQuote(state, quote(
      price: 4200, at: '2026-11-22T12:00:00Z')), isTrue);
    var record = trackedMarketProducts(state).single;
    expect(record['previousPriceCents'], 5500);
    expect(record['priceCents'], 4200);
    expect(record['change'], 'down');
    // Same price at next refresh must not become a second alert.
    expect(applyMarketQuote(state, quote(
      price: 4200, at: '2026-11-23T12:00:00Z')), isFalse);
    record = trackedMarketProducts(state).single;
    expect(record['previousPriceCents'], 5500);
    expect(record['change'], 'down');
    expect(applyMarketQuote(state, quote(
      price: 6000, at: '2026-11-24T12:00:00Z')), isTrue);
    record = trackedMarketProducts(state).single;
    expect(record['previousPriceCents'], 4200);
    expect(record['priceCents'], 6000);
    expect(record['change'], 'up');
  });

  test('never accepts another store, even with the same product id', () {
    final state = emptyPosState();
    addTrackedMarketQuote(state, quote());
    expect(applyMarketQuote(state, quote(market: 'BİM', price: 1000)), isFalse);
    expect(trackedMarketProducts(state).single['priceCents'], 4200);
  });
}
