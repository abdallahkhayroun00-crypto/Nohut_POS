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
import '../support/synthetic_pos.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:sqlite3/sqlite3.dart';

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
        final latencies = <int>[], edits = <int>[];
        final r = Random(7);
        for (var k = 0; k < 15; k++) {
          final edit = Stopwatch()..start();
          final snap = store.read();
          final next = snap.data;
          final (o, orderJobs) = syntheticLocalOrder(r, DateTime.utc(2026, 11, 27, 12));
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
          edit.stop();
          latencies.add(w.elapsedMicroseconds);
          edits.add(edit.elapsedMicroseconds);
        }
        latencies.sort();
        edits.sort();
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
          'editLatencyMsP50': _pct(edits, .5),
          'editLatencyMsP95': _pct(edits, .95),
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
