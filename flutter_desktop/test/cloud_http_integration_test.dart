// Real Dart serializer -> HTTP RPC boundary -> PostgreSQL -> Windows command
// -> confirmed app status. The bridge is synthetic/local-only, never deployed.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/cloud_finance_serializer.dart';
import 'package:nohut_falafel_desktop/cloud_catalog_serializer.dart';
import 'package:nohut_falafel_desktop/cloud_order_serializer.dart';
import 'package:nohut_falafel_desktop/cloud_receipt_serializer.dart';
import 'package:nohut_falafel_desktop/cloud_platform_serializer.dart';
import 'package:nohut_falafel_desktop/cloud_payment_ledger_serializer.dart';
import 'package:nohut_falafel_desktop/card_terminal.dart';
import 'package:nohut_falafel_desktop/group_payments.dart';
import 'package:nohut_falafel_desktop/receipt_printer.dart';
import 'package:nohut_falafel_desktop/operations.dart';
import 'package:nohut_falafel_desktop/order_actions.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/finance_logic.dart';
import 'package:nohut_falafel_desktop/payroll.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/remote_commands.dart';
import 'package:nohut_falafel_desktop/supabase_agent_transport.dart';
import 'package:nohut_falafel_desktop/sync_outbox.dart';
import 'package:nohut_falafel_desktop/sync_worker.dart';
import 'package:nohut_falafel_desktop/windows_agent_setup.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/synthetic_agent_secrets.dart';
import 'support/synthetic_platform_order.dart';
import 'support/synthetic_inpos_gateway.dart';

