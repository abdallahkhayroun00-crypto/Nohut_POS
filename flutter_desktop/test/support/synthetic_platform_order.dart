// Synthetic API-shaped commercial fixture. No network or real restaurant data.
import 'package:nohut_falafel_desktop/trendyol_go_readonly.dart';

Map<String, dynamic> syntheticPlatformOrder({
  String supplier = '12345',
}) => normalizeTgoPackage({
  'id': 'synthetic-package',
  'orderId': 'synthetic-order',
  'orderNumber': 'SYNTHETIC-1',
  'supplierId': supplier,
  'storeId': '456',
  'packageStatus': 'Picking',
  'packageCreationDate': DateTime.utc(
    2026,
    11,
    26,
    22,
    30,
  ).millisecondsSinceEpoch,
  'packageModificationDate': DateTime.utc(
    2026,
    11,
    26,
    22,
    31,
  ).millisecondsSinceEpoch,
  'totalPrice': 20,
  'payment': {'paymentType': 'ONLINE'},
  'customer': {
    'firstName': 'Private',
    'lastName': 'PlatformCustomer',
    'email': 'private@example.invalid',
  },
  'address': {
    'phone': '0850 000 0000',
    'address1': 'Synthetic private address',
  },
  'customerNote':
      'Sos ayrı olsun · Private PlatformCustomer · 0850 000 0000 · Synthetic private address',
  'lines': [
    for (final id in ['item-a', 'item-b'])
      {
        'name': 'Synthetic original falafel',
        'unitSellingPrice': 12.34,
        'items': [
          {'packageItemId': id, 'isCancelled': false},
        ],
        'modifierProducts': [
          {'name': 'Synthetic sauce'},
        ],
        'removedIngredients': ['Soğan'],
        'extraIngredients': ['Humus'],
      },
    {
      'name': 'Synthetic cancelled item',
      'unitSellingPrice': 9.99,
      'items': [
        {'packageItemId': 'item-c', 'isCancelled': true},
      ],
    },
  ],
});
