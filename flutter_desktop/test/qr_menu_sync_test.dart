import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/qr_menu_reader.dart';
import 'package:nohut_falafel_desktop/qr_menu_sync.dart';

PublishedQrMenu exampleRemote({double falafelPrice = 150}) {
  return PublishedQrMenu(
    products: [
      PublishedProductPrice(
        category: 'wrap',
        name: 'Falafel Dürüm',
        priceTl: falafelPrice,
      ),
      const PublishedProductPrice(
        category: 'wrap',
        name: 'Vegan Dürüm',
        priceTl: 140,
      ),
      for (var n = 0; n < 48; n++)
        PublishedProductPrice(
          category: 'drink',
          name: 'Test Ürünü $n',
          priceTl: 40,
        ),
    ],
    campaigns: [
      const PublishedCampaign(
        id: 'falafel-menu-250',
        active: true,
        priceTl: 250,
        title: {'tr': 'Falafel Menü', 'en': 'Falafel Menu', 'ar': 'وجبة فلافل'},
        description: {'tr': '', 'en': '', 'ar': ''},
        items: [
          {'tr': 'Falafel', 'en': 'Falafel', 'ar': 'فلافل'},
        ],
        poster: 'assets/campaigns/falafel-menu-250.webp',
        thumbnail: 'assets/campaigns/falafel-menu-250-thumb.webp',
      ),
    ],
    retrievedAtUtc: DateTime.utc(2026, 11, 14),
  );
}

Map<String, dynamic> fixturePos() => {
  ...emptyPosState(),
  'localMenu': [
    {'id': 25, 'name': 'Falafel Dürüm', 'category': 'wrap', 'price': 140},
    {'id': 37, 'name': 'Old Local Item', 'category': 'meze', 'price': 120},
  ],
  'orders': [
    {
      'id': 1200,
      'source': 'Gel-Al',
      'closed': true,
      'cancelled': false,
      'batches': [
        {
          'id': 1,
          'lines': [
            {
              'name': 'Falafel Dürüm',
              'productId': 25,
              'price': 140,
              'qty': 1,
              'removed': [],
              'note': '',
            }
          ],
        }
      ],
      'payments': [
        {'method': 'Nakit', 'amount': 140, 'refunds': []},
      ],
    },
  ],
  'nextId': 1201,
};

String remotePriceJson() => jsonEncode({
  'wrap': [
    {'name': 'Falafel Dürüm', 'price': 150},
    {'name': 'Vegan Dürüm', 'price': 140},
  ],
  'drink': [
    for (var n = 0; n < 48; n++)
      {'name': 'Test Ürünü $n', 'price': 40},
  ],
});

QrMenuReader mockReader({bool fail = false}) => QrMenuReader(
  fetcher: (uri) async {
    if (fail) throw const SocketException('offline');
    if (uri.path.endsWith('menu-prices.json')) return remotePriceJson();
    return '[]';
  },
);

