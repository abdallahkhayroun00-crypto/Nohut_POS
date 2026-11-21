import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/group_payments.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';

Json makePickup(int id, int customerId, int centsTotal, {int paid = 0}) => {
  'id': id,
  'source': 'Gel-Al',
  'createdAt': DateTime.utc(2026, 11, 20, 11, id).toIso8601String(),
  'customer': {'id': customerId, 'name': 'Ahmet'},
  'closed': false,
  'serviceStatus': 'Hazırlanıyor',
  'payments': paid == 0 ? <dynamic>[] : <dynamic>[
    {'method': 'Nakit', 'amount': paid / 100}
  ],
  'events': <dynamic>[],
  'batches': <dynamic>[{
    'id': 1,
    'lines': <dynamic>[{
      'name': 'Falafel Dürüm', 'qty': 1, 'price': centsTotal / 100
    }],
  }],
};

void main() {
  test('one cash transaction settles two pickup orders without double charging', () {
    final state = emptyPosState();
    state['orders'] = [
      makePickup(1, 12, 18000),
      makePickup(2, 12, 32000),
    ];
    final slip = recordCombinedPickupPayment(
      state,
      orderIds: [1, 2],
      amountCents: 50000,
      method: 'Nakit',
      receivedCents: 60000,
      transactionId: 'group-1',
    );
    expect(slip, contains('TOPLU HESAP ÖZETİ'));
    expect(slip, contains('Para üstü 100,00'));
    final first = mutableOrder(state, 1)!;
    final second = mutableOrder(state, 2)!;
    expect(orderDueCents(first), 0);
    expect(orderDueCents(second), 0);
    expect(first['payments'], hasLength(1));
    expect(second['payments'], hasLength(1));
    expect((first['payments'] as List).first['combinedPaymentId'], 'group-1');
    expect((second['payments'] as List).first['combinedPaymentId'], 'group-1');
    expect((state['combinedPayments'] as List).length, 1);
    expect(() => recordCombinedPickupPayment(
      state,
      orderIds: [1, 2],
      amountCents: 50000,
      method: 'Nakit',
      receivedCents: 60000,
      transactionId: 'group-1',
    ), throwsFormatException);
  });

  test('mixed payment is correctly allocated across two orders', () {
    final state = emptyPosState();
    state['orders'] = [
      makePickup(1, 12, 18000, paid: 3000), // due 150 TL
      makePickup(2, 12, 20000), // due 200 TL
    ];
    recordCombinedPickupPayment(
      state,
      orderIds: [1, 2],
      amountCents: 35000,
      method: 'Karışık',
      cashCents: 22000,
      receivedCents: 25000,
    );
    expect(orderDueCents(mutableOrder(state, 1)!), 0);
    expect(orderDueCents(mutableOrder(state, 2)!), 0);
    final methods = [
      for (final o in state['orders'] as List)
        for (final p in (o['payments'] as List)) p['method'],
    ];
    expect(methods, contains('Kart'));
    expect(methods, contains('Nakit'));
    final history = (state['combinedPayments'] as List).single as Map;
    expect(history['cash'], 220);
    expect(history['card'], 130);
  });

  test('rejects cross-customer and duplicate order ids before charging', () {
    final state = emptyPosState();
    state['orders'] = [
      makePickup(1, 12, 10000),
      makePickup(2, 13, 15000),
    ];
    expect(() => recordCombinedPickupPayment(
      state,
      orderIds: [1, 2],
      amountCents: 25000,
      method: 'Kart',
    ), throwsFormatException);
    expect(() => recordCombinedPickupPayment(
      state,
      orderIds: [1, 1],
      amountCents: 20000,
      method: 'Kart',
    ), throwsFormatException);
    expect((mutableOrder(state, 1)!['payments'] as List), isEmpty);
    expect((mutableOrder(state, 2)!['payments'] as List), isEmpty);
  });


  test('combined payment settles split guest and unsplit Gel-Al together', () {
    final state = emptyPosState();
    final split = makePickup(1, 12, 18000);
    split['guestChecks'] = [
      {'id': 1, 'name': 'Ali', 'allocations': [
        {'key': '1:0', 'cents': 9000},
      ]},
      {'id': 2, 'name': 'Ayşe', 'allocations': [
        {'key': '1:0', 'cents': 9000},
      ]},
    ];
    state['orders'] = [split, makePickup(2, 12, 10000)];
    recordCombinedPickupPayment(state,
      orderIds: [1, 2], amountCents: 28000, method: 'Kart',
      transactionId: 'split-together');
    expect(orderDueCents(mutableOrder(state, 1)!), 0);
    expect(orderDueCents(mutableOrder(state, 2)!), 0);
    final payments = mutableOrder(state, 1)!['payments'] as List;
    expect(payments, hasLength(2));
    expect(payments.map((p) => p['guestCheckId']).toSet(), {1, 2});
    expect(payments.every((p) =>
      p['combinedPaymentId'] == 'split-together'), true);
  });

  test('product-partial payment can group settle only outstanding remainder', () {
    final state = emptyPosState();
    final partial = makePickup(1, 12, 18000);
    partial['guestChecks'] = [
      {'id': 1, 'name': 'Ürün ödemesi', 'allocations': [
        {'key': '1:0', 'cents': 6000},
      ]},
    ];
    partial['payments'] = [{
      'method': 'Nakit', 'amount': 60.0,
      'guestCheckId': 1, 'reversed': false,
    }];
    state['orders'] = [partial, makePickup(2, 12, 10000)];
    recordCombinedPickupPayment(state,
      orderIds: [1, 2], amountCents: 22000,
      method: 'Karışık', cashCents: 9000,
      receivedCents: 11000, transactionId: 'partial-group');
    expect(orderDueCents(mutableOrder(state, 1)!), 0);
    expect(orderDueCents(mutableOrder(state, 2)!), 0);
    final guests = mutableOrder(state, 1)!['guestChecks'] as List;
    expect(guests, hasLength(2));
    expect(guests.last['name'], 'Kalan hesap');
    expect(orderPaidCents(mutableOrder(state, 1)!), 18000);
    expect((state['combinedPayments'] as List).single['id'], 'partial-group');
  });

  test('inconsistent old split payment aborts group transaction atomically', () {
    final state = emptyPosState();
    final split = makePickup(1, 12, 10000, paid: 1000);
    split['guestChecks'] = [
      {'id': 1, 'name': 'Unmatched', 'allocations': [
        {'key': '1:0', 'cents': 10000},
      ]},
    ];
    state['orders'] = [split, makePickup(2, 12, 10000)];
    expect(() => recordCombinedPickupPayment(state,
      orderIds: [1, 2], amountCents: 19000,
      method: 'Nakit', receivedCents: 20000,
    ), throwsFormatException);
    expect((mutableOrder(state, 1)!['payments'] as List), hasLength(1));
    expect((mutableOrder(state, 2)!['payments'] as List), isEmpty);
    // Atomic failure must not create a combined transaction entry.
    // Legacy seed states may omit the key until first successful payment.
    expect(asMaps(state['combinedPayments']), isEmpty);
  });

  test('empty pre-existing guest allocation is safely assigned and settled', () {
    final state = emptyPosState();
    final split = makePickup(1, 12, 10000);
    split['guestChecks'] = [
      {'id': 1, 'name': 'Empty', 'allocations': []},
    ];
    state['orders'] = [split, makePickup(2, 12, 10000)];
    recordCombinedPickupPayment(state,
      orderIds: [1, 2], amountCents: 20000,
      method: 'Nakit', receivedCents: 20000);
    expect(orderDueCents(mutableOrder(state, 1)!), 0);
    expect(orderDueCents(mutableOrder(state, 2)!), 0);
  });
}
