// Owner mandate 2026-11-27 §6: payment combinations in exact kuruş, with
// refusal paths. Pure domain rules shared by Windows, LAN and remote commands.
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/operations.dart';
import 'package:nohut_falafel_desktop/order_actions.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';

Json state() => {
  ...emptyPosState(),
  'settings': {'receiptPolicy': 'manual', 'printerName': 'fake', 'autoPrint': false},
  'localMenu': [{'id': 0, 'name': 'Test Dürüm', 'category': 'wrap', 'price': 100.01}],
};
Json line(int qty) => {'productId': 0, 'name': 'Test Dürüm', 'price': 100.01, 'qty': qty, 'note': '', 'removed': <String>[]};

void main() {
  test('partial cash with change, then Karma closes the exact remainder', () {
    final s = state();
    final o = newLocalOrder(state: s, source: 'Masa', table: 1, productLines: [line(2)]);
    expect(orderTotalCents(o), 20002);
    recordPayment(o, 5000, 'Nakit', receivedCents: 10000);
    final cash = (o['payments'] as List).last as Map;
    expect(cents(cash['change']), 5000);
    expect(orderDueCents(o), 15002);
    // Overpayment and short cash are refused; nothing is recorded.
    expect(() => recordPayment(o, 15003, 'Kart'), throwsFormatException);
    expect(() => recordPayment(o, 1000, 'Nakit', receivedCents: 999), throwsFormatException);
    expect((o['payments'] as List), hasLength(1));
    // Karma: an invalid split changes nothing (atomic trial copy).
    expect(() => recordMixedPayment(o, 15002, 15002), throwsFormatException);
    expect((o['payments'] as List), hasLength(1));
    recordMixedPayment(o, 15002, 7001, receivedCents: 8000);
    expect(orderDueCents(o), 0);
    expect(orderPaidCents(o), 20002);
    closeLocalOrder(o);
    expect(o['closed'], true);
    expect(() => recordPayment(o, 1, 'Kart'), throwsFormatException, reason: 'closed accounts take no money');
  });

  test('equal split of an odd kuruş total sums exactly, no lost or invented kuruş', () {
    final s = state();
    final o = newLocalOrder(state: s, source: 'Masa', table: 2, productLines: [line(1)]);
    splitEqually(o, 3); // 100,01 TL → 33,34 + 33,34 + 33,33
    final shares = [for (final g in asMaps(o['guestChecks']))
      asMaps(g['allocations']).fold<int>(0, (n, a) => n + (a['cents'] as int))];
    expect(shares, [3334, 3334, 3333]);
    expect(shares.reduce((a, b) => a + b), orderTotalCents(o));
  });

  test('refunds never exceed collections; cancel and close refuse open money', () {
    final s = state();
    final o = newLocalOrder(state: s, source: 'Masa', table: 3, productLines: [line(1)]);
    s['orders'] = [o];
    expect(() => closeLocalOrder(o), throwsFormatException, reason: 'unpaid balance');
    recordPayment(o, 10001, 'Kart');
    expect(() => refundPayment(o, 0, 10002, 'test'), throwsFormatException);
    expect(() => refundPayment(o, 0, 100, ''), throwsFormatException, reason: 'reason required');
    expect(() => cancelLocalOrder(s, o['id'] as int, 'müşteri vazgeçti'), throwsFormatException,
        reason: 'collected money must be refunded before cancelling');
    refundPayment(o, 0, 10001, 'müşteri vazgeçti');
    expect(orderPaidCents(o), 0);
    cancelLocalOrder(s, o['id'] as int, 'müşteri vazgeçti');
    expect(o['cancelled'], true);
    // The original payment and its refund both stay in history.
    final p = (o['payments'] as List).single as Map;
    expect(cents(p['amount']), 10001);
    expect(asMaps(p['refunds']).single['reason'], 'müşteri vazgeçti');
  });

  test('table transfer never merges into an occupied table', () {
    final s = state();
    final a = newLocalOrder(state: s, source: 'Masa', table: 4, productLines: [line(1)]);
    s['orders'] = [a];
    final b = newLocalOrder(state: s, source: 'Masa', table: 5, productLines: [line(1)]);
    (s['orders'] as List).add(b);
    expect(() => moveLocalTable(s, a, 5, 'test'), throwsFormatException);
    expect(a['table'], 4);
    moveLocalTable(s, a, 1, 'test');
    expect(a['table'], 1);
    expect((a['events'] as List).last, contains('Masa 4 → 1'));
  });
}
