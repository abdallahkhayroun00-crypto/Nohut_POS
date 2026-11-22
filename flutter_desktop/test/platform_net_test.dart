import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/platform_net.dart';

void main() {
  test('October invoice reference is effective 38.4% rather than an assumed base fee', () {
    final estimate = DeliveryNetEstimate(
      source: 'Trendyol Go',
      orderCount: 149,
      grossCents: 5626000,
      deductionPercent: 38.4,
    );
    expect(estimate.deductionCents, 2160384);
    expect(estimate.estimatedNetCents, 3465616);
  });

  test('unknown fee stays unknown and explicit zero fee is not unknown', () {
    final unknown = DeliveryNetEstimate(
      source: 'Migros Yemek',
      orderCount: 1, grossCents: 20000,
      deductionPercent: null);
    expect(unknown.deductionCents, isNull);
    expect(unknown.estimatedNetCents, isNull);
    expect(deliveryDeductionPercent({
      'settings': {'platformDeductionRates': {'Migros Yemek': 0.0}},
    }, 'Migros Yemek'), 0);
  });

  test('report counts delivered real orders but no unconfirmed or demo sales', () {
    final state = <String, dynamic>{
      'settings': {
        'platformDeductionRates': {
          'Trendyol Go': 38.4,
          'Migros Yemek': 25.0,
        },
      },
      'trendyolGoOrders': [
        {'status': 'Delivered', 'totalCents': 100000,
          'createdAt': '2026-10-20T09:00:00Z'},
        {'status': 'Delivered', 'totalCents': 200000,
          'testPackage': true, 'createdAt': '2026-10-20T09:00:00Z'},
        {'status': 'Cancelled', 'totalCents': 40000,
          'createdAt': '2026-10-20T09:00:00Z'},
      ],
      'orders': [
        {'source': 'Migros Yemek', 'status': 'Delivered',
          'platformSnapshot': {'orderTotal': 250},
          'createdAt': '2026-10-20T09:00:00Z'},
        {'source': 'Yemeksepeti', 'status': 'New',
          'platformSnapshot': {'orderTotal': 500},
          'createdAt': '2026-10-20T09:00:00Z'},
      ],
    };
    final entries = deliveryNetEstimates(state, (_) => true);
    final trendyol = entries.firstWhere((e) => e.source == 'Trendyol Go');
    final migros = entries.firstWhere((e) => e.source == 'Migros Yemek');
    final yemeksepeti = entries.firstWhere((e) => e.source == 'Yemeksepeti');
    expect(trendyol.orderCount, 1);
    expect(trendyol.grossCents, 100000);
    expect(trendyol.estimatedNetCents, 61600);
    expect(migros.orderCount, 1);
    expect(migros.grossCents, 25000);
    expect(migros.estimatedNetCents, 18750);
    expect(yemeksepeti.orderCount, 0);
    expect(yemeksepeti.deductionCents, isNull);
  });
}
