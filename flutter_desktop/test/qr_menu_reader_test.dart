import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/qr_menu_reader.dart';

const _prices = '''
{
  "wrap": [
    {"name":"Falafel Dürüm","price":140},
    {"name":"Vegan Dürüm","price":140}
  ],
  "dessert": [
    {"name":"Layali Lübnan","price":150}
  ]
}
''';

const _campaigns = '''
[
  {
    "id": "2li-menu-300",
    "active": true,
    "price": 300,
    "title": {
      "tr": "2’li Menü",
      "en": "Combo for Two",
      "ar": "وجبة لشخصين"
    },
    "description": {
      "tr": "İki kişilik falafel menüsü.",
      "en": "A falafel combo for two.",
      "ar": "وجبة فلافل لشخصين."
    },
    "items": [
      {
        "tr": "2 Falafel Dürüm",
        "en": "2 falafel wraps",
        "ar": "٢ ساندويتش فلافل"
      }
    ],
    "poster": "assets/campaigns/2li-menu-300.webp",
    "thumbnail": "assets/campaigns/2li-menu-300-thumb.webp",
    "startsAt": null,
    "endsAt": "2026-12-01T00:00:00+03:00"
  }
]
''';

QrMenuReader _mockReader({
  String prices = _prices,
  String campaigns = _campaigns,
  List<Uri>? requests,
}) => QrMenuReader(
  fetcher: (url) async {
    requests?.add(url);
    if (url.path.endsWith('/cms/menu-prices.json')) return prices;
    if (url.path.endsWith('/cms/campaigns.json')) return campaigns;
    throw StateError('Unexpected QR endpoint: ' + url.path);
  },
);

void main() {
  test('reads both public CMS JSON endpoints without changing local POS data',
      () async {
    final requests = <Uri>[];
    final snapshot = await _mockReader(requests: requests).readPublishedMenu();

    expect(requests.map((e) => e.path), [
      '/qr-menu/cms/menu-prices.json',
      '/qr-menu/cms/campaigns.json',
    ]);
    expect(requests.every((url) => url.scheme == 'https'), isTrue);
    expect(snapshot.products, hasLength(3));
    expect(snapshot.products[0].name, 'Falafel Dürüm');
    expect(snapshot.products[0].category, 'wrap');
    expect(snapshot.products[0].priceTl, 140.0);
    expect(snapshot.products[2].name, 'Layali Lübnan');
    expect(snapshot.campaigns, hasLength(1));
    expect(snapshot.campaigns.first.title['ar'], 'وجبة لشخصين');
    expect(snapshot.campaigns.first.items.first['tr'], '2 Falafel Dürüm');
    expect(snapshot.campaigns.first.priceTl, 300.0);
    expect(snapshot.retrievedAtUtc.isUtc, isTrue);
  });

  test('campaign expiry respects offset-aware timestamps', () async {
    final offer = (await _mockReader().readPublishedMenu()).campaigns.single;
    expect(offer.isVisibleAt(DateTime.utc(2026, 11, 14)), isTrue);
    expect(offer.isVisibleAt(DateTime.utc(2026, 11, 30, 21)), isFalse);
  });

  test('rejects product with invalid or negative price', () async {
    final reader = _mockReader(
      prices: '{"wrap":[{"name":"Falafel Dürüm","price":-10}]}',
    );
    await expectLater(reader.readPublishedMenu(),
        throwsA(isA<FormatException>()));
  });

  test('rejects duplicate product names across categories', () async {
    final reader = _mockReader(
      prices: '{"wrap":[{"name":"Falafel","price":140}],'
          '"plate":[{"name":"Falafel","price":200}]}',
    );
    await expectLater(reader.readPublishedMenu(),
        throwsA(isA<FormatException>()));
  });

  test('rejects malformed CMS body instead of replacing the local catalog',
      () async {
    final reader = _mockReader(prices: 'not-json');
    await expectLater(reader.readPublishedMenu(), throwsFormatException);
  });

  test('rejects campaign image paths outside public campaign assets', () async {
    final reader = _mockReader(
      campaigns: _campaigns.replaceFirst(
        'assets/campaigns/2li-menu-300.webp',
        '../private/other.webp',
      ),
    );
    await expectLater(reader.readPublishedMenu(), throwsFormatException);
  });

  test('rejects unversioned http source URL', () async {
    final reader = QrMenuReader(
      baseUrl: Uri.parse('http://localhost:8080/qr-menu/'),
      fetcher: (_) async => _prices,
    );
    await expectLater(reader.readPublishedMenu(), throwsFormatException);
  });

  test('rejects absent prices instead of accepting an empty menu', () async {
    final reader = _mockReader(prices: '{}');
    await expectLater(reader.readPublishedMenu(), throwsFormatException);
  });
}
