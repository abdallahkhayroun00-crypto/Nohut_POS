// Synthetic POS state built through the real production write paths.
// Shared by the storage benchmark and the persistence validation tests.
// Synthetic data only: names, phones and addresses are invented.
import 'dart:math';

import 'package:nohut_falafel_desktop/operations.dart';
import 'package:nohut_falafel_desktop/order_actions.dart';
import 'package:nohut_falafel_desktop/order_reporting.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/trendyol_go_readonly.dart';

const _menu = [
  ('Falafel Dürüm', 160), ('Falafel Tabağı', 240), ('Humus', 110),
  ('Vegan Özel Tabağı', 290), ('Ayran', 35), ('Çay', 20),
  ('Ispanaklı Sembusek', 40), ('Şakşuka', 150), ('Mercimek Çorbası', 90),
  ('Layali Lübnan', 120), ('Patates Kızartması (Büyük)', 95),
  ('Muhammara', 115),
];
const _removable = ['Domates', 'Turşu', 'Soğan', 'Maydanoz', 'Acı sos'];
const _notes = [
  'Acı olsun', 'Sos ayrı gelsin', 'Çocuk için, az baharatlı',
  'Ekmeği iyi pişmiş olsun', 'Paket olsun lütfen', '',
];
const _names = ['Ayşe', 'Mehmet Yılmaz', 'Gülşen', 'İbrahim', 'Özge Çelik'];

Json _scratch() => {
  ...emptyPosState(),
  'localMenu': [
    for (var i = 0; i < _menu.length; i++)
      {'id': i, 'name': _menu[i].$1, 'category': 'wrap', 'price': _menu[i].$2},
  ],
  'settings': {'autoPrint': true, 'printerName': 'bench'},
};

Json _line(Random r) {
  final p = r.nextInt(_menu.length);
  final removed = r.nextInt(4) == 0
      ? [_removable[r.nextInt(_removable.length)]]
      : <String>[];
  return {
    'productId': p,
    'name': _menu[p].$1,
    'price': _menu[p].$2,
    'qty': 1 + r.nextInt(3),
    'removed': removed,
    'note': r.nextInt(5) == 0 ? _notes[r.nextInt(_notes.length)] : '',
  };
}

List<Json> _lines(Random r) {
  final lines = [for (var i = 0, n = 1 + r.nextInt(4); i < n; i++) _line(r)];
  if (r.nextInt(5) == 0) {
    // Campaign-shaped line: a menu with frozen components, as stored today.
    lines.first['name'] = '2’li Menü';
    lines.first['components'] = [
      {'name': 'Falafel Dürüm', 'removed': ['Soğan'], 'note': ''},
      {'name': 'Ayran', 'removed': <String>[], 'note': 'Soğuk'},
    ];
  }
  return lines;
}

/// One local order (Masa or Gel-Al) created with the real functions.
(Json, List<Json>) syntheticLocalOrder(Random r, DateTime at) {
  final s = _scratch();
  final pickup = r.nextInt(10) < 4;
  final o = newLocalOrder(
    state: s,
    source: pickup ? 'Gel-Al' : 'Masa',
    table: pickup ? null : 1 + r.nextInt(5),
    productLines: _lines(r),
    pickupChannel: pickup && r.nextBool() ? 'Telefon' : 'Tezgahtan',
    cashier: 'Test Personel A',
    staffId: 2,
    customer: pickup
        ? {
            'name': _names[r.nextInt(_names.length)],
            'phone': r.nextBool() ? '0555${1000000 + r.nextInt(8999999)}' : '',
            'time': '1${r.nextInt(9)}:${r.nextBool() ? '15' : '45'}',
          }
        : null,
  );
  if (r.nextInt(100) < 15) {
    addOrderBatch(s, o['id'] as int, _lines(r), cashier: 'Test Personel B', staffId: 3);
  }
  if (r.nextInt(100) < 5) {
    cancelProduct(s, o['id'] as int, '1:0', 1, 'Müşteri vazgeçti');
  }
  final total = orderTotalCents(o);
  if (total > 0) {
    if (r.nextInt(100) < 10 && total > 100) {
      recordPayment(o, total ~/ 2, 'Kart');
      recordPayment(o, total - total ~/ 2, 'Nakit',
          receivedCents: ((total - total ~/ 2) ~/ 10000 + 1) * 10000);
    } else if (r.nextBool()) {
      recordPayment(o, total, 'Kart');
    } else {
      recordPayment(o, total, 'Nakit', receivedCents: (total ~/ 10000 + 1) * 10000);
    }
    if (r.nextInt(100) < 5) {
      refundPayment(o, 0, min(1000, paymentNetCents(asMaps(o['payments']).first)),
          'Ürün eksik geldi');
    }
    if (r.nextInt(100) < 30) {
      queuePaymentReceipt(s, o, requestId: 'rcpt_${r.nextInt(1 << 30)}');
    }
    if (orderDueCents(o) == 0) {
      o['closed'] = true;
      o['tableReleased'] = true;
      o['closedAt'] = at.add(const Duration(minutes: 35)).toIso8601String();
    }
  }
  // Historical orders never hold a table (refunded / partly paid ones too).
  o['tableReleased'] = true;
  // Move every timestamp to the synthetic business day.
  final stamp = at.toIso8601String();
  o['createdAt'] = stamp;
  for (final b in (o['batches'] as List).cast<Map>()) {
    b['createdAt'] = stamp;
  }
  final jobs = asMaps(s['printJobs']);
  for (final j in jobs) {
    j['createdAt'] = stamp;
    j['state'] = 'Kuyruğa gönderildi';
  }
  return (o, jobs);
}

