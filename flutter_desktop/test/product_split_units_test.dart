import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/operations.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';

void main() {
  Map<String, dynamic> sampleOrder() => {
    'id': 1,
    'source': 'Masa',
    'table': 2,
    'dailyNumber': 1,
    'numberDay': '2026-11-20',
    'closed': false,
    'cancelled': false,
    'events': <dynamic>[],
    'payments': <dynamic>[],
    'guestChecks': <dynamic>[],
    'batches': [
      {
        'id': 1,
        'staff': 'Test Personel A',
        'createdAt': '2026-11-20T12:00:00Z',
        'lines': [
          {'name': 'Ayran', 'price': 40, 'qty': 2},
          {'name': 'Dürüm', 'price': 140, 'qty': 2},
          {'name': 'Porsiyon', 'price': 180, 'qty': 1},
        ],
      }
    ],
  };

  List<String> unpaidNames(Map<String, dynamic> order) => [
    for (final line in checkLines(order))
      if (line.total > allocatedTo(order, line.key)) '${line.line['name']}'
  ];

  test('three guests pay one unit at a time, paid units leave remaining', () {
    final order = sampleOrder();
    expect(orderTotalCents(order), 54000);
    final keys = checkLines(order).map((line) => line.key).toList();
    expect(keys, ['1:0', '1:1', '1:2']);
    final receipt = recordProductPayment(
      order,
      {keys[0]: 4000, keys[1]: 14000},
      18000,
      'Nakit',
      receivedCents: 20000,
    );
    expect(receipt, contains('1 × Ayran'));
    expect(receipt, contains('1 × Dürüm'));
    expect(orderPaidCents(order), 18000);
    expect(orderDueCents(order), 36000);
    expect(allocatedTo(order, keys[0]), 4000);
    expect(allocatedTo(order, keys[1]), 14000);
    expect(unpaidNames(order), ['Ayran', 'Dürüm', 'Porsiyon']);

    recordProductPayment(order,
        {keys[0]: 4000, keys[1]: 14000}, 18000, 'Kart');
    expect(orderDueCents(order), 18000);
    expect(unpaidNames(order), ['Porsiyon']);
    expect(allocatedTo(order, keys[0]), 8000);
    expect(allocatedTo(order, keys[1]), 28000);

    final before = copyJson(order);
    expect(
      () => recordProductPayment(order, {keys[0]: 4000}, 4000, 'Kart'),
      throwsFormatException,
    );
    expect(order, before, reason: 'invalid double payment must be atomic');

    recordProductPayment(order, {keys[2]: 18000}, 18000, 'Kart');
    expect(orderDueCents(order), 0);
    expect(unpaidNames(order), isEmpty);
    expect(asMaps(order['payments']), hasLength(3));
    // Paid units remain in the historical order and receipt.
    expect(checkLines(order), hasLength(3));
  });
}