void main() {
  final base = Platform.environment['NOHUT_TEST_RPC_URL'];
  test(
    'full synthetic HTTP/database sync and command recovery',
    () async {
      final url = Uri.parse(base!);
      expect(url.scheme, 'http');
      expect(url.host, '127.0.0.1');
      final client = HttpClient();
      Future<Map<String, dynamic>> call(
        String path, [
        Map<String, Object?> args = const {},
        bool app = false,
      ]) async {
        final request = await client.postUrl(url.replace(path: path));
        request.headers.contentType = ContentType.json;
        if (app)
          request.headers.set('Authorization', 'Bearer synthetic-user-jwt');
        request.write(jsonEncode(args));
        final response = await request.close();
        final body = await utf8.decoder.bind(response).join();
        expect(response.statusCode, 200, reason: body);
        return Map<String, dynamic>.from(jsonDecode(body) as Map);
      }

      final setup = await call('/test/setup');
      final concurrent = await call('/test/concurrent-enrollment');
      expect(concurrent, {
        'enrollments': 1,
        'live_agents': 1,
        'same_agent': true,
        'session_ok': true,
      });
      final folder = Directory.systemTemp.createTempSync(
        'nohut-http-integration',
      );
      final store = PosStore(databaseFile: '${folder.path}/pos.sqlite3');
      final db = sqlite3.open(store.filePath);
      final agentSetup = WindowsAgentSetup(
        url: url,
        publishableKey: 'sb_publishable_synthetic_test_key',
        deviceId: setup['windowsDeviceId'] as String,
        restaurantId: setup['restaurantId'] as String,
        authorityEpoch: setup['authorityEpoch'] as String,
        accessToken: () async => 'synthetic-windows-owner-jwt',
        secrets: SyntheticAgentSecrets(),
        allowLoopbackHttpForTests: true,
      );
      await call('/test/lose-next-enroll-ack');
      await expectLater(
        agentSetup.enrollOrRotate(permissionVersion: 1),
        throwsA(isA<SyncNetworkException>()),
      );
      final credentials = await agentSetup.enrollOrRotate(permissionVersion: 1);
      expect(
        (await call('/test/inspect'))['enrollments'],
        1,
        reason: 'lost enrollment ACK must not rotate twice',
      );
      final transport = SupabaseAgentTransport(
        credentials,
        allowLoopbackHttpForTests: true,
      );
      var now = DateTime.now().toUtc();
      final identities = CloudIdentityMap(db);
      final sync = SyncWorker(
        db,
        TypedFinanceTransport(
          identities,
          TypedCatalogTransport(
            identities,
            TypedOrderTransport(
              identities,
              TypedReceiptTransport(
                identities,
                TypedPlatformTransport(
                  identities,
                  TypedPaymentLedgerTransport(identities, transport),
                ),
              ),
            ),
          ),
        ),
        clock: () => now,
      );
      try {
        final initial = emptyPosState()
          ..['settings'] = {'receiptPolicy': 'onPayment'}
          ..['employees'] = [
            {
              'id': 1,
              'name': 'Synthetic Initial',
              'role': 'Yönetici',
              'active': true,
            },
          ];
        expect(store.replace(initial, store.read().revision).ok, true);
        setSyncState(
          db,
          'authority_epoch',
          (setup['authorityEpoch'] as String).replaceAll('-', ''),
        );
        enableOutbox(db);
        store.command('synthetic_finance_delta', {}, (s) {
          (s['employees'] as List).first['name'] = 'Synthetic Employee';
          (s['employees'] as List).first['payrollEligible'] = false;
          setEmployeeRate(s, employeeId: 1, payType: 'Saatlik', rateCents: 10000,
              effectiveFrom: '2026-10-01', by: 'Synthetic manager', now: DateTime.utc(2026, 9, 30));
          setEmployeeRate(s, employeeId: 1, payType: 'Saatlik', rateCents: 12000,
              effectiveFrom: '2026-10-02', by: 'Synthetic manager', now: DateTime.utc(2026, 10, 1));
          saveOtherExpense(
            s,
            day: '2026-10-01',
            category: 'Diğer',
            name: 'Synthetic expense',
            amountCents: 12345,
            paymentMethod: 'Nakit',
          );
          s['localMenu'] = [
            {
              'id': 1,
              'name': 'Synthetic falafel',
              'price': 12.34,
              'category': 'wrap',
              'active': true,
              'available': true,
            },
          ];
          s['qrCategories'] = [
            {
              'id': 'wrap',
              'name': {'tr': 'Dürümler', 'ar': 'لفائف'},
              'active': true,
              'order': 1,
            },
          ];
          s['qrCampaigns'] = [
            {
              'id': 'synthetic-offer',
              'title': {'tr': 'Örnek Menü'},
              'price': 25,
              'active': true,
              'items': [
                {'tr': '1 Synthetic falafel'},
              ],
            },
          ];
          return {'ok': true};
        });
        expect(groupPending(db).single.events, hasLength(5));
        await call('/test/lose-next-ingest-ack');
        expect(await sync.flush(), 0);
        expect(pendingOutbox(db), hasLength(5));
        final committed = await call('/test/inspect');
        expect(committed['expenses'], 1);
        expect(committed['expense_kurus'], '12345');
        expect(committed['transactions'], 1);
        now = now.add(const Duration(minutes: 1));
        expect(await sync.flush(), 5);
        expect(pendingOutbox(db), isEmpty);
        expect(
          (await call('/test/inspect'))['transactions'],
          1,
          reason: 'lost ACK must not duplicate finance',
        );
        store.command('synthetic_catalog_reprice', {}, (s) {
          (s['localMenu'] as List).first['price'] = 23.45;
          (s['localMenu'] as List).first['name'] = 'Synthetic renamed falafel';
          return {'ok': true};
        });
        expect(await sync.flush(), 1);
        final catalog = await call('/test/inspect');
        expect(catalog['product_versions'], 2);
        expect(catalog['product_prices'], [
          1234,
          2345,
        ], reason: 'catalog edits must retain old prices');
        store.command('synthetic_catalog_remove', {}, (s) {
          s['localMenu'] = <dynamic>[];
          return {'ok': true};
        });
        expect(await sync.flush(), 1);
        final removed = await call('/test/inspect');
        expect(removed['active_products'], 0);
        expect(removed['product_versions'], 2);
        store.command('synthetic_catalog_return', {}, (s) {
          s['localMenu'] = [
            {
              'id': 1,
              'name': 'Synthetic renamed falafel',
              'price': 23.45,
              'category': 'wrap',
              'active': true,
              'available': true,
            },
          ];
          return {'ok': true};
        });
        expect(await sync.flush(), 1);
        expect((await call('/test/inspect'))['active_products'], 1);

        var orderId = 0;
        store.command('synthetic_order_create', {}, (s) {
          final o = newLocalOrder(
            state: s,
            source: 'Gel-Al',
            table: null,
            cashier: 'Synthetic Employee',
            staffId: 1,
            productLines: [
              {'name': 'Historical synthetic item', 'price': 12.34, 'qty': 2},
              {
                'name': 'Synthetic custom item',
                'price': 20,
                'qty': 1,
                'customItem': true,
                'removed': ['Soğan'],
                'note': 'Synthetic note',
              },
            ],
            customer: {
              'name': 'Private synthetic customer',
              'phone': '05551234567',
              'time': '12:30',
            },
          );
          orderId = o['id'] as int;
          splitEqually(o, 2);
          return {'ok': true};
        });
        expect(await sync.flush(), 1, reason: '${sync.status().lastError}');
        final orderBefore = await call('/test/inspect');
        expect(orderBefore['orders'], 1);
        expect(orderBefore['order_items'], 2);
        expect(orderBefore['order_total'], '4468');
        expect(orderBefore['guest_allocations'], 3);
        store.command('synthetic_order_mixed_payment', {}, (s) {
          recordMixedPayment(mutableOrder(s, orderId)!, 1400, 1000, guestId: 1);
          return {'ok': true};
        });
        await call('/test/lose-next-ingest-ack');
        expect(await sync.flush(), 0);
        now = now.add(const Duration(minutes: 1));
        expect(await sync.flush(), 1);
        final payment = await call('/test/inspect');
        expect(payment['payments'], 2);
        expect(payment['order_paid'], '1400');
        expect(payment['order_due'], '3068');
        store.command('synthetic_order_refund', {}, (s) {
          refundPayment(mutableOrder(s, orderId)!, 0, 100, 'Synthetic refund');
          return {'ok': true};
        });
        expect(await sync.flush(), 1);
        final refunded = await call('/test/inspect');
        expect(refunded['refunds'], 1);
        expect(refunded['order_paid'], '1300');
        expect(refunded['order_due'], '3168');
        store.command('synthetic_order_edit', {}, (s) {
          editLocalLine(
            mutableOrder(s, orderId)!,
            '1:0',
            2,
            'Synthetic corrected note',
            [],
            'Synthetic Employee',
            adjustmentCents: 100,
          );
          return {'ok': true};
        });
        expect(await sync.flush(), 1);
        final edited = await call('/test/inspect');
        expect(edited['order_total'], '4668');
        expect(edited['line_edits'], 1);
        expect(edited['historical_sale_prices'], [1234, 1334, 2000]);
        store.command('synthetic_payment_receipt', {}, (s) {
          (s['settings'] as Map)['printerName'] = 'Synthetic printer';
          queuePaymentReceipt(
            s,
            mutableOrder(s, orderId)!,
            requestId: 'synthetic_payment_receipt',
          );
          return {'ok': true};
        });
        expect(await sync.flush(), 1, reason: '${sync.status().lastError}');
        var prints = 0;
        final printer = ReceiptPrinter(
          store,
          transport: (text, name) async {
            prints++;
            expect(text, contains('Private synthetic customer'));
            if (prints == 1)
              throw const SocketException('Synthetic uncertain print');
          },
        );
        try {
          await printer.pump();
          expect(await sync.flush(), 2, reason: '${sync.status().lastError}');
          await printer.pump();
          expect(prints, 1);
          retryAmbiguousPrint(store, {
            'requestId': 'synthetic_payment_reprint',
            'target': 'payment',
            'receiptRequestId': 'synthetic_payment_receipt',
            'checked': true,
          });
          expect(await sync.flush(), 1, reason: '${sync.status().lastError}');
          await printer.pump();
          expect(await sync.flush(), 2, reason: '${sync.status().lastError}');
          final receipt = await call('/test/inspect');
          expect(receipt['receipt_snapshots'], 1);
          expect(receipt['print_jobs'], 1);
          expect(receipt['print_events'], 6);
          expect(receipt['print_status'], 'spooled');
          expect(receipt['receipt_body'], contains('Toplam 46,68'));
          expect(
            receipt['receipt_body'],
            isNot(contains('Private synthetic customer')),
          );
          expect(receipt['receipt_body'], isNot(contains('05551234567')));
        } finally {
          printer.dispose();
        }
        store.deleteOrder(
          orderId,
          store.read().revision,
          'synthetic_order_archive',
          staffId: 1,
          reason: 'Synthetic audit',
        );
        expect(await sync.flush(), 2, reason: '${sync.status().lastError}');
        final archived = await call('/test/inspect');
        expect(archived['deleted_orders'], 1);
        expect(archived['deletion_audits'], 1);
        expect(archived['payments'], 2);
        expect(archived['refunds'], 1);
        expect(archived['order_items'], 2);
        expect(archived['print_jobs'], 1);
        expect(archived['print_events'], 6);
        store.command('synthetic_platform_import', {}, (s) {
          s['trendyolGoOrders'] = [syntheticPlatformOrder()];
          return {'ok': true};
        });
        expect(await sync.flush(), 1, reason: '${sync.status().lastError}');
        final imported = await call('/test/inspect');
        expect(imported['platform_records'], 1);
        expect(imported['platform_versions'], 1);
        expect(imported['platform_line_versions'], 3);
        expect(imported['platform_cancelled_qty'], '1');
        expect(
          imported['platform_collection_net'],
          null,
          reason: 'order data does not prove bank settlement',
        );
        expect(imported['platform_note'], contains('Sos ayrı olsun'));
        expect(
          imported['platform_note'],
          isNot(contains('Private PlatformCustomer')),
        );
        expect(imported['platform_note'], isNot(contains('0850 000 0000')));
        store.command('synthetic_platform_delivered', {}, (s) {
          final o = (s['trendyolGoOrders'] as List).single as Map;
          o['status'] = 'Delivered';
          o['modifiedAt'] = '2026-11-27T12:01:00Z';
          return {'ok': true};
        });
        expect(await sync.flush(), 1, reason: '${sync.status().lastError}');
        store.command('synthetic_platform_correction', {}, (s) {
          final o = (s['trendyolGoOrders'] as List).single as Map;
          (o['lineFacts'] as List).first['unitPriceCents'] = 1500;
          (o['lines'] as List).first['unitPriceCents'] = 1500;
          o['totalCents'] = 2200;
          o['modifiedAt'] = '2026-11-27T12:02:00Z';
          return {'ok': true};
        });
        await call('/test/lose-next-ingest-ack');
        expect(await sync.flush(), 0);
        now = now.add(const Duration(minutes: 1));
        expect(await sync.flush(), 1);
        final history = await call('/test/inspect');
        expect(history['platform_records'], 1);
        expect(history['platform_versions'], 3);
        expect(history['platform_line_versions'], 9);
        expect(history['platform_first_total'], '2000');
        expect(history['platform_current_total'], '2200');
        expect(history['platform_current_sales_eligible'], true);
        store.command('synthetic_platform_supplier_isolation', {}, (s) {
          (s['trendyolGoOrders'] as List).add(
            syntheticPlatformOrder(supplier: '999'),
          );
          return {'ok': true};
        });
        expect(await sync.flush(), 1, reason: '${sync.status().lastError}');
        expect((await call('/test/inspect'))['platform_records'], 2);
        final ledgerOrders = <int>[];
        store.command('synthetic_auxiliary_ledger_sources', {}, (s) {
          openCash(s, 10000);
          moveCash(s, -200, 'Synthetic cash movement');
          for (final price in [10, 20, 10]) {
            ledgerOrders.add(
              newLocalOrder(
                    state: s,
                    source: 'Gel-Al',
                    table: null,
                    cashier: 'Synthetic Employee',
                    staffId: 1,
                    productLines: [
                      {
                        'name': 'Synthetic ledger item',
                        'price': price,
                        'qty': 1,
                      },
                    ],
                    customer: {
                      'id': 12,
                      'name': 'Private ledger customer',
                      'phone': '05559876543',
                    },
                  )['id']
                  as int,
            );
          }
          return {'ok': true};
        });
        expect(
          await sync.flush(),
          greaterThanOrEqualTo(4),
          reason: '${sync.status().lastError}',
        );
        store.command('synthetic_combined_ledger_payment', {}, (s) {
          recordCombinedPickupPayment(
            s,
            orderIds: ledgerOrders.take(2).toList(),
            amountCents: 3000,
            method: 'Karışık',
            cashCents: 1200,
            receivedCents: 1500,
            transactionId: 'synthetic-combined-reference',
          );
          closeCash(s, 11000);
          return {'ok': true};
        });
        await call('/test/lose-next-ingest-ack');
        expect(await sync.flush(), 0);
        now = now.add(const Duration(minutes: 1));
        expect(await sync.flush(), 4, reason: '${sync.status().lastError}');
        final combined = await call('/test/inspect');
        expect(combined['combined_groups'], 1);
        expect(combined['combined_members'], 2);
        expect(combined['combined_amount'], '3000');
        expect(combined['combined_cash'], '1200');
        expect(combined['combined_card'], '1800');
        expect(combined['cash_expected'], '11000');
        expect(combined['cash_variance'], '0');
        expect(combined['cash_movements'], 1);
        final gateway = SyntheticInposGateway();
        final coordinator = InposPayments(store, gateway);
        await coordinator.pay(
          ledgerOrders.last,
          1000,
          'synthetic_terminal_reference',
        );
        expect(await sync.flush(), 3, reason: '${sync.status().lastError}');
        await coordinator.pay(
          ledgerOrders.last,
          1000,
          'synthetic_terminal_reference',
        );
        expect(gateway.sends, 1);
        expect(gateway.queries, 1);
        expect(await sync.flush(), 0);
        gateway.reply = const TerminalReply(
          TerminalStatus.approved,
          transactionId: 'synthetic-terminal-transaction',
          amountCents: 1000,
        );
        await coordinator.reconcile('synthetic_terminal_reference');
        expect(await sync.flush(), 2, reason: '${sync.status().lastError}');
        final card = await call('/test/inspect');
        expect(card['terminal_attempts'], 1);
        expect(card['terminal_events'], 4);
        expect(card['terminal_status'], 'approved');
        expect(card['terminal_payments'], 1);
        store.deleteOrder(
          ledgerOrders.last,
          store.read().revision,
          'synthetic_terminal_archive',
          reason: 'Synthetic audit',
        );
        expect(await sync.flush(), 2, reason: '${sync.status().lastError}');
        expect((await call('/test/inspect'))['terminal_events'], 4);

        const requestId = '90000000-0000-4000-8000-000000000001';
        final context = <String, Object?>{
          'p_device_id': setup['deviceId'],
          'p_client': 'yonetici',
          'p_permission_version': 1,
          'p_request_id': requestId,
        };
        expect(
          (await call('/rest/v1/rpc/nohut_enqueue_command', {
            ...context,
            'p_action': 'clock_in_out',
            'p_payload': {'action': 'clockIn'},
          }, true))['status'],
          'accepted',
        );
        expect(
          (await call(
            '/rest/v1/rpc/nohut_command_status',
            context,
            true,
          ))['state'],
          'pending',
        );
        final worker = RemoteCommandWorker(store, transport);
        expect(await worker.runOnce(), 1, reason: '${worker.lastError}');
        expect((store.read().data['shifts'] as List), hasLength(1));
        expect(
          (await call(
            '/rest/v1/rpc/nohut_command_status',
            context,
            true,
          ))['state'],
          'confirmed',
        );
        expect(await worker.runOnce(), 0);
        expect((store.read().data['shifts'] as List), hasLength(1));
        expect(await sync.flush(), greaterThan(0));
        expect(pendingOutbox(db), isEmpty);
        final rotated = await agentSetup.enrollOrRotate(permissionVersion: 1);
        final wageFacts = await call('/test/inspect');
        expect(wageFacts['wage_rates'], [10000, 12000]);
        expect(wageFacts['payroll_eligible'], false);
        expect(rotated.token, isNot(credentials.token));
        await expectLater(
          transport.checkpoint(),
          throwsA(isA<AgentTransportException>()),
        );
        final replacement = SupabaseAgentTransport(
          rotated,
          allowLoopbackHttpForTests: true,
        );
        try {
          expect(
            (await replacement.checkpoint())['last_acked_seq'],
            greaterThan(0),
          );
          expect((await call('/test/inspect'))['enrollments'], 2);
          await agentSetup.revoke(permissionVersion: 1);
          await expectLater(
            replacement.checkpoint(),
            throwsA(isA<AgentTransportException>()),
          );
          expect((await call('/test/inspect'))['live_agents'], 0);
        } finally {
          replacement.close();
        }
      } finally {
        agentSetup.close();
        sync.dispose();
        transport.close();
        db.close();
        store.dispose();
        client.close(force: true);
        folder.deleteSync(recursive: true);
      }
    },
    skip: base == null,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
