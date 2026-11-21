import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/order_reporting.dart';
import 'package:nohut_falafel_desktop/operations.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/service_metrics.dart';

Json item(String label, int price) => {
  'productId': 0,
  'name': label,
  'price': price,
  'qty': 1,
  'removed': <String>[],
  'note': '',
};

void main() {
  test('extra order credited to original owner, not cashier who entered extra', () {
    final s = emptyPosState();
    final original = newLocalOrder(
      state: s,
      source: 'Masa',
      table: 1,
      productLines: [item('Falafel', 200)],
      cashier: 'Abdallah',
    );
    (original['batches'] as List).first['staffId'] = 3;
    addOrderBatch(
      s,
      original['id'] as int,
      [item('Sembusek', 100)],
      cashier: 'Mehmet',
      staffId: 2,
    );

    expect(orderOwnerName(original), 'Abdallah');
    expect(orderTotalCents(original), 30000);
    expect(sales(s).map((entry) => entry.staff), ['Abdallah', 'Abdallah']);
    final summary = staffOrderSummaries(s, istanbulDay(DateTime.now()));
    expect(summary, hasLength(1));
    expect(summary.single.name, 'Abdallah');
    expect(summary.single.orders, 1);
    expect(summary.single.additions, 1);
    expect(summary.single.totalCents, 30000);
  });

  test('historical cashier-created order stays unassigned instead of guessed', () {
    final s = emptyPosState();
    final order = newLocalOrder(
      state: s,
      source: 'Gel-Al',
      productLines: [item('Falafel', 140)],
    );
    expect(orderOwnerName(order), 'Atanmamış');
    final summary = staffOrderSummaries(s, istanbulDay(DateTime.now()));
    expect(summary.single.unassigned, isTrue);
    expect(summary.single.name, 'Atanmamış');
    expect(summary.single.totalCents, 14000);
    expect(sales(s).single.staff, 'Atanmamış');
  });
}
