// Phase 0 storage benchmark (spec V5 §19.9). Synthetic data only.
//
// Skipped in normal CI. Run explicitly:
//   NOHUT_BENCH=1 flutter test test/benchmark/storage_benchmark_test.dart
// Optional: NOHUT_BENCH_SIZES=1000,10000,50000 NOHUT_BENCH_OUT=<file.json>
//
// Every order is created through the real POS functions (newLocalOrder,
// addOrderBatch, recordPayment, refundPayment, cancelProduct,
// queuePaymentReceipt, normalizeTgoPackage) on a small scratch state and then
// appended, so the stored JSON has the production shape. Nothing here
// estimates; every number printed is measured on this machine.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/operations.dart';
import 'package:nohut_falafel_desktop/order_actions.dart';
import 'package:nohut_falafel_desktop/order_reporting.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/trendyol_go_readonly.dart';
import 'package:sqlite3/sqlite3.dart';

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
(Json, List<Json>) _localOrder(Random r, DateTime at) {
  final s = _scratch();
  final pickup = r.nextInt(10) < 4;
  final o = newLocalOrder(
    state: s,
    source: pickup ? 'Gel-Al' : 'Masa',
    table: pickup ? null : 1 + r.nextInt(5),
    productLines: _lines(r),
    pickupChannel: pickup && r.nextBool() ? 'Telefon' : 'Tezgahtan',
    cashier: 'Mehmet',
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
    addOrderBatch(s, o['id'] as int, _lines(r), cashier: 'Abdallah', staffId: 3);
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
    final (o, orderJobs) = _localOrder(r, at);
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

int _bytes(Object? v) => utf8.encode(jsonEncode(v)).length;

double _pct(List<int> sorted, double p) =>
    sorted[min(sorted.length - 1, (p * (sorted.length - 1)).round())] / 1000;

void main() {
  final enabled = Platform.environment['NOHUT_BENCH'] == '1';
  test('storage benchmark (synthetic, measured)', () async {
    final sizes = (Platform.environment['NOHUT_BENCH_SIZES'] ?? '1000,10000,50000')
        .split(',').map(int.parse).toList();
    final results = <Map<String, Object?>>[];
    for (final n in sizes) {
      final dir = Directory.systemTemp.createTempSync('nohut-bench');
      try {
        final buildWatch = Stopwatch()..start();
        final state = buildSyntheticState(n);
        buildWatch.stop();
        final local = (state['orders'] as List).length,
            platform = (state['trendyolGoOrders'] as List).length;
        final file = '${dir.path}/bench.sqlite3';
        final store = PosStore(databaseFile: file);
        expect(store.replace(state, store.read().revision).ok, true);

        // Real staff command receipts for every phone (Gel-Al Telefon) order
        // are not reproducible without the LAN; measure one real receipt row
        // shape and insert one per Gel-Al order through SQLite directly.
        final receiptPayload = jsonEncode({
          'requestId': 'staff_bench_0000000', 'expectedRevision': 1,
          'staffId': 2, 'source': 'Gel-Al', 'pickupChannel': 'Telefon',
          'customer': {'name': 'Ayşe', 'phone': '05551234567', 'time': '13:15'},
          'lines': [{'productId': 0, 'qty': 2, 'removed': ['Domates'], 'note': ''}],
        });
        final receiptResult = jsonEncode({'ok': true, 'orderId': 1300,
          'orderNumber': '0042', 'requestId': 'staff_bench_0000000',
          'revision': 1});

        // Write latency of one more order on a store of this size: the
        // whole JSON snapshot is rewritten on every committed change.
        final latencies = <int>[];
        final r = Random(7);
        for (var k = 0; k < 15; k++) {
          final snap = store.read();
          final next = copyJson(snap.data);
          final (o, orderJobs) = _localOrder(r, DateTime.utc(2026, 11, 27, 12));
          final nid = next['nextId'] as int;
          o['id'] = nid;
          for (final j in orderJobs) {
            j['orderId'] = nid;
          }
          next['nextId'] = nid + 1;
          (next['orders'] as List).add(o);
          (next['printJobs'] as List).addAll(orderJobs);
          final w = Stopwatch()..start();
          expect(store.replace(next, snap.revision).ok, true);
          w.stop();
          latencies.add(w.elapsedMicroseconds);
        }
        latencies.sort();
        store.dispose();

        final db = sqlite3.open(file);
        final gelAl = (state['orders'] as List)
            .where((o) => (o as Map)['source'] == 'Gel-Al').length;
        db.execute('BEGIN');
        final insert = db.prepare(
            'INSERT INTO command_receipts(request_id,payload,result) VALUES(?,?,?)');
        for (var k = 0; k < gelAl; k++) {
          insert.execute(['staff_bench_$k', receiptPayload, receiptResult]);
        }
        insert.dispose();
        db.execute('COMMIT');
        db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
        final pageCount = db.select('PRAGMA page_count').single.values.first as int;
        final pageSize = db.select('PRAGMA page_size').single.values.first as int;
        final payloadLen = db.select(
            'SELECT length(CAST(payload AS BLOB)) AS n FROM state_snapshot').single['n'] as int;
        final receiptsLen = db.select(
            'SELECT coalesce(sum(length(CAST(payload AS BLOB))+length(CAST(result AS BLOB))+length(request_id)),0) AS n FROM command_receipts').single['n'] as int;
        final backup = '${dir.path}/backup.sqlite3';
        db.execute('VACUUM INTO ?', [backup]);
        db.dispose();
        final backupBytes = File(backup).lengthSync();
        final gz = gzip.encode(File(backup).readAsBytesSync()).length;

        final orderBytes = _bytes(state['orders']),
            jobBytes = _bytes(state['printJobs']),
            tgoBytes = _bytes(state['trendyolGoOrders']);
        final row = {
          'orders': n,
          'localOrders': local,
          'trendyolGoOrders': platform,
          'printJobs': (state['printJobs'] as List).length,
          'commandReceipts': gelAl,
          'buildSeconds': buildWatch.elapsedMilliseconds / 1000,
          'stateJsonBytes': payloadLen,
          'ordersJsonBytes': orderBytes,
          'printJobsJsonBytes': jobBytes,
          'trendyolGoJsonBytes': tgoBytes,
          'commandReceiptBytes': receiptsLen,
          'bytesPerLocalOrder': (orderBytes / local).round(),
          'printJobBytesPerLocalOrder': (jobBytes / local).round(),
          'bytesPerTrendyolOrder': (tgoBytes / platform).round(),
          'sqliteFileBytes': pageCount * pageSize,
          'vacuumBackupBytes': backupBytes,
          'gzipBackupBytes': gz,
          'writeLatencyMsP50': _pct(latencies, .5),
          'writeLatencyMsP95': _pct(latencies, .95),
          'writeSamples': latencies.length,
        };
        results.add(row);
        // ignore: avoid_print
        print(jsonEncode(row));
      } finally {
        dir.deleteSync(recursive: true);
      }
    }
    final out = Platform.environment['NOHUT_BENCH_OUT'];
    if (out != null) {
      File(out).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(results));
    }
  }, skip: enabled ? false : 'Set NOHUT_BENCH=1 to run', timeout: Timeout.none);
}
