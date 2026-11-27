// Phase 2 / PR-04 hardening (adds to sync_outbox_transaction_test.dart):
// phone path, failed command, soft delete, device settings, ACK watermark,
// canonical JSON and the legacy-database guard.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/staff_commands.dart';
import 'package:nohut_falafel_desktop/sync_outbox.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/synthetic_pos.dart';

Json line() => {'productId': 0, 'qty': 1, 'removed': <String>[], 'note': ''};

void main() {
  late Directory dir;
  late PosStore store;
  late Database probe;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('nohut-outbox');
    store = PosStore(databaseFile: '${dir.path}/db');
    probe = sqlite3.open('${dir.path}/db');
    final s = buildSyntheticState(40)
      ..['settings'] = {'autoPrint': true, 'printerName': 'fake'};
    expect(store.replace(s, store.read().revision).ok, true);
  });
  tearDown(() {
    probe.dispose();
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  test('disabled by default: nothing is recorded', () {
    final s = store.read().data
      ..['nextId'] = (store.read().data['nextId'] as int) + 1;
    store.replace(s, store.read().revision);
    expect(outboxEnabled(probe), false);
    expect(pendingOutbox(probe), isEmpty);
  });

  test('one changed order → exactly one projected, hashed event', () {
    enableOutbox(probe);
    final s = store.read().data;
    final order = asMaps(s['orders']).first;
    (s['orders'] as List).cast<Map>().first['serviceStatus'] = 'Hazır';
    store.replace(s, store.read().revision);
    final events = pendingOutbox(probe);
    expect(events, hasLength(1));
    final e = events.single;
    expect(e['entity_type'], 'orders');
    expect(e['entity_id'], '${order['id']}');
    expect(e['op'], 'upsert');
    expect(e['revision'], store.read().revision);
    final body = e['payload_json'] as String;
    expect(
      e['payload_sha256'],
      hash.sha256.convert(utf8.encode(body)).toString(),
    );
    final payload = jsonDecode(body) as Map;
    expect(payload['serviceStatus'], 'Hazır');
    expect(payload['id'], order['id']);
    // Contact data never enters the outbox.
    final customer = payload['customer'];
    if (customer is Map) {
      expect(customer.keys.toSet().difference({'id', 'time'}), isEmpty);
    }
    expect(
      '${e['event_id']}',
      endsWith(':${e['revision']}:orders:${order['id']}'),
    );
    expect(e['revision'], isNotNull);
  });

  test('phone order via staff command: events with the business change; a '
      'failed command records nothing', () {
    enableOutbox(probe);
    final s = store.read().data
      ..['employees'] = [
        {'id': 2, 'name': 'Mehmet', 'role': 'Personel', 'active': true},
      ];
    store.replace(s, store.read().revision);
    final before = pendingOutbox(probe).length;
    submitStaffOrder(store, {
      'requestId': 'staff_outbox_0001',
      'expectedRevision': store.read().revision,
      'staffId': 2,
      'source': 'Gel-Al',
      'pickupChannel': 'Telefon',
      'customer': {'name': 'Ayşe', 'phone': '05551234567', 'time': '13:15'},
      'lines': [line()],
    });
    final events = pendingOutbox(probe).skip(before).toList();
    // The order syncs; print jobs are not in the cloud allowlist yet
    // (receipt facts get their own typed table in PR-05).
    expect(events.map((e) => e['entity_type']).toSet(), {
      'orders',
      'printJobs',
    });
    final all = events.map((e) => e['payload_json']).join();
    expect(all, isNot(contains('05551234567')));
    expect(all, isNot(contains('Ayşe')));
    expect(all, contains('13:15'), reason: 'pickup time is allowed');
    final count = pendingOutbox(probe).length;
    expect(
      () => store.command('staff_outbox_fail', {'x': 1}, (s) {
        s['nextId'] = (s['nextId'] as int) + 5;
        throw const FormatException('stop');
      }),
      throwsFormatException,
    );
    expect(pendingOutbox(probe).length, count);
  });

  test('soft delete emits a delete and a tombstone; settings never sync', () {
    enableOutbox(probe);
    final id = asMaps(store.read().data['orders']).first['id'] as int;
    store.deleteOrder(
      id,
      store.read().revision,
      'delete_outbox_1',
      reason: 'Test',
    );
    final types = pendingOutbox(
      probe,
    ).map((e) => '${e['entity_type']}:${e['op']}').toList();
    expect(types, contains('orders:delete'));
    expect(types, contains('deletedOrders:upsert'));
    final before = pendingOutbox(probe).length;
    final s = store.read().data;
    (s['settings'] as Map)['printerName'] = 'Başka yazıcı';
    store.replace(s, store.read().revision);
    expect(
      pendingOutbox(probe).length,
      before,
      reason: 'device settings are not in the cloud allowlist',
    );
  });

  test('ACK is a contiguous watermark', () {
    enableOutbox(probe);
    for (var i = 0; i < 3; i++) {
      final s = store.read().data;
      (s['orders'] as List).cast<Map>()[i]['serviceStatus'] = 'Hazır';
      store.replace(s, store.read().revision);
    }
    final events = pendingOutbox(probe);
    expect(events, hasLength(3));
    ackOutboxThrough(probe, events[1]['seq'] as int, '2026-11-27T00:00:00Z');
    final left = pendingOutbox(probe);
    expect(left, hasLength(1));
    expect(left.single['seq'], events[2]['seq']);
  });

  test('canonical JSON sorts keys recursively', () {
    expect(
      canonicalJson({
        'b': 1,
        'a': {
          'd': 2,
          'c': [
            3,
            {'f': 1, 'e': 0},
          ],
        },
      }),
      '{"a":{"c":[3,{"e":0,"f":1}],"d":2},"b":1}',
    );
  });

  test(
    'the outbox cannot be enabled on a legacy (non-normalized) database',
    () {
      final legacy = sqlite3.open('${dir.path}/legacy.sqlite3');
      legacy.execute(
        'CREATE TABLE state_snapshot(id INTEGER PRIMARY KEY, '
        'revision INTEGER, payload TEXT, updated_at TEXT)',
      );
      createSyncTables(legacy);
      expect(() => enableOutbox(legacy), throwsFormatException);
      expect(outboxEnabled(legacy), false);
      legacy.dispose();
    },
  );
}
