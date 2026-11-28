import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/cloud_finance_serializer.dart';
import 'package:nohut_falafel_desktop/cloud_order_serializer.dart';
import 'package:nohut_falafel_desktop/order_sync_identity.dart';
import 'package:nohut_falafel_desktop/operations.dart';
import 'package:nohut_falafel_desktop/order_actions.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/sync_outbox.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'typed orders retain frozen campaign customizations and reject missing identities',
    () {
      final db = sqlite3.openInMemory();
      try {
        final state = emptyPosState()
          ..['settings'] = {'receiptPolicy': 'onPayment'};
        final o = newLocalOrder(
          state: state,
          source: 'Gel-Al',
          table: null,
          cashier: 'Synthetic',
          productLines: [
            {'name': 'Synthetic campaign', 'price': 25, 'qty': 1},
          ],
        );
        final line =
            ((o['batches'] as List).single['lines'] as List).single as Map;
      line.addAll(<String,dynamic>{
          'campaignId': 'synthetic-offer',
          'basePrice': 24,
          'adjustmentCents': 100,
          'removed': ['Soğan'],
          'components': [
            {
              'slot': 0,
              'productId': 1,
              'name': 'Historical component',
              'qty': 1,
              'price': 12.34,
              'basePrice': 12.34,
              'adjustmentCents': 0,
              'removed': ['Sos'],
              'note': 'Synthetic detail',
            },
          ],
        });
        prepareOrderSyncIdentities(emptyPosState(), state, force: true);
        final ids = CloudIdentityMap(db);
        Map<String, Object?> encode() => serializeOrder(
          Map<String, dynamic>.from(projectRow('orders', o) as Map),
          ids,
          '2026-11-27T12:00:00Z',
        );
        final before = encode(), rows = (before['rows'] as List).cast<Map>();
        final item =
            rows.singleWhere((r) => r['table'] == 'order_items')['data'] as Map;
        expect(item['unit_price_kurus'], 2500);
        expect(
          item['customizations']['components'].single['price_kurus'],
          1234,
        );
        expect(item['customizations']['removed'], ['Soğan']);
        final frozen =
            rows.singleWhere((r) => r['table'] == 'product_versions')['data']
                as Map;
        line['name'] = 'Synthetic renamed sale';
        line['price'] = 26;
        final after =
            (encode()['rows'] as List).cast<Map>().singleWhere(
                  (r) => r['table'] == 'product_versions',
                )['data']
                as Map;
        expect(after['product_id'], frozen['product_id']);
        expect(
          after['product_version_id'],
          isNot(frozen['product_version_id']),
        );
        expect(frozen['label_tr'], 'Synthetic campaign');
        expect(frozen['price_kurus'], 2500);
        line.remove('syncId');
        expect(encode, throwsFormatException);
      } finally {
        db.close();
      }
    },
  );
  test(
    'nested IDs survive money changes, edits, reorder, restart and soft delete',
    () {
      final folder = Directory.systemTemp.createTempSync(
        'nohut-order-identities',
      );
      var store = PosStore(databaseFile: '${folder.path}/pos.sqlite3');
      final probe = sqlite3.open(store.filePath);
      try {
        final state = emptyPosState()
          ..['settings'] = {'receiptPolicy': 'onPayment'};
        final order = newLocalOrder(
          state: state,
          source: 'Gel-Al',
          table: null,
          cashier: 'Synthetic',
          staffId: 1,
          productLines: [
            {'name': 'Synthetic first', 'price': 12.34, 'qty': 2},
            {'name': 'Synthetic second', 'price': 20, 'qty': 1},
          ],
        );
        final orderId = order['id'] as int;
        expect(store.replace(state, store.read().revision).ok, true);
        enableOutbox(probe);
        store.prepareCloudOrderIdentities();
        Map current() => asMaps(store.read().data['orders']).single;
        final before = asMaps(asMaps(current()['batches']).single['lines']);
        final lineIds = {
          for (final line in before) line['name']: line['syncId'],
        };
        expect(lineIds.values.toSet(), hasLength(2));
        store.command('synthetic_mixed_payment', {}, (s) {
          recordMixedPayment(mutableOrder(s, orderId)!, 1000, 400);
          return {'ok': true};
        });
        final payments = asMaps(current()['payments']);
        final paymentIds = payments.map((p) => p['syncId']).toList();
        expect(paymentIds.toSet(), hasLength(2));
        store.command('synthetic_refund_payment', {}, (s) {
          refundPayment(mutableOrder(s, orderId)!, 0, 100, 'Synthetic refund');
          return {'ok': true};
        });
        expect(
          asMaps(current()['payments']).map((p) => p['syncId']),
          paymentIds,
        );
        final refundId = asMaps(
          asMaps(current()['payments']).first['refunds'],
        ).single['syncId'];
        expect(refundId, isA<String>());
        store.command('synthetic_line_edit', {}, (s) {
          editLocalLine(
            mutableOrder(s, orderId)!,
            '1:0',
            2,
            'Synthetic edit',
            [],
            'Synthetic',
          );
          return {'ok': true};
        });
        final edited = store.read();
        final mutable = mutableOrder(edited.data, orderId)!;
        final batch = (mutable['batches'] as List).first as Map;
        batch['lines'] = (batch['lines'] as List).reversed.toList();
        expect(store.replace(edited.data, edited.revision).ok, true);
        for (final line in asMaps(
          asMaps(current()['batches']).single['lines'],
        )) {
          expect(line['syncId'], lineIds[line['name']]);
        }
        store.dispose();
        store = PosStore(databaseFile: '${folder.path}/pos.sqlite3');
        expect(
          asMaps(
            asMaps(current()['payments']).first['refunds'],
          ).single['syncId'],
          refundId,
        );
        store.deleteOrder(
          orderId,
          store.read().revision,
          'synthetic_archive_order',
          staffId: 1,
          reason: 'Synthetic audit',
        );
        final archived =
            (asMaps(store.read().data['deletedOrders']).single['order'] as Map);
        expect(
          asMaps(archived['payments']).map((p) => p['syncId']),
          paymentIds,
        );
        expect(
          asMaps(
            asMaps(archived['batches']).single['lines'],
          ).map((l) => l['syncId']).toSet(),
          lineIds.values.toSet(),
        );
      } finally {
        probe.close();
        store.dispose();
        folder.deleteSync(recursive: true);
      }
    },
  );

  test(
    'cloud order audit retains the action without local customer contact data',
    () {
      final state = emptyPosState()
        ..['settings'] = {'receiptPolicy': 'onPayment'};
      final order = newLocalOrder(
        state: state,
        source: 'Gel-Al',
        table: null,
        cashier: 'Synthetic',
        staffId: 1,
        productLines: [
          {'name': 'Synthetic item', 'price': 12.34, 'qty': 1},
        ],
        customer: {
          'name': 'SyntheticPrivateCustomer',
          'phone': '05551234567',
          'time': '12:30',
        },
      );
      (order['events'] as List).add(
        'Müşteri kaydı ile eşleştirildi · SyntheticPrivateCustomer · 2026-11-27T12:00:00Z',
      );
      (order['events'] as List).add('Synthetic note 05551234567');
      final encoded = jsonEncode(projectRow('orders', order));
      expect(encoded, isNot(contains('SyntheticPrivateCustomer')));
      expect(encoded, isNot(contains('05551234567')));
      expect(encoded, contains('Müşteri bağlantısı değiştirildi'));
      expect(order['customer']['name'], 'SyntheticPrivateCustomer');
    },
  );
}
