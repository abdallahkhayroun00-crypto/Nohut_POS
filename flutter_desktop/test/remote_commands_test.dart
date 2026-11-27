// Phase 5: remote commands executed by the Windows authority (spec §11.2,
// §20.3, §22.3). Synthetic data only.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/permission_catalogue.g.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/remote_commands.dart';

Json state() => {
  ...emptyPosState(),
  'localMenu': [
    {'id': 0, 'name': 'Falafel', 'category': 'wrap', 'price': 140},
  ],
  'settings': {'autoPrint': false},
};

final t0 = DateTime.utc(2026, 11, 27, 12);

Map<String, dynamic> envelope(
  String type,
  Map<String, dynamic> payload, {
  String id = 'cmd_00000001',
  String client = 'personel',
  int employeeId = 2,
  bool owner = false,
  List<String> grants = const ['orders.create', 'payments.take', 'orders.move', 'orders.release'],
  DateTime? issued,
  Duration ttl = const Duration(minutes: 10),
  String? hash,
}) {
  final at = issued ?? t0;
  return {
    'request_id': id,
    'action_type': type,
    'client': client,
    'actor': {'employee_id': employeeId, 'is_owner': owner, 'grants': grants, 'permission_version': 1},
    'issued_at': at.toIso8601String(),
    'expires_at': at.add(ttl).toIso8601String(),
    'payload': payload,
    'payload_sha256': hash ?? payloadSha256(payload),
  };
}

