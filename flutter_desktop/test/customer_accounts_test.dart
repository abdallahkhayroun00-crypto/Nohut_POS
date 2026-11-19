import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_pos/customer_accounts.dart';
import 'package:nohut_pos/pos_logic.dart';
import 'package:nohut_pos/pos_store.dart';

Json order(int id, Json customer, int total, int paid) => {
  'id': id,
  'source': 'Gel-Al',
  'createdAt': DateTime.utc(2026, 11, 19, id).toIso8601String(),
  'customer': customer,
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
}
