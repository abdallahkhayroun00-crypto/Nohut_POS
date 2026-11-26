import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/trendyol_go_readonly.dart';

void main() {
  final payload = <String, dynamic>{
    'id': 5000,
    'orderNumber': 'TG-101',
    'supplierId': 12345,
    'storeId': 456,
    'packageStatus': 'Picking',
    'packageCreationDate': 1763503200000,
    'packageModificationDate': 1763503260000,
    'totalPrice': 355.50,
    'customerNote': 'Sos ayrı olsun',
    'payment': {'paymentType': 'ONLINE'},
    'lines': [
      {
        'name': 'Falafel Dürüm',
        'unitSellingPrice': 160.00,
        'items': [
          {'isCancelled': false},
          {'isCancelled': false},
        ],
        'modifierProducts': [
          {'name': 'Ekstra humus'},
        ],
      },
    ],
  };

  test(
    'Platform price and total remain authoritative, not shop-menu price',
    () {
      final o = normalizeTgoPackage(payload);
      expect(o['source'], 'Trendyol Go');
      expect(o['totalCents'], 35550);
      expect(o['customerNote'], 'Sos ayrı olsun');
      final lines = o['lines'] as List;
      expect(lines.single['unitPriceCents'], 16000);
      expect(lines.single['qty'], 2);
      expect((lines.single['options'] as List).single, 'Ekstra humus');
    },
  );

  test('Cancelled or test orders are not counted as sales', () {
    final order = normalizeTgoPackage(payload);
    expect(tgoCountsAsSale(order), false); // Picking is not a completed sale.
    expect(tgoCountsAsSale({...order, 'status': 'Delivered'}), true);
    expect(tgoCountsAsSale({...order, 'status': 'Cancelled'}), false);
    expect(tgoCountsAsSale({...order, 'testPackage': true}), false);
  });

  test('Official meal payload preserves available customer and courier details', () {
    final order = normalizeTgoPackage({
      ...payload,
      'id': 'abc123',
      'customer': {'firstName': 'A', 'lastName': 'K', 'email': 'masked@example.com'},
      'address': {
        'address1': 'Sokak 5',
        'district': 'Serdivan',
        'city': 'Sakarya',
        'phone': '0850 000 0000',
      },
      'userInformation': {'appName': 'TrendyolGo'},
      'preparationTime': 12,
      'isCourierNearby': true,
      'pickupEtaState': 'SUCCESS',
      'estimatedPickupTimeMin': 1763503200000,
      'estimatedPickupTimeMax': 1763503500000,
      'eta': '15 - 30 dk',
      'lines': [
        {
          'name': 'Falafel Dürüm',
          'items': [
            {'packageItemId': 'item-1', 'isCancelled': false},
            {'packageItemId': 'item-2', 'isCancelled': false},
          ],
        },
      ],
    });
    expect(order['customerName'], 'A K');
    expect(order['customerPhone'], '0850 000 0000');
    expect(order['customerEmail'], 'masked@example.com');
    expect(order['deliveryAddress'], contains('Sokak 5'));
    expect(order['appName'], 'TrendyolGo');
    expect(order['preparationMinutes'], 12);
    expect(order['courierNearby'], true);
    expect(order['courierEtaFrom'], isNotNull);
    expect(order['courierEtaTo'], isNotNull);
    expect(order['pickupEtaState'], 'SUCCESS');
    expect(order['packageItemIds'], ['item-1', 'item-2']);
    expect(order['deliveryEta'], '15 - 30 dk');
  });

  test('Order write actions are enabled in standard builds', () {
    expect(TrendyolGoReadonly.writeEnabled, true);
  });

  group('Documented MEAL write requests (packageId in body, not path)', () {
    final order = <String, dynamic>{
      'packageId': '5000',
      'packageItemIds': ['item-1', 'item-2'],
    };
    const base = '/integrator/order/meal/suppliers/12345/packages';

    test('Kabul Et → PUT packages/picked with preparationTime', () {
      final w = tgoWriteRequest(supplierId: '12345', order: order,
        action: 'accept', preparationMinutes: 20);
      expect(w.path, '$base/picked');
      expect(w.body, {'packageId': '5000', 'preparationTime': 20});
    });

    test('Hazır → PUT packages/invoiced with only packageId', () {
      final w = tgoWriteRequest(supplierId: '12345', order: order,
        action: 'ready');
      expect(w.path, '$base/invoiced');
      expect(w.body, {'packageId': '5000'});
    });

    test('İptal → PUT packages/unsupplied with items and reason', () {
      final w = tgoWriteRequest(supplierId: '12345', order: order,
        action: 'cancel', reasonId: 622);
      expect(w.path, '$base/unsupplied');
      expect(w.body, {
        'packageId': '5000',
        'itemIdList': ['item-1', 'item-2'],
        'reasonId': 622,
      });
    });

    test('Rejects invalid input before any network call', () {
      for (final minutes in [null, 0, 121]) {
        expect(() => tgoWriteRequest(supplierId: '12345', order: order,
          action: 'accept', preparationMinutes: minutes),
          throwsFormatException);
      }
      expect(() => tgoWriteRequest(supplierId: '12345', order: order,
        action: 'cancel', reasonId: 999), throwsFormatException);
      expect(() => tgoWriteRequest(supplierId: '12345',
        order: {'packageId': '5000'}, action: 'cancel', reasonId: 621),
        throwsFormatException);
      expect(() => tgoWriteRequest(supplierId: '12345',
        order: {'packageId': '50/00'}, action: 'ready'),
        throwsFormatException);
      expect(() => tgoWriteRequest(supplierId: 'abc', order: order,
        action: 'ready'), throwsFormatException);
      expect(() => tgoWriteRequest(supplierId: '12345', order: order,
        action: 'delete'), throwsFormatException);
    });
  });

  test('Rejects packages without a stable external identifier', () {
    expect(
      () => normalizeTgoPackage({...payload, 'id': null}),
      throwsFormatException,
    );
  });
}
