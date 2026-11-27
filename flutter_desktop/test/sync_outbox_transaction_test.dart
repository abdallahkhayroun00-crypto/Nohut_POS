import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/sync_outbox.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory dir;
  late PosStore store;
  late Database probe;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nohut-outbox');
    final path = '${dir.path}/db.sqlite3';
    store = PosStore(databaseFile: path);
    probe = sqlite3.open(path);
    final snap = store.read();
    snap.data['localMenu'] = [
      {'id': 0, 'name': 'Falafel', 'category': 'wrap', 'price': 140},
    ];
    expect(store.replace(snap.data, snap.revision).ok, true);
  });
  tearDown(() {
    probe.dispose();
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  Json addPickup(Json data) => newLocalOrder(
    state: data,
    source: 'Gel-Al',
    pickupChannel: 'Telefon',
    customer: {
      'name': 'Synthetic Customer',
      'phone': '05550001122',
      'time': '18:30',
    },
    productLines: [
      {'productId': 0, 'name': 'Falafel', 'qty': 1, 'price': 140,
       'removed': <String>[], 'note': ''},
    ],
  );

  test('recording defaults to disabled and no network is involved', () {
    expect(outboxEnabled(probe), false);
    final snap = store.read();
    addPickup(snap.data);
    expect(store.replace(snap.data, snap.revision).ok, true);
    expect(pendingOutbox(probe), isEmpty);
  });

  test('replace records projected order, not contact fields or print jobs', () {
    enableOutbox(probe);
    final snap = store.read();
    final order = addPickup(snap.data);
    expect(store.replace(snap.data, snap.revision).ok, true);
    final events = pendingOutbox(probe);
    final event = events.singleWhere((e) => e['entity_type'] == 'orders');
    expect(event['entity_id'], '${order['id']}');
    expect(event['revision'], snap.revision + 1);
    expect(event['op'], 'upsert');
    final payload = jsonDecode(event['payload_json'] as String) as Map;
    expect(payload['id'], order['id']);
    final customer = payload['customer'] as Map;
    expect(customer['time'], '18:30');
    expect(customer.containsKey('name'), false);
    expect(customer.containsKey('phone'), false);
    expect(jsonEncode(events), isNot(contains('05550001122')));
    expect(events.any((e) => e['entity_type'] == 'printJobs'), false);

    final current = store.read();
    final mutable = mutableOrder(current.data, order['id'] as int)!;
    (mutable['customer'] as Map)['phone'] = '05550009988';
    expect(store.replace(current.data, current.revision).ok, true);
    expect(pendingOutbox(probe), hasLength(events.length));
  });

  test('command retries and stale revisions do not duplicate events', () {
    enableOutbox(probe);
    final first = store.read();
    final result = store.command('outbox_test_001', {'kind': 'test'}, (data) {
      final order = addPickup(data);
      return {'orderId': order['id']};
    });
    final count = pendingOutbox(probe).length;
    expect(count, greaterThan(0));
    expect(store.command('outbox_test_001', {'kind': 'test'}, (_) {
      throw StateError('replay must not execute');
    }), result);
    expect(store.replace(first.data, first.revision).ok, false);
    expect(pendingOutbox(probe), hasLength(count));
  });

  test('soft deletion records a tombstone and removes the active projection', () {
    enableOutbox(probe);
    final snap = store.read();
    final order = addPickup(snap.data);
    final id = order['id'] as int;
    expect(store.replace(snap.data, snap.revision).ok, true);
    final revision = store.read().revision;
    store.deleteOrder(id, revision, 'outbox_delete_001', reason: 'Test');
    final events = pendingOutbox(probe)
        .where((e) => e['revision'] == revision + 1).toList();
    expect(events.any((e) => e['entity_type'] == 'orders' && e['op'] == 'delete'), true);
    final archived = events.singleWhere((e) => e['entity_type'] == 'deletedOrders');
    expect(archived['op'], 'upsert');
    expect(archived['payload_json'], isNot(contains('05550001122')));
    expect(archived['payload_json'], isNot(contains('Synthetic Customer')));
    expect(mutableOrder(store.read().data, id), isNull);
  });

  test('outbox insert failure rolls back business rows and revision', () {
    enableOutbox(probe);
    probe.execute("CREATE TRIGGER block_sync BEFORE INSERT ON sync_outbox "
        "BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END");
    final before = store.read();
    final next = copyJson(before.data);
    addPickup(next);
    expect(() => store.replace(next, before.revision), throwsA(isA<SqliteException>()));
    expect(store.read().revision, before.revision);
    expect(store.read().data, before.data);
    expect(pendingOutbox(probe), isEmpty);
    probe.execute('DROP TRIGGER block_sync');
    expect(store.replace(next, before.revision).ok, true);
    expect(pendingOutbox(probe), isNotEmpty);
  });
}