Json _platformOrder(Random r, DateTime at, int n) {
  final order = normalizeTgoPackage({
    'id': 'pkg-${100000 + n}',
    'orderNumber': '${1090000000 + n}',
    'orderCode': n.toRadixString(36).toUpperCase().padLeft(5, '0'),
    'packageStatus': r.nextInt(20) == 0 ? 'Cancelled' : 'Delivered',
    'packageCreationDate': at.millisecondsSinceEpoch,
    'packageModificationDate': at.millisecondsSinceEpoch + 2400000,
    'totalPrice': 300 + r.nextInt(400),
    'customerNote': r.nextInt(4) == 0 ? 'Zili çalmayın, kapıya bırakın' : '',
    'payment': {'paymentType': 'PAY_WITH_CARD'},
    'customer': {'firstName': 'Gülşen', 'lastName': 'Ö.'},
    'address': {
      'address1': 'Atatürk Mah. Çiçek Sok. No: ${r.nextInt(90)}',
      'district': 'Merkez', 'city': 'Bilecik',
      'phone': '0555${1000000 + r.nextInt(8999999)}',
    },
    'lines': [
      for (var i = 0, k = 1 + r.nextInt(3); i < k; i++)
        {
          'name': _menu[r.nextInt(_menu.length)].$1,
          'unitSellingPrice': 100 + r.nextInt(200),
          'items': [
            for (var q = 0; q < 1 + r.nextInt(2); q++)
              {'packageItemId': 'it-$n-$i-$q', 'isCancelled': false},
          ],
          'modifierProducts': r.nextBool() ? [{'name': 'Humus'}] : [],
          'removedIngredients': r.nextInt(3) == 0 ? [{'name': 'Domates'}] : [],
        },
    ],
  });
  order['kitchenPrintState'] = 'Kuyruğa gönderildi';
  order['kitchenQueuedAt'] = at.toIso8601String();
  return order;
}

/// Builds a state with [count] orders (≈25 % Trendyol Go) over ~60 orders/day.
Json buildSyntheticState(int count, {int seed = 20261127}) {
  final r = Random(seed);
  final state = _scratch();
  final orders = state['orders'] as List, jobs = state['printJobs'] as List;
  final tgo = <Json>[];
  var id = 1200;
  final start = DateTime.utc(2024, 1, 1, 7);
  for (var i = 0; i < count; i++) {
    final at = start.add(Duration(minutes: (i ~/ 60) * 1440 + (i % 60) * 12));
    if (r.nextInt(4) == 0) {
      tgo.add(_platformOrder(r, at, i));
      continue;
    }
    final (o, orderJobs) = syntheticLocalOrder(r, at);
    final old = o['id'];
    o['id'] = id;
    for (final j in orderJobs) {
      if (j['orderId'] == old) j['orderId'] = id;
      final snap = j['snapshot'];
      if (snap is Map && snap['order'] is Map) (snap['order'] as Map)['id'] = id;
    }
    id++;
    orders.add(o);
    jobs.addAll(orderJobs);
  }
  state['trendyolGoOrders'] = tgo;
  state['nextId'] = id;
  for (final o in [...orders.cast<Map>(), ...tgo]) {
    o.remove('dailyNumber');
    o.remove('numberDay');
  }
  assignDailyNumbers(state);
  return state;
}

