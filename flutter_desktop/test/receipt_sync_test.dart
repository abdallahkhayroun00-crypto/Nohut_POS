import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/cloud_finance_serializer.dart';
import 'package:nohut_falafel_desktop/cloud_receipt_serializer.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/receipt_printer.dart';
import 'package:nohut_falafel_desktop/receipt_sync_history.dart';
import 'package:nohut_falafel_desktop/remote_commands.dart';
import 'package:nohut_falafel_desktop/sync_outbox.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'print history is local and durable while cloud recording is disabled',
    () {
      final folder = Directory.systemTemp.createTempSync(
        'nohut-offline-print-audit',
      );
      final store = PosStore(databaseFile: '${folder.path}/pos.sqlite3');
      final db = sqlite3.open(store.filePath);
      try {
        final state = emptyPosState();
        newLocalOrder(
          state: state,
          source: 'Gel-Al',
          table: null,
          cashier: 'Synthetic',
          productLines: [
            {'name': 'Synthetic', 'price': 1, 'qty': 1},
          ],
        );
        expect(store.replace(state, store.read().revision).ok, true);
        final job = cloudPrintJobs(store.read().data).single;
        expect(job['syncPrintHistory'].single['origin'], 'created');
        expect(job['syncReceipt'], isNotNull);
        expect(outboxEnabled(db), false);
        expect(pendingOutbox(db), isEmpty);
      } finally {
        db.close();
        store.dispose();
        folder.deleteSync(recursive: true);
      }
    },
  );
  test(
    'print audit survives ambiguity, explicit retry, restart and archive without changing paper content',
    () async {
      final folder = Directory.systemTemp.createTempSync('nohut-print-sync');
      var store = PosStore(databaseFile: '${folder.path}/pos.sqlite3');
      final db = sqlite3.open(store.filePath);
      ReceiptPrinter? printer;
      try {
        enableOutbox(db);
        final state = emptyPosState()
          ..['settings'] = {
            'autoPrint': true,
            'printerName': 'Synthetic printer',
          };
        final order = newLocalOrder(
          state: state,
          source: 'Gel-Al',
          table: null,
          cashier: 'Synthetic',
          productLines: [
            {'name': 'Synthetic original item', 'price': 12.34, 'qty': 1},
          ],
          customer: {
            'name': 'PrivateSyntheticCustomer',
            'phone': '05551234567',
            'time': '12:30',
          },
        );
        final orderId = order['id'] as int;
        expect(store.replace(state, store.read().revision).ok, true);
        Map job() => (store.read().data['printJobs'] as List).single as Map;
        final before = job(),
            id = before['syncId'],
            frozen = jsonEncode(before['syncReceipt']);
        final events = jsonEncode(pendingOutbox(db));
        expect(events, isNot(contains('PrivateSyntheticCustomer')));
        expect(events, isNot(contains('05551234567')));
        expect(frozen, contains('Synthetic original item'));
        expect(frozen, contains('12:30'));
        var calls = 0;
        printer = ReceiptPrinter(
          store,
          transport: (text, name) async {
            calls++;
            expect(text, contains('PrivateSyntheticCustomer'));
            expect(text, isNot(contains('05551234567')));
            if (calls == 1)
              throw const SocketException(
                'Synthetic uncertain printer outcome',
              );
          },
        );
        await printer.pump();
        expect(job()['state'], 'Kontrol gerekli');
        await printer.pump();
        expect(calls, 1, reason: 'ambiguous outcomes never auto retry');
        retryAmbiguousPrint(store, {
          'requestId': 'synthetic_print_retry',
          'checked': true,
          'target': 'kitchen',
          'orderId': orderId,
          'batchId': 1,
        });
        await printer.pump();
        expect(calls, 2);
        expect(job()['state'], 'Kuyruğa gönderildi');
        expect(job()['syncId'], id);
        expect(jsonEncode(job()['syncReceipt']), frozen);
        final history = job()['syncPrintHistory'] as List;
        expect(history.map((e) => e['state']), [
          'Bekliyor',
          'Gönderiliyor',
          'Kontrol gerekli',
          'Bekliyor',
          'Gönderiliyor',
          'Kuyruğa gönderildi',
        ]);
        expect(history.map((e) => e['id']).toSet(), hasLength(6));
        final wire = serializeReceipt(
          Map<String, dynamic>.from(projectRow('printJobs', job()) as Map),
          CloudIdentityMap(db),
          '2026-11-27T12:00:00Z',
        );
        expect(wire['event_count'], 6);
        expect(
          (wire['rows'] as List).singleWhere(
            (r) => r['table'] == 'print_jobs',
          )['data']['status'],
          'spooled',
        );
        printer.dispose();
        printer = null;
        store.dispose();
        store = PosStore(databaseFile: '${folder.path}/pos.sqlite3');
        expect(job()['syncId'], id);
        expect(job()['syncPrintHistory'], history);
        final cursor = pendingOutbox(db).length;
        store.deleteOrder(
          orderId,
          store.read().revision,
          'synthetic_print_archive',
          reason: 'Synthetic audit',
        );
        expect(cloudPrintJobs(store.read().data).single['syncId'], id);
        expect(
          pendingOutbox(
            db,
          ).skip(cursor).any((e) => e['entity_type'] == 'printJobs'),
          false,
          reason: 'archiving retains print audit without erasing it',
        );
      } finally {
        printer?.dispose();
        db.close();
        store.dispose();
        folder.deleteSync(recursive: true);
      }
    },
  );

  test('legacy kitchen job without a frozen source cannot be invented', () {
    final db = sqlite3.openInMemory();
    try {
      final state = emptyPosState()
        ..['printJobs'] = [
          {
            'orderId': 1,
            'batchId': 1,
            'state': 'Bekliyor',
            'createdAt': '2026-11-27T12:00:00Z',
          },
        ];
      prepareReceiptSyncHistory(
        state,
        state,
        '2026-11-27T12:00:01Z',
        force: true,
      );
      final job = cloudPrintJobs(state).single;
      expect(job['syncReceipt'], null);
      expect(job['syncPrintHistory'].single['origin'], 'legacy_current');
      expect(
        () => serializeReceipt(
          Map<String, dynamic>.from(job),
          CloudIdentityMap(db),
          '2026-11-27T12:00:01Z',
        ),
        throwsFormatException,
      );
    } finally {
      db.close();
    }
  });
}
