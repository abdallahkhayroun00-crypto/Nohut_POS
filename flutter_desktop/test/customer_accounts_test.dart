import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/customer_accounts.dart';
import 'package:nohut_falafel_desktop/operations.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';

Json order(int id, Json customer, int total, int paid) => {
  'id': id,
  'source': 'Gel-Al',
  'createdAt': DateTime.utc(2026, 11, 19, id).toIso8601String(),
  'customer': customer,
  'closed': false,
  'events': <dynamic>[],
  'batches': [{
    'id': 1,
    'lines': [{'name': 'Falafel Dürüm', 'qty': 1, 'price': total / 100}],
  }],
  'payments': paid == 0 ? <dynamic>[] : [
    {'method': 'Nakit', 'amount': paid / 100},
  ],
};

void main() {
  test('saved customer reuses the same ID when phone matches', () {
    final state = emptyPosState();
    final first = savePickupCustomer(state, name: 'Ahmet', phone: '0500 123 4567');
    final again = savePickupCustomer(state, name: 'Ahmet Y.', phone: '0500-123-4567');
    expect(again, first);
    expect(savedCustomers(state), hasLength(1));
  });

  test('different phones do not merge identical customer names', () {
    final state = emptyPosState();
    final a = savePickupCustomer(state, name: 'Ahmet', phone: '05001234567');
    final b = savePickupCustomer(state, name: 'Ahmet', phone: '05009998877');
    expect(a, isNot(b));
    expect(savedCustomers(state), hasLength(2));
  });

  test('two unpaid and partially paid pickup orders aggregate accurately', () {
    final state = emptyPosState();
    final id = savePickupCustomer(state, name: 'Ahmet', phone: '05001234567');
    state['orders'] = [
      order(1, {'id': id, 'name': 'Ahmet'}, 18000, 5000),
      order(2, {'id': id, 'name': 'Ahmet'}, 22000, 0),
      order(3, {'id': id, 'name': 'Ahmet'}, 5000, 5000),
    ];
    final accounts = pickupOpenAccounts(state);
    expect(accounts, hasLength(1));
    expect(accounts.single.orders, hasLength(2));
    expect(accounts.single.dueCents, 35000);
    // After payment the balance comes from the same persisted order.
    (state['orders'] as List)[1]['payments'].add({
      'method': 'Kart', 'amount': 220,
    });
    expect(pickupOpenAccounts(state).single.dueCents, 13000);
  });

  test('anonymous name-only debt is not merged with a namesake', () {
    final state = emptyPosState();
    state['orders'] = [
      order(1, {'name': 'Ahmet'}, 14000, 0),
      order(2, {'name': 'Ahmet'}, 14000, 0),
    ];
    final accounts = pickupOpenAccounts(state);
    expect(accounts, hasLength(2));
    expect(accounts.map((a) => a.dueCents).toList(), [14000, 14000]);
  });

  test('linked pickup customer omits temporary UI save flag', () {
    final state = emptyPosState();
    final linked = linkedPickupCustomer(state, {
      'name': 'Ayşe',
      'phone': '05330000000',
      'time': '16:30',
      'saveCustomer': true,
    });
    expect(linked['id'], isA<int>());
    expect(linked.containsKey('saveCustomer'), false);
    expect(savedCustomers(state), hasLength(1));
  });
  test('old Gel-Al order links to an existing customer without changing money', () {
    final state = emptyPosState();
    final id = savePickupCustomer(
      state, name: 'Ayşe', phone: '05330000000');
    final first = order(1, {'name': 'Eski kayıt', 'phone': ''}, 18000, 5000);
    final second = order(2, {'id': id, 'name': 'Ayşe'}, 20000, 0);
    state['orders'] = [first, second];
    final createdAt = first['createdAt'];
    expect(pickupOpenAccounts(state), hasLength(2));
    linkLegacyPickupOrder(
      state, orderId: 1, existingCustomerId: id);
    final attached = mutableOrder(state, 1)!;
    expect((attached['customer'] as Map)['id'], id);
    expect(attached['createdAt'], createdAt);
    expect(orderDueCents(attached), 13000);
    expect(orderPaidCents(attached), 5000);
    expect(asMaps(attached['customerLinkHistory']), hasLength(1));
    final accounts = pickupOpenAccounts(state);
    expect(accounts, hasLength(1));
    expect(accounts.single.orders, hasLength(2));
    expect(accounts.single.dueCents, 33000);
    expect(() => linkLegacyPickupOrder(
      state, orderId: 1, existingCustomerId: id),
      throwsFormatException);
  });

  test('new client creation for legacy Gel-Al never merges on name alone', () {
    final state = emptyPosState();
    state['orders'] = [
      order(1, {'name': 'Ali'}, 10000, 0),
      order(2, {'name': 'Ali'}, 20000, 0),
    ];
    linkLegacyPickupOrder(
      state, orderId: 1, newCustomerName: 'Ali');
    linkLegacyPickupOrder(
      state, orderId: 2, newCustomerName: 'Ali');
    expect(savedCustomers(state), hasLength(2));
    expect(pickupOpenAccounts(state), hasLength(2));
  });

  test('legacy linking fails for settled orders and nonexistent customer IDs', () {
    final state = emptyPosState();
    state['orders'] = [order(1, {'name': 'Ali'}, 10000, 0)];
    expect(() => linkLegacyPickupOrder(
      state, orderId: 1, existingCustomerId: 999),
      throwsFormatException);
    expect((mutableOrder(state, 1)!['customer'] as Map).containsKey('id'), false);
    recordPayment(
      mutableOrder(state, 1)!, 10000, 'Kart',
    );
    expect(() => linkLegacyPickupOrder(
      state, orderId: 1, newCustomerName: 'Ali'),
      throwsFormatException);
  });

}
