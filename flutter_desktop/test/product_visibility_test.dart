import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/qr_menu_sync.dart';
import 'package:nohut_falafel_desktop/staff_commands.dart';

import 'qr_catalog_fixtures.dart';

String pricesWithSambaliVisible(bool visible) {
  final cms = jsonDecode(QrCatalogFixture.priceJson()) as Map;
  final dessert = (cms['dessert'] as List).cast<Map>();
  final item = dessert.singleWhere((p) => p['name'] == 'Şambali Tatlısı');
  item['active'] = visible;
  return jsonEncode(cms);
}

void main() {
  test('live CMS false hides Şambali, retaining ID, price and past orders', () async {
    final state = QrCatalogFixture.localState();
    final orders = jsonEncode(state['orders']);
    final feed = await QrCatalogFixture.reader(
      pricesOverride: pricesWithSambaliVisible(false),
    ).readPublishedMenu();
    expect(feed.products.singleWhere((p) => p.id == 32).active, false);
    expect(feed.products.singleWhere((p) => p.id == 52).active, true);

    final result = reconcilePublishedMenu(state, feed);
    expect(result.changed, true);
    final sambali = (state['localMenu'] as List)
        .cast<Map>().singleWhere((p) => p['id'] == 32);
    expect(sambali['name'], 'Şambali Tatlısı');
    expect(sambali['price'], isA<num>());
    expect(sambali['active'], false);
    expect((state['localMenu'] as List).length, 53);
    expect(jsonEncode(state['orders']), orders);
    final noOp = reconcilePublishedMenu(state, feed);
    expect(noOp.changed, false);
  });

  test('CMS reactivation restores the same original ID without new product', () async {
    final state = QrCatalogFixture.localState();
    final hidden = await QrCatalogFixture.reader(
      pricesOverride: pricesWithSambaliVisible(false),
    ).readPublishedMenu();
    final visible = await QrCatalogFixture.reader(
      pricesOverride: pricesWithSambaliVisible(true),
    ).readPublishedMenu();
    reconcilePublishedMenu(state, hidden);
    final result = reconcilePublishedMenu(state, visible);
    expect(result.changed, true);
    expect(result.added, 0);
    final item = (state['localMenu'] as List)
        .cast<Map>().singleWhere((p) => p['id'] == 32);
    expect(item['active'], true);
    expect(item['name'], 'Şambali Tatlısı');
  });

  test('staff API rejects ordering hidden product even with stale phone menu',
      () async {
    final dir = Directory.systemTemp.createTempSync('hidden-pos-product-');
    final store = PosStore(databaseFile: '${dir.path}/nohut.sqlite3');
    addTearDown(() {
      store.dispose();
      dir.deleteSync(recursive: true);
    });
    final state = QrCatalogFixture.localState();
    state['employees'] = [
      {'id': 1, 'name': 'Test worker', 'active': true},
    ];
    final hidden = await QrCatalogFixture.reader(
      pricesOverride: pricesWithSambaliVisible(false),
    ).readPublishedMenu();
    reconcilePublishedMenu(state, hidden);
    expect(store.replace(state, 0).ok, true);
    final before = store.read();
    expect(
      () => submitStaffOrder(store, {
        'requestId': 'hidden-product-001',
        'expectedRevision': before.revision,
        'staffId': 1,
        'source': 'Gel-Al',
        'lines': [
          {'productId': 32, 'qty': 1, 'removed': <String>[], 'note': ''},
        ],
      }),
      throwsFormatException,
    );
    expect(store.read().revision, before.revision);
    expect(jsonEncode(store.read().data['orders']),
        jsonEncode(before.data['orders']));
  });

  test('cashier cannot submit a hidden product using a stale order window',
      () async {
    final state = QrCatalogFixture.localState();
    final hidden = await QrCatalogFixture.reader(
      pricesOverride: pricesWithSambaliVisible(false),
    ).readPublishedMenu();
    reconcilePublishedMenu(state, hidden);
    final orderCount = (state['orders'] as List).length;
    final line = <String, dynamic>{
      'productId': 32,
      'productKey': 'Şambali Tatlısı',
      'name': 'Şambali Tatlısı',
      'price': 70,
      'qty': 1,
      'removed': <String>[],
      'note': '',
    };
    expect(
      () => newLocalOrder(
        state: state, source: 'Gel-Al', productLines: [line],
      ),
      throwsFormatException,
    );
    expect((state['orders'] as List).length, orderCount);
    final visible = await QrCatalogFixture.reader(
      pricesOverride: pricesWithSambaliVisible(true),
    ).readPublishedMenu();
    reconcilePublishedMenu(state, visible);
    // SQLite state is decoded as dynamic JSON before the real cashier writes.
    final activated = copyJson(state);
    expect(newLocalOrder(
      state: activated, source: 'Gel-Al', productLines: [line],
    )['id'], isA<int>());
  });

  test('malformed visibility value fails closed before SQLite sync', () async {
    final cms = jsonDecode(QrCatalogFixture.priceJson()) as Map;
    final item = (cms['dessert'] as List)
        .cast<Map>().singleWhere((p) => p['name'] == 'Şambali Tatlısı');
    item['active'] = 'false';
    await expectLater(
      QrCatalogFixture.reader(
        pricesOverride: jsonEncode(cms),
      ).readPublishedMenu(),
      throwsFormatException,
    );
  });
}
