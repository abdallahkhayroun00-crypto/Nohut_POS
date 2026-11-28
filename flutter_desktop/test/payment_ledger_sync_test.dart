import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/card_terminal.dart';
import 'package:nohut_falafel_desktop/cloud_finance_serializer.dart';
import 'package:nohut_falafel_desktop/cloud_payment_ledger_serializer.dart';
import 'package:nohut_falafel_desktop/cloud_order_serializer.dart';
import 'package:nohut_falafel_desktop/group_payments.dart';
import 'package:nohut_falafel_desktop/operations.dart';
import 'package:nohut_falafel_desktop/payment_ledger_sync.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/sync_outbox.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/synthetic_inpos_gateway.dart';

void main() {
  test(
    'combined/cash/terminal facts stay exact and terminal audit survives archive',
    () async {
      final folder = Directory.systemTemp.createTempSync(
        'nohut-payment-ledger',
      );
      var store = PosStore(databaseFile: '${folder.path}/pos.sqlite3');
      final db = sqlite3.open(store.filePath);
      try {
        enableOutbox(db);
        final state = emptyPosState()
          ..['settings'] = {'receiptPolicy': 'onPayment'};
        final orders = <int>[];
        for (final price in [10, 20, 10]) {
          orders.add(
            newLocalOrder(
                  state: state,
                  source: 'Gel-Al',
                  table: null,
                  cashier: 'Synthetic',
                  productLines: [
                    {'name': 'Synthetic item', 'price': price, 'qty': 1},
                  ],
                  customer: {
                    'id': 12,
                    'name': 'Private Synthetic Customer',
                    'phone': '05551234567',
                  },
                )['id']
                as int,
          );
        }
        openCash(state, 10000);
        moveCash(state, -200, 'Synthetic cash movement');
        expect(store.replace(state, store.read().revision).ok, true);
        store.command('synthetic_combined_payment', {}, (s) {
          recordCombinedPickupPayment(
            s,
            orderIds: orders.take(2).toList(),
            amountCents: 3000,
            method: 'Karışık',
            cashCents: 1200,
            receivedCents: 1500,
            transactionId: 'synthetic-combined-reference',
          );
          closeCash(s, 11000);
          return {'ok': true};
        });
        final current = store.read().data, ids = CloudIdentityMap(db);
        final group = serializePaymentLedger(
          'combinedPayments',
          projectCore('combinedPayments', current['combinedPayments']),
          ids,
          '2026-11-27T12:00:00Z',
        );
        expect(group['counts'], {
          'combined_payment_groups': 1,
          'combined_payment_members': 2,
        });
        expect(jsonEncode(group), isNot(contains('accountKey')));
        expect(jsonEncode(group), isNot(contains('05551234567')));
        final cash = serializePaymentLedger(
          'cashBook',
          projectCore('cashBook', current['cashBook']),
          ids,
          '2026-11-27T12:00:00Z',
        );
        final cashRow = (cash['rows'] as List).singleWhere(
          (r) => r['table'] == 'cash_sessions',
        )['data'];
        expect(cashRow['expected_kurus'], 11000);
        expect(cashRow['difference_kurus'], 0);
        final movementId = ((current['cashBook'] as Map)['movements'] as List)
            .single['syncId'];
        final gateway = SyntheticInposGateway();
        // Use exactly one fake processor for the attempted payment and inquiry.
        final coordinator = InposPayments(store, gateway);
        await coordinator.pay(
          orders.last,
          1000,
          'synthetic_terminal_reference',
        );
        await coordinator.pay(
          orders.last,
          1000,
          'synthetic_terminal_reference',
        );
        expect(gateway.sends, 1);
        expect(gateway.queries, 1);
        gateway.reply = const TerminalReply(
          TerminalStatus.approved,
          transactionId: 'synthetic-terminal-transaction',
          amountCents: 1000,
        );
        await coordinator.reconcile('synthetic_terminal_reference');
        final attempt = allTerminalAttempts(store.read().data).single;
        expect((attempt['syncHistory'] as List).map((e) => e['status']), [
          'waiting',
          'waiting',
          'unknown',
          'approved',
        ]);
        final projection = serializePaymentLedger(
          'terminalAttempts',
          projectCore(
            'terminalAttempts',
            allTerminalAttempts(store.read().data),
          ),
          ids,
          '2026-11-27T12:00:00Z',
        );
        expect(projection['counts'], {
          'terminal_attempts': 1,
          'terminal_attempt_events': 4,
        });
        final export = Platform.environment['NOHUT_EXPORT_SYNTHETIC_LEDGER'];
        if (export != null) {
          File(export).writeAsStringSync(
            jsonEncode({
              'combined': group,
              'cash': cash,
              'terminal': projection,
              'orders': [
                for (final o
                    in (store.read().data['orders'] as List).cast<Map>())
                  serializeOrder(
                    Map<String, dynamic>.from(projectRow('orders', o) as Map),
                    ids,
                    '2026-11-27T12:00:00Z',
                  ),
              ],
            }),
          );
        }
        // Keep source observation times rather than inventing a payment date.
        expect(
          (projection['rows'] as List).first['data']['first_observed_at'],
          attempt['syncHistory'].first['observedAt'],
        );
        final count = pendingOutbox(db).length;
        store.deleteOrder(
          orders.last,
          store.read().revision,
          'synthetic_terminal_archive',
          reason: 'Synthetic audit',
        );
        expect(allTerminalAttempts(store.read().data).single, attempt);
        expect(
          pendingOutbox(
            db,
          ).skip(count).any((e) => e['entity_type'] == 'terminalAttempts'),
          false,
        );
        store.dispose();
        store = PosStore(databaseFile: '${folder.path}/pos.sqlite3');
        expect(
          allTerminalAttempts(store.read().data).single['syncHistory'],
          attempt['syncHistory'],
        );
        expect(
          store.read().data['cashBook']['movements'].single['syncId'],
          movementId,
        );
      } finally {
        db.close();
        store.dispose();
        folder.deleteSync(recursive: true);
      }
    },
  );
}