void main() {
  late Directory dir;
  late PosStore store;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('nohut-remote');
    store = PosStore(databaseFile: '${dir.path}/db');
    expect(store.replace(state(), store.read().revision).ok, true);
  });
  tearDown(() {
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  Map<String, dynamic> newOrder({int table = 1}) => {
    'expectedRevision': store.read().revision,
    'source': 'Masa',
    'table': table,
    'lines': [
      {'productId': 0, 'qty': 2, 'removed': <String>[], 'note': '', 'expectedPriceCents': 14000},
    ],
  };

  RemoteCommandResult run(Map<String, dynamic> e, {DateTime? now}) =>
      executeRemoteCommand(store, e, now: now ?? t0.add(const Duration(seconds: 5)));

  test('a permitted order is executed by the same handler and confirmed', () {
    final r = run(envelope('create_order', newOrder()));
    expect(r.outcome, CommandOutcome.confirmed);
    final orders = asMaps(store.read().data['orders']);
    expect(orders, hasLength(1));
    expect(orders.single['table'], 1);
    expect(orderTotalCents(orders.single), 28000);
  });

  test('the acting employee comes from the envelope, not the payload', () {
    final p = newOrder()..['staffId'] = 999;
    final r = run(envelope('create_order', p, employeeId: 2));
    expect(r.outcome, CommandOutcome.confirmed);
    final batch = asMaps(asMaps(store.read().data['orders']).single['batches']).first;
    final staff = asMaps(store.read().data['employees']).firstWhere((e) => e['id'] == 2);
    expect(jsonEncode(batch), contains('${staff['name']}'));
  });

  test('retrying the same request returns the stored receipt, no second order', () {
    final e = envelope('create_order', newOrder());
    expect(run(e).outcome, CommandOutcome.confirmed);
    final again = run(e);
    expect(again.outcome, CommandOutcome.confirmed);
    expect(asMaps(store.read().data['orders']), hasLength(1));
  });

  test('same request id with a different payload is refused', () {
    expect(run(envelope('create_order', newOrder(table: 1))).outcome, CommandOutcome.confirmed);
    final r = run(envelope('create_order', newOrder(table: 2)));
    expect(r.outcome, CommandOutcome.rejected);
    expect(r.code, 'idempotency_payload_mismatch');
    expect(asMaps(store.read().data['orders']), hasLength(1));
  });

  test('lost ACK after restart and expiry returns the committed receipt', () {
    final e = envelope('create_order', newOrder());
    final first = run(e);
    expect(first.outcome, CommandOutcome.confirmed);
    store.dispose();
    store = PosStore(databaseFile: '${dir.path}/db');
    final retry = run(e, now: t0.add(const Duration(hours: 1)));
    expect(retry.outcome, CommandOutcome.confirmed);
    expect(retry.result, first.result);
    expect(asMaps(store.read().data['orders']), hasLength(1));
  });

  test('a cached receipt cannot be reused with another action or actor', () {
    final e = envelope('create_order', newOrder());
    expect(run(e).outcome, CommandOutcome.confirmed);
    expect(run({...e, 'actor': {...e['actor'] as Map, 'employee_id': 3}}).code,
        'idempotency_payload_mismatch');
    expect(run({...e, 'authority_epoch': 'different'}).code,
        'idempotency_payload_mismatch');
  });

  test('authorization is checked before returning a committed receipt', () {
    final e = envelope('create_order', newOrder());
    expect(run(e).outcome, CommandOutcome.confirmed);
    expect(run({...e, 'actor': {...e['actor'] as Map, 'grants': <String>[]}}).code, 'forbidden');
  });

  test('failed business transaction does not leave a remote receipt', () {
    final e = envelope('create_order', newOrder()..['expectedRevision'] = -1);
    expect(run(e).outcome, CommandOutcome.conflict);
    expect(store.remoteCommandReceipt('${e['request_id']}', envelopeSha256(e)), isNull);
  });

  test('Windows-only operations are refused for every remote client, even the owner', () {
    for (final type in ['sync_manual', 'backup_manual', 'restore_request', 'first_sync', 'full_resync']) {
      for (final client in ['personel', 'yonetici']) {
        final r = run(envelope(type, {'x': 1}, client: client, owner: true, grants: permissionCatalogue.keys.toList()));
        expect(r.code, 'windows_only', reason: '$type/$client');
      }
    }
    for (final entry in permissionCatalogue.entries.where((e) => e.value.section == 'sync' || e.value.section == 'backup')) {
      expect(entry.value.clients, ['windows'], reason: entry.key);
    }
  });

  test('missing grant is forbidden; nothing changes', () {
    final r = run(envelope('create_order', newOrder(), grants: const []));
    expect(r.code, 'forbidden');
    expect(asMaps(store.read().data['orders']), isEmpty);
  });

  test('unknown action types fail closed', () {
    expect(run(envelope('delete_everything', {})).code, 'unknown_action');
  });

  test('tampered payload is refused', () {
    final r = run(envelope('create_order', newOrder(), hash: 'deadbeef'));
    expect(r.code, 'payload_hash_mismatch');
    expect(asMaps(store.read().data['orders']), isEmpty);
  });

  test('expired commands never run (server expiry and local TTL)', () {
    final late = run(envelope('create_order', newOrder()), now: t0.add(const Duration(minutes: 11)));
    expect(late.outcome, CommandOutcome.expired);
    // Server gave a long expiry but the payment TTL is 15 minutes.
    final pay = envelope('record_payment', {'action': 'pay', 'orderId': 1, 'method': 'Nakit', 'amountCents': 100, 'confirmed': true, 'printReceipt': false, 'expectedRevision': 1},
        ttl: const Duration(hours: 3));
    expect(run(pay, now: t0.add(const Duration(minutes: 20))).outcome, CommandOutcome.expired);
    expect(asMaps(store.read().data['orders']), isEmpty);
  });

  test('inactive or unknown employees cannot act', () {
    expect(run(envelope('create_order', newOrder(), employeeId: 4242)).code, 'actor_inactive');
  });

  test('action type and payload must agree', () {
    expect(run(envelope('record_payment', {'action': 'close', 'orderId': 1})).code, 'action_mismatch');
    expect(run(envelope('add_order_items', newOrder())).code, 'action_mismatch');
  });

  test('payment through a remote command updates the Windows balance', () {
    expect(run(envelope('create_order', newOrder())).outcome, CommandOutcome.confirmed);
    final order = asMaps(store.read().data['orders']).single;
    final pay = {
      'action': 'pay',
      'orderId': order['id'],
      'method': 'Nakit',
      'amountCents': 28000,
      'receivedCents': 30000,
      'confirmed': true,
      'printReceipt': false,
      'expectedRevision': store.read().revision,
    };
    final r = run(envelope('record_payment', pay, id: 'cmd_pay_0001'));
    expect(r.outcome, CommandOutcome.confirmed, reason: r.result.toString());
    expect(orderDueCents(asMaps(store.read().data['orders']).single), 0);
  });

  test('stale expected revision is a conflict, not a silent overwrite', () {
    final p = newOrder()..['expectedRevision'] = store.read().revision - 1;
    final r = run(envelope('create_order', p));
    expect(r.outcome, CommandOutcome.conflict);
  });

  test('client must be allowed for the operation', () {
    expect(run(envelope('create_order', newOrder(), client: 'windows')).outcome, CommandOutcome.rejected);
    expect(run(envelope('create_order', newOrder(), client: 'unknown')).outcome, CommandOutcome.rejected);
  });

  test('canonical hashing ignores key order', () {
    expect(payloadSha256({'b': 1, 'a': [{'y': 2, 'x': 1}]}), payloadSha256({'a': [{'x': 1, 'y': 2}], 'b': 1}));
  });

  group('worker', () {
    test('reports only after commit; a lost acknowledgement is safe', () async {
      final t = _FakeTransport([envelope('create_order', newOrder())]);
      final w = RemoteCommandWorker(store, t, clock: () => t0.add(const Duration(seconds: 1)));
      t.failComplete = true;
      await w.runOnce();
      expect(w.lastError, isNotNull);
      expect(asMaps(store.read().data['orders']), hasLength(1)); // committed
      t.failComplete = false; // lease expired → re-claimed
      expect(await w.runOnce(), 1);
      expect(t.completed.single['state'], 'confirmed');
      expect(asMaps(store.read().data['orders']), hasLength(1)); // not twice
    });
  });
}

class _FakeTransport implements CommandTransport {
  _FakeTransport(this.queue);
  final List<Map<String, dynamic>> queue;
  final completed = <Map<String, dynamic>>[];
  bool failComplete = false;

  @override
  Future<List<Map<String, dynamic>>> claim({required int max}) async => queue.take(max).toList();

  @override
  Future<void> complete(String requestId, Map<String, dynamic> result) async {
    if (failComplete) throw const SocketException('offline');
    queue.removeWhere((e) => e['request_id'] == requestId);
    completed.add(result);
  }
}