void main() {
  test('adds new products, reprices existing ID and leaves historical orders',
      () {
    final local = fixturePos();
    final oldOrder = jsonEncode(local['orders']);
    final result = reconcilePublishedMenu(local, exampleRemote());
    expect(result.changed, isTrue);
    expect(result.added, 49);
    expect(result.repriced, 1);
    expect(result.unlisted, 1);
    final products = (local['localMenu'] as List).cast<Map>();
    final falafel = products.singleWhere((p) => p['name'] == 'Falafel Dürüm');
    expect(falafel['id'], 25);
    expect(falafel['price'], 150.0);
    final vegan = products.singleWhere((p) => p['name'] == 'Vegan Dürüm');
    expect(vegan['id'], 38);
    expect(vegan['price'], 140.0);
    expect(products.any((p) => p['name'] == 'Old Local Item'), isTrue);
    expect(jsonEncode(local['orders']), oldOrder);
    expect((local['qrCampaigns'] as List), hasLength(1));
  });

  test('same website data does not cause extra writes or renumber IDs', () {
    final local = fixturePos();
    final first = reconcilePublishedMenu(local, exampleRemote());
    final ids = jsonEncode(local['localMenu']);
    final second = reconcilePublishedMenu(local, exampleRemote());
    expect(first.changed, isTrue);
    expect(second.changed, isFalse);
    expect(second.added, 0);
    expect(second.repriced, 0);
    expect(jsonEncode(local['localMenu']), ids);
  });

  test('rejects suspicious short feed without changing menu', () {
    final local = fixturePos(), previous = jsonEncode(local);
    final remote = PublishedQrMenu(
      products: [
        const PublishedProductPrice(
          category: 'wrap',
          name: 'Vegan Dürüm',
          priceTl: 140,
        ),
      ],
      campaigns: const [],
      retrievedAtUtc: DateTime.utc(2026),
    );
    expect(() => reconcilePublishedMenu(local, remote), throwsFormatException);
    expect(jsonEncode(local), previous);
  });

  test('rejects a category mismatch before any changes', () {
    final local = fixturePos(), previous = jsonEncode(local);
    final remote = exampleRemote();
    final conflicting = PublishedQrMenu(
      products: [
        const PublishedProductPrice(
          category: 'drink',
          name: 'Falafel Dürüm',
          priceTl: 999,
        ),
        ...remote.products.skip(1),
      ],
      campaigns: remote.campaigns,
      retrievedAtUtc: remote.retrievedAtUtc,
    );
    expect(
      () => reconcilePublishedMenu(local, conflicting),
      throwsFormatException,
    );
    expect(jsonEncode(local), previous);
  });

  test('background service updates SQLite only when actual data changes',
      () async {
    final folder = Directory.systemTemp.createTempSync('qr-sync-test-');
    final store = PosStore(databaseFile: '${folder.path}/nohut.sqlite3');
    addTearDown(() {
      store.dispose();
      folder.deleteSync(recursive: true);
    });
    final fixture = fixturePos();
    expect(store.replace(fixture, 0).ok, isTrue);
    final sync = QrMenuAutoSync(store, reader: mockReader());
    addTearDown(sync.dispose);

    final initial = store.read();
    await sync.syncNow();
    expect(sync.lastError, isNull);
    final changed = store.read();
    expect(changed.revision, initial.revision + 1);
    expect((changed.data['localMenu'] as List), hasLength(51));
    expect((changed.data['orders'] as List).first['payments'][0]['amount'], 140);
    await sync.syncNow();
    expect(store.read().revision, changed.revision);
  });

  test('disabled sync never fetches or modifies SQLite', () async {
    final folder = Directory.systemTemp.createTempSync('qr-sync-disabled-');
    final store = PosStore(databaseFile: '${folder.path}/nohut.sqlite3');
    addTearDown(() {
      store.dispose();
      folder.deleteSync(recursive: true);
    });
    final fixture = fixturePos();
    fixture['settings'] = {'qrAutoSync': false};
    expect(store.replace(fixture, 0).ok, isTrue);
    final before = store.read();
    final sync = QrMenuAutoSync(store, reader: mockReader(fail: true));
    addTearDown(sync.dispose);
    await sync.syncNow();
    expect(store.read().revision, before.revision);
    expect(sync.lastError, isNull);
    expect(sync.lastCheckedAtUtc, isNull);
  });

  test('offline failure retains old menu and reports error', () async {
    final folder = Directory.systemTemp.createTempSync('qr-sync-offline-');
    final store = PosStore(databaseFile: '${folder.path}/nohut.sqlite3');
    addTearDown(() {
      store.dispose();
      folder.deleteSync(recursive: true);
    });
    expect(store.replace(fixturePos(), 0).ok, isTrue);
    final before = store.read();
    final sync = QrMenuAutoSync(store, reader: mockReader(fail: true));
    addTearDown(sync.dispose);
    await sync.syncNow();
    expect(sync.lastError, isNotNull);
    expect(store.read().revision, before.revision);
    expect(jsonEncode(store.read().data), jsonEncode(before.data));
  });
}
