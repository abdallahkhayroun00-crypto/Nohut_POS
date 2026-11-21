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

  test('four exact market locations are saved, with distinct Hakmar branches', () {
    expect(nohutStorePlaces, hasLength(4));
    expect(nohutStorePlaces[0].id, 'a101');
    expect(nohutStorePlaces[0].address,
      'Kemalpaşa Mah. Bağlar Cad. No:82, Serdivan / Sakarya');
    expect(nohutStorePlaces[1].branchName, 'İSTİKLAL / SERDİVAN');
    expect(nohutStorePlaces[1].address,
      contains('Oğuzhan Sk. Bodrum Kat 2'));
    expect(nohutStorePlaces[2].address,
      contains('Karadere Sk. No:9'));
    expect(nohutStorePlaces[3].address,
      contains('Döner Sk. No:29/A'));
    expect(nohutStorePlaces.map((e) => e.googleMapsFeatureId).toSet(),
      hasLength(4));
    expect(nohutStorePlaces[0].latitude, 40.7647916);
    expect(nohutStorePlaces[0].longitude, 30.3604948);
    expect(nohutStorePlaces[1].latitude, 40.7634139);
    expect(nohutStorePlaces[1].longitude, 30.3610601);
    expect(nohutStorePlaces[2].latitude, 40.7666496);
    expect(nohutStorePlaces[2].longitude, 30.3589871);
    expect(nohutStorePlaces[3].latitude, 40.7630785);
    expect(nohutStorePlaces[3].longitude, 30.3568336);
    expect(nohutStorePlaces[2].id, isNot(nohutStorePlaces[3].id));
  });

  test('API branch selection must match brand AND physical coordinates', () {
    const nearby = [
      MarketDepot('a101-correct', 'A101', 'A101 Şube',
          latitude: 40.7648, longitude: 30.3605),
      MarketDepot('a101-wrong', 'A101', 'Other A101',
          latitude: 40.78, longitude: 30.38),
      MarketDepot('bim-wrong', 'BİM', 'BİM',
          latitude: 40.7648, longitude: 30.3605),
      MarketDepot('no-coordinates', 'A101', 'Unknown'),
    ];
    final matched = matchMarketDepots(nohutStorePlaces.first, nearby);
    expect(matched.map((d) => d.id).toList(), ['a101-correct']);
    expect(MarketDepot.parse({
      'id': 'a101-correct', 'marketName': 'A101',
      'sellerName': 'A101 Şube',
      'location': {'lat': 40.7648, 'lon': 30.3605},
    })?.latitude, 40.7648);
    expect(storeDistanceMeters(
        40.7666496, 30.3589871, 40.7630785, 30.3568336),
        greaterThan(300));
  });

  test('BİM/BIM spelling links to the same retailer, never to A101', () {
    expect(marketBrandKey('BİM'), 'bim');
    expect(marketBrandKey('BIM'), 'bim');
    expect(marketBrandKey('Hakmar Express'), 'hakmar');
    expect(marketBrandKey('A101'), isNot(marketBrandKey('BİM')));
  });

  test('tracked product preserves exact physical store link', () {
    final state = emptyPosState();
    addTrackedMarketQuote(state, quote(), storeId: 'hakmar-2');
    final entry = trackedMarketProducts(state).single;
    expect(entry['storeId'], 'hakmar-2');
    expect(entry['depotId'], 'hakmar-1');
    expect(entry['productId'], 'marul-1');
  });

  test('validates input coordinates, radius and absent values', () {
    expect(validMarketCoordinates(40.75, 30.35, 4), isTrue);
    expect(validMarketCoordinates(null, 30.35, 4), isFalse);
    expect(validMarketCoordinates(92, 30.35, 4), isFalse);
    expect(validMarketCoordinates(40.75, 30.35, 0), isFalse);
    expect(validMarketCoordinates(40.75, 30.35, 51), isFalse);
  });

  test('imageUrl accepts only HTTPS and never invents missing photos', () {
    expect(marketImageUrl('https://marketfiyati.org.tr/images/item.png'),
        'https://marketfiyati.org.tr/images/item.png');
    expect(marketImageUrl('http://example.com/photo.jpg'), isNull);
    expect(marketImageUrl('file:///C:/secret.png'), isNull);
    expect(marketImageUrl('https://user:password@site.com/x.png'), isNull);
    expect(marketImageUrl('//site.com/x.png'), isNull);
    expect(marketImageUrl(''), isNull);

    final product = {
      'id': 'feast-1', 'title': 'Feast Patates 1 Kg',
      'imageUrl': 'https://images.example.org/feast.png',
    };
    final offer = {
      'marketAdi': 'BİM', 'depotId': 'bim-1', 'price': 115,
    };
    final found = MarketQuote.parse(product, offer, '2026-11-21T12:00:00Z')!;
    expect(found.imageUrl, 'https://images.example.org/feast.png');

    final state = emptyPosState();
    addTrackedMarketQuote(state, found, storeId: 'bim');
    expect(trackedMarketProducts(state).single['imageUrl'], found.imageUrl);
    final changed = MarketQuote.parse({
      ...product, 'imageUrl': 'http://not-allowed.example.com/item.png',
    }, {...offer, 'price': 110}, '2026-11-22T12:00:00Z')!;
    applyMarketQuote(state, changed);
    expect(trackedMarketProducts(state).single['imageUrl'], found.imageUrl);
    expect(trackedMarketProducts(state).single['priceCents'], 11000);
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
