// Phase 1B / owner decision 2: audited soft deletion. Nothing is erased;
// reports behave exactly as before (the order leaves `orders`), the archive
// keeps the full record, related rows and the audit, idempotency holds.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/order_reporting.dart';
import 'package:nohut_falafel_desktop/overview_metrics.dart';
import 'package:nohut_falafel_desktop/operations.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/staff_commands.dart';
import 'package:nohut_falafel_desktop/sync_field_registry.dart';

Json state() => {
  ...emptyPosState(),
  'localMenu': [
    {'id': 0, 'name': 'Falafel', 'category': 'wrap', 'price': 140},
  ],
  'settings': {'autoPrint': true, 'printerName': 'fake'},
};

Json line() => {'productId': 0, 'qty': 1, 'removed': <String>[], 'note': ''};

void main() {
  late Directory dir;
  late PosStore store;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('nohut-softdel');
    store = PosStore(databaseFile: '${dir.path}/db');
    expect(store.replace(state(), store.read().revision).ok, true);
  });
  tearDown(() {
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  int sumPaid(Json s) =>
      asMaps(s['orders']).fold(0, (n, o) => n + orderPaidCents(o));

  test('soft delete archives the full order with audit and related rows',
      () {
    // Two phone orders through the real staff command path.
    for (final (id, table) in [('staff_sd_0001', 1), ('staff_sd_0002', 2)]) {
      submitStaffOrder(store, {
        'requestId': id,
        'expectedRevision': store.read().revision,
        'staffId': 2,
        'source': 'Masa',
        'table': table,
        'lines': [line()],
      });
    }
    // Pay the first one.
    final paid = store.read().data;
    recordPayment(mutableOrder(paid, 1200)!, 14000, 'Kart');
    store.replace(paid, store.read().revision);
    final before = store.read().data;
    final victim = Map<String, dynamic>.from(mutableOrder(before, 1200)!);
    final jobs = asMaps(before['printJobs'])
        .where((j) => j['orderId'] == 1200).toList();
    expect(jobs, isNotEmpty);

    submitStaffAction(store, {
      'requestId': 'staff_sd_del1',
      'action': 'delete',
      'orderId': 1200,
      'expectedRevision': store.read().revision,
      'staffId': 2,
      'confirmed': true,
      'reason': 'Yanlış masa girildi',
    });

    final after = store.read().data;
    // Live lists: the order and its related rows are gone, exactly as the
    // old hard delete behaved, so every report keeps its meaning.
    expect(mutableOrder(after, 1200), isNull);
    expect(asMaps(after['printJobs']).where((j) => j['orderId'] == 1200),
        isEmpty);
    expect(activeTable(after, 1), isNull, reason: 'table freed');
    expect(sumPaid(after), sumPaid(before) - 14000);
    expect(mutableOrder(after, 1201), isNotNull);
    // Archive: nothing lost.
    final archived = asMaps(after['deletedOrders']).single;
    expect(archived['orderId'], 1200);
    expect(archived['order'], victim);
    expect(orderPaidCents(archived['order'] as Json), 14000);
    expect(asMaps((archived['related'] as Map)['printJobs']), jobs);
    expect(archived['deletedBy'], 'Mehmet');
    expect(archived['deletedByStaffId'], 2);
    expect(archived['reason'], 'Yanlış masa girildi');
    expect(archived['requestId'], 'staff_sd_del1');
    expect(DateTime.tryParse('${archived['deletedAt']}'), isNotNull);
    // Field registry and validation accept the archive; ids never reused.
    expect(unregisteredFieldPaths(after), isEmpty);
    expect(after['nextId'], greaterThan(1201));
    final next = newLocalOrder(state: after, source: 'Masa', table: 3,
        productLines: [{...line(), 'name': 'Falafel', 'price': 140}]);
    expect(next['id'], isNot(1200));
  });

  test('idempotency survives: replays never re-create the deleted order',
      () {
    final payload = {
      'requestId': 'staff_sd_0003',
      'expectedRevision': store.read().revision,
      'staffId': 2,
      'source': 'Masa',
      'table': 1,
      'lines': [line()],
    };
    submitStaffOrder(store, payload);
    store.deleteOrder(1200, store.read().revision, 'delete_sd_0001',
        reason: 'Test');
    // Same create request again: refused with a clear message.
    expect(() => submitStaffOrder(store, payload), throwsFormatException);
    expect(store.read().data['orders'], isEmpty);
    // Same delete request again: no-op success.
    expect(store.deleteOrder(1200, 0, 'delete_sd_0001')['ok'], true);
    expect(asMaps(store.read().data['deletedOrders']), hasLength(1));
  });

  test('dashboard totals exclude deleted orders; cancelled stay as before',
      () {
    final s = store.read().data;
    final a = newLocalOrder(state: s, source: 'Gel-Al',
        productLines: [{...line(), 'name': 'Falafel', 'price': 140}]);
    recordPayment(a, 14000, 'Nakit', receivedCents: 14000);
    final b = newLocalOrder(state: s, source: 'Gel-Al',
        productLines: [{...line(), 'name': 'Falafel', 'price': 140}]);
    recordPayment(b, 14000, 'Kart');
    final c = newLocalOrder(state: s, source: 'Masa', table: 4,
        productLines: [{...line(), 'name': 'Falafel', 'price': 140}]);
    cancelLocalOrder(s, c['id'] as int, 'Müşteri vazgeçti');
    store.replace(s, store.read().revision);
    final day = istanbulDay(DateTime.now().toUtc());
    final before = daySales(store.read().data, day);
    expect(before.orders, 2, reason: 'cancelled order is not a sale');
    store.deleteOrder(b['id'] as int, store.read().revision,
        'delete_sd_0002', reason: 'Çift kayıt');
    final data = store.read().data;
    final after = daySales(data, day);
    expect(after.orders, 1);
    expect(after.revenueCents, before.revenueCents - 14000);
    // The cancelled order is still a cancelled order, not deleted.
    expect(mutableOrder(data, c['id'] as int)!['cancelled'], true);
    expect(asMaps(data['deletedOrders']).single['orderId'], b['id']);
    // Cloud projection keeps the tombstone without contact data.
    final projected = projectForCloud(data);
    final tomb = asMaps(projected['deletedOrders']).single;
    expect(tomb['orderId'], b['id']);
    expect(tomb['reason'], 'Çift kayıt');
    expect((tomb['order'] as Map)['payments'], isNotEmpty);
  });
}
