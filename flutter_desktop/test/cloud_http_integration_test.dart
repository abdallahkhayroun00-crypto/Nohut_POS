// Real Dart serializer -> HTTP RPC boundary -> PostgreSQL -> Windows command
// -> confirmed app status. The bridge is synthetic/local-only, never deployed.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
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
import 'package:nohut_falafel_desktop/workforce.dart';
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
          (s['employees'] as List).add({'id': 2, 'name': 'Synthetic payroll staff', 'active': true});
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
        for (final action in ['pay', 'payMixed', 'payProducts']) {
          late int targetOrder;
          store.command('synthetic-attribution-$action', {}, (s) {
            targetOrder = newLocalOrder(state: s, source: 'Gel-Al', staffId: 1,
              cashier: 'Synthetic Employee', productLines: [{'name': 'Synthetic attribution item', 'price': 10, 'qty': 1}],
              customer: {})['id'] as int;
            return {'ok': true};
          });
          expect(await sync.flush(), greaterThan(0), reason: sync.status().lastError);
          final paymentRequest = '90000000-0000-4000-8000-00000000000${['pay', 'payMixed', 'payProducts'].indexOf(action)+2}';
          final paymentContext = {...context, 'p_request_id': paymentRequest};
          final payload = <String,Object?>{'expectedRevision': store.read().revision, 'orderId': targetOrder,
            'action': action, 'amountCents': 1000, 'confirmed': true};
          if (action=='payMixed') {
            payload.addAll({'cashCents': 400, 'receivedCents': 400, 'printReceipt': false});
          } else {
            payload['method'] = 'Kart';
            if (action=='pay') payload['printReceipt'] = false;
            if (action=='payProducts') payload['shares'] = {checkLines(mutableOrder(store.read().data,targetOrder)!).first.key: 1000};
          }
          final enqueue = {...paymentContext, 'p_action': 'record_payment', 'p_payload': payload};
          expect((await call('/rest/v1/rpc/nohut_enqueue_command',enqueue,true))['status'], 'accepted');
          expect(await worker.runOnce(), 1, reason: '${worker.lastError}');
          expect((await call('/rest/v1/rpc/nohut_command_status',paymentContext,true))['state'], 'confirmed');
          final payments = (mutableOrder(store.read().data,targetOrder)!['payments'] as List).cast<Map>();
          expect(payments.every((p) => p['staffId']==1), true);
          final count = payments.length;
          await call('/rest/v1/rpc/nohut_enqueue_command',enqueue,true);
          expect(await worker.runOnce(), 0);
          expect((mutableOrder(store.read().data,targetOrder)!['payments'] as List), hasLength(count));
          expect(await sync.flush(), greaterThan(0), reason: sync.status().lastError);
        }
        expect((await call('/test/inspect'))['session_collector_payments'], 4);
        final workNow = DateTime.utc(2026, 11, 24, 12);
        final planned = applyPlanCommand(store, {'action': 'plan_save', 'requestId': 'synthetic-plan',
          'date': '2026-11-27', 'start': '22:00', 'end': '06:00', 'breakMinutes': 60, 'repeatWeeks': 1},
          actorId: 2, actorName: 'Synthetic payroll staff', now: workNow);
        await call('/test/lose-next-ingest-ack');
        expect(await sync.flush(), 0);
        now = now.add(const Duration(seconds: 4));
        expect(await sync.flush(), greaterThan(0));
        expect((await call('/test/inspect'))['planned_count'], 2);
        final plannedId = (planned['ids'] as List).first;
        var planRow = shiftPlansOf(store.read().data).firstWhere((p) => p['id']==plannedId);
        applyPlanCommand(store, {'action': 'plan_save', 'requestId': 'synthetic-plan-edit', 'id': plannedId,
          'expectedUpdatedAt': planRow['updatedAt'], 'date': '2026-11-27', 'start': '22:00', 'end': '07:00', 'breakMinutes': 30},
          actorId: 2, actorName: 'Synthetic payroll staff', now: workNow);
        expect(await sync.flush(), greaterThan(0), reason: sync.status().lastError);
        planRow = shiftPlansOf(store.read().data).firstWhere((p) => p['id']==plannedId);
        applyPlanCommand(store, {'action': 'plan_cancel', 'requestId': 'synthetic-plan-cancel', 'id': plannedId,
          'expectedUpdatedAt': planRow['updatedAt']}, actorId: 2, actorName: 'Synthetic payroll staff', now: workNow);
        applyPlanCommand(store, {'action': 'plan_save', 'requestId': 'synthetic-day-off', 'date': '2026-11-29', 'dayOff': true},
          actorId: 2, actorName: 'Synthetic payroll staff', now: workNow);
        expect(await sync.flush(), greaterThan(0), reason: sync.status().lastError);
        final planFacts = await call('/test/inspect');
        expect(planFacts['planned_count'], 3);
        expect(planFacts['planned_cancelled'], 1);
        expect(planFacts['planned_history'], 2);
        expect(planFacts['manual_minutes'], '0');
        final manual = applyWorkCommand(store, {'action': 'work_save', 'requestId': 'synthetic-manual',
          'date': '2026-11-23', 'start': '09:00', 'end': '18:00', 'breakMinutes': 60},
          actorId: 2, actorName: 'Synthetic payroll staff', now: workNow);
        expect(await sync.flush(), greaterThan(0), reason: sync.status().lastError);
        expect((await call('/test/inspect'))['manual_minutes'], '480');
        submitWeek(store, {'requestId': 'synthetic-submit', 'weekStart': '2026-11-23'}, actorId: 2, now: workNow);
        await call('/test/lose-next-ingest-ack');
        expect(await sync.flush(), 0);
        now = now.add(const Duration(seconds: 4));
        expect(await sync.flush(), greaterThan(0));
        expect((await call('/test/inspect'))['timesheet_submissions'], 1);
        final editedWork = applyWorkCommand(store, {'action': 'work_save', 'requestId': 'synthetic-manual-edit',
          'id': manual['id'], 'expectedUpdatedAt': manual['updatedAt'], 'date': '2026-11-23',
          'start': '09:00', 'end': '18:00', 'breakMinutes': 30},
          actorId: 2, actorName: 'Synthetic payroll staff', now: workNow);
        expect(await sync.flush(), greaterThan(0), reason: sync.status().lastError);
        expect((await call('/test/inspect'))['manual_minutes'], '510');
        submitWeek(store, {'requestId': 'synthetic-resubmit', 'weekStart': '2026-11-23'}, actorId: 2, now: workNow);
        expect(await sync.flush(), greaterThan(0), reason: sync.status().lastError);
        applyWorkCommand(store, {'action': 'work_void', 'requestId': 'synthetic-manual-void',
          'id': manual['id'], 'expectedUpdatedAt': editedWork['updatedAt'], 'reason': 'Synthetic correction'},
          actorId: 2, actorName: 'Synthetic payroll staff', now: workNow);
        expect(await sync.flush(), greaterThan(0), reason: sync.status().lastError);
        final manualFacts = await call('/test/inspect');
        expect(manualFacts['manual_minutes'], '0');
        expect(manualFacts['manual_corrections'], 2);
        submitWeek(store, {'requestId': 'synthetic-nowork', 'weekStart': '2026-11-23', 'noWork': true}, actorId: 2, now: workNow);
        expect(await sync.flush(), greaterThan(0), reason: sync.status().lastError);
        final submissions = await call('/test/inspect');
        expect(submissions['timesheet_submissions'], 3);
        expect(submissions['submitted_minutes'], [480, 510, 0]);
        final payrollNow = DateTime.utc(2026, 11, 30, 10);
        late String partialPayment;
        store.command('synthetic-payroll-partial', {}, (s) {
          final p = recordPayrollPayment(s, {'employeeId': 2, 'weekStart': '2026-11-23',
            'paidOn': '2026-11-30', 'method': 'Karma', 'cashCents': 30000, 'bankCents': 50000,
            'requestId': 'synthetic-payroll-partial'}, by: 'Synthetic manager', now: payrollNow);
          partialPayment = p['id'] as String;
          acknowledgeUnpaid(s, {'employeeId': 2, 'weekStart': '2026-11-23'}, by: 'Synthetic manager', now: payrollNow);
          return {'ok': true};
        });
        await call('/test/lose-next-ingest-ack');
        expect(await sync.flush(), 0);
        expect((await call('/test/inspect'))['payroll_total'], '80000');
        now = now.add(const Duration(seconds: 4));
        expect(await sync.flush(), greaterThan(0));
        expect((await call('/test/inspect'))['payroll_count'], 1);
        store.command('synthetic-payroll-correction', {}, (s) {
          reversePayrollPayment(s, {'id': partialPayment, 'reason': 'Synthetic correction'}, by: 'Synthetic manager', now: payrollNow);
          recordPayrollPayment(s, {'employeeId': 2, 'weekStart': '2026-11-23', 'paidOn': '2026-11-30',
            'method': 'Havale/EFT', 'bankCents': 176000, 'requestId': 'synthetic-payroll-final'}, by: 'Synthetic manager', now: payrollNow);
          return {'ok': true};
        });
        expect(await sync.flush(), greaterThan(0), reason: sync.status().lastError);
        final payrollFacts = await call('/test/inspect');
        expect(payrollFacts['payroll_count'], 3);
        expect(payrollFacts['payroll_total'], '176000');
        expect(payrollFacts['payroll_reviews'], 1);
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

  test(
    'initial-sync HTTP contract: p_events JSON array accepted, string rejected, activation tolerates omitted dailyReports/notifications',
    () async {
      final url = Uri.parse(base!);
      final client = HttpClient();
      Future<({int status, Map<String, dynamic> body})> rawCall(
        String path,
        Map<String, Object?> args, {
        String? jwt,
      }) async {
        final request = await client.postUrl(url.replace(path: path));
        request.headers.contentType = ContentType.json;
        if (jwt != null) request.headers.set('Authorization', 'Bearer $jwt');
        request.write(jsonEncode(args));
        final response = await request.close();
        final text = await utf8.decoder.bind(response).join();
        return (
          status: response.statusCode,
          body: Map<String, dynamic>.from(jsonDecode(text) as Map),
        );
      }

      try {
        final setupRes = await rawCall('/test/setup', {});
        expect(setupRes.status, 200);
        final setup = setupRes.body;

        // 1. Rotate authority epoch via owner aal2 Windows RPC
        final rotRes = await rawCall(
          '/rest/v1/rpc/nohut_owner_rotate_authority_epoch',
          {
            'p_device_id': setup['windowsDeviceId'],
            'p_permission_version': 1,
            'p_reason': 'synthetic_http_initial_sync_test',
          },
          jwt: 'synthetic-windows-owner-jwt',
        );
        expect(rotRes.status, 200, reason: '${rotRes.body}');
        final newEpoch = rotRes.body['new_authority_epoch'] as String;

        // 2. Enroll fresh scoped Windows agent on the rotated epoch
        final agentToken = List.filled(64, 'b').join();
        final tokenSha = crypto.sha256.convert(utf8.encode(agentToken)).toString();
        final enrollRes = await rawCall(
          '/rest/v1/rpc/nohut_enroll_agent',
          {
            'p_device_id': setup['windowsDeviceId'],
            'p_permission_version': 1,
            'p_epoch': newEpoch,
            'p_request_id': '88888888-8888-4888-8888-888888888881',
            'p_token_sha256': tokenSha,
          },
          jwt: 'synthetic-windows-owner-jwt',
        );
        expect(enrollRes.status, 200, reason: '${enrollRes.body}');

        // 3. Build one canonical employee snapshot batch (omitting dailyReports & notifications)
        const migrationId = '77777777-7777-4777-8777-777777777771';
        const batchId = '77777777-7777-4777-8777-777777777772';
        const eventsCanonical =
            '[{"entity_id":"core","entity_type":"employees","payload":[{"active":true,"id":1,"name":"Synthetic HTTP Staff","payrollEligible":true}]}]';
        final eventsArray = jsonDecode(eventsCanonical) as List;
        final bodySha = crypto.sha256.convert(utf8.encode(eventsCanonical)).toString();
        final manifestLine = 'employees:$batchId:1:$bodySha';
        final manifestSha = crypto.sha256.convert(utf8.encode(manifestLine)).toString();

        // 4. Begin initial sync
        final beginRes = await rawCall(
          '/rest/v1/rpc/nohut_agent_begin_initial_sync',
          {
            'p_token': agentToken,
            'p_migration_id': migrationId,
            'p_snapshot_revision': 12,
            'p_snapshot_seq': 5,
            'p_manifest_sha256': manifestSha,
            'p_backup_verified': true,
          },
        );
        expect(beginRes.status, 200, reason: '${beginRes.body}');
        expect(beginRes.body['status'], 'accepted');

        // 5a. Negative check: sending p_events as a JSON-encoded STRING must be rejected (400)
        final stringRes = await rawCall(
          '/rest/v1/rpc/nohut_agent_upload_snapshot_batch',
          {
            'p_token': agentToken,
            'p_migration_id': migrationId,
            'p_batch_id': batchId,
            'p_category': 'employees',
            'p_item_count': 1,
            'p_body_sha256': bodySha,
            'p_events': eventsCanonical,
          },
        );
        expect(stringRes.status, 400, reason: 'JSON string p_events must be rejected');

        // 5b. Positive check: sending p_events as a JSON ARRAY in PostgREST body succeeds (200)
        final uploadRes = await rawCall(
          '/rest/v1/rpc/nohut_agent_upload_snapshot_batch',
          {
            'p_token': agentToken,
            'p_migration_id': migrationId,
            'p_batch_id': batchId,
            'p_category': 'employees',
            'p_item_count': 1,
            'p_body_sha256': bodySha,
            'p_events': eventsArray,
          },
        );
        expect(uploadRes.status, 200, reason: '${uploadRes.body}');
        expect(uploadRes.body['status'], 'accepted');

        // 6. Activate without any dailyReports or notifications batches
        final actRes = await rawCall(
          '/rest/v1/rpc/nohut_agent_activate_initial_sync',
          {
            'p_token': agentToken,
            'p_migration_id': migrationId,
            'p_expected_batches': 1,
            'p_expected_manifest_sha256': manifestSha,
          },
        );
        expect(actRes.status, 200, reason: '${actRes.body}');
        expect(actRes.body['status'], 'accepted');

        // 7. Verify read RPCs tolerate absent dailyReports and notifications cleanly over HTTP
        final dailyRes = await rawCall(
          '/rest/v1/rpc/nohut_daily_report_view',
          {
            'p_device_id': setup['deviceId'],
            'p_client': 'yonetici',
            'p_permission_version': 1,
            'p_day': '2026-11-28',
          },
          jwt: 'synthetic-user-jwt',
        );
        expect(dailyRes.status, 200, reason: '${dailyRes.body}');
        expect(dailyRes.body['available'], false);

        final notifRes = await rawCall(
          '/rest/v1/rpc/nohut_notifications_list',
          {
            'p_device_id': setup['deviceId'],
            'p_client': 'yonetici',
            'p_permission_version': 1,
            'p_limit': 20,
          },
          jwt: 'synthetic-user-jwt',
        );
        expect(notifRes.status, 200, reason: '${notifRes.body}');
        expect(notifRes.body['items'], isEmpty);
        expect(notifRes.body['unreadCount'], 0);
      } finally {
        client.close(force: true);
      }
    },
    skip: base == null,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
