// Nested-field registry, runtime validation, cloud allowlist and PII
// replication scan (spec V5.1 §4.4, §19.4, §19.9; owner decisions 3, 4, 6).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/customer_accounts.dart';
import 'package:nohut_falafel_desktop/finance_logic.dart';
import 'package:nohut_falafel_desktop/group_payments.dart';
import 'package:nohut_falafel_desktop/operations.dart';
import 'package:nohut_falafel_desktop/order_actions.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/sync_field_registry.dart';

import 'support/synthetic_pos.dart';

/// A state touched by every writer we can drive without UI or network.
Json kitchenSink() {
  final s = buildSyntheticState(300);
  saveMonthlyFixed(s, category: 'Kira', name: 'Dükkan kirası',
      amountCents: 2500000, startMonth: '2026-01');
  final fixedId = asMaps(financeBook(s)['monthlyFixed']).single['id'] as int;
  markMonthlyFixedPaid(s, fixedId, '2026-01', true);
  saveMonthlyFixed(s, id: fixedId, category: 'Kira', name: 'Dükkan kirası',
      amountCents: 2600000, startMonth: '2026-01');
  saveMaterialPurchase(s, date: '2026-01-05', title: 'Nohut', unit: 'kg',
      quantityMilli: 5000, pricePerUnitCents: 6500, storeBrand: 'BİM');
  saveOtherExpense(s, day: '2026-01-06', category: 'Temizlik',
      name: 'Deterjan', amountCents: 12000, paymentMethod: 'Nakit');
  saveEmployeePay(s, 2, 'Saatlik', 15000);
  saveWeeklyPayroll(s, employeeId: 2, weekStart: '2026-01-05',
      workedMinutes: 2400, bonusCents: 10000, advanceCents: 5000);
  saveManualPlatformIncome(s, source: manualIncomePlatforms.first,
      month: '2025-12', kind: manualIncomeTypes.first, amountCents: 150000);
  openCash(s, 50000);
  closeCash(s, 50000);
  final customerId = savePickupCustomer(s, name: 'Ayşe Kaya',
      phone: '0555 111 22 33');
  // Open Gel-Al account orders paid together (Açık Hesaplar).
  final ids = <int>[];
  for (var i = 0; i < 2; i++) {
    final o = newLocalOrder(state: s, source: 'Gel-Al',
        productLines: [{'productId': 0, 'name': 'Falafel Dürüm', 'price': 160,
          'qty': 1, 'removed': <String>[], 'note': ''}],
        customer: {'id': customerId, 'name': 'Ayşe Kaya',
          'phone': '0555 111 22 33', 'time': ''});
    ids.add(o['id'] as int);
  }
  recordCombinedPickupPayment(s, orderIds: ids, amountCents: 32000,
      method: 'Karışık', cashCents: 12000, receivedCents: 20000);
  recordStaffNotice(s, mutableOrder(s, ids.first)!, 'staff_ks_1', 'Mehmet',
      'Yeni sipariş');
  return s;
}

void main() {
  test('every field written by the real writers is declared', () {
    expect(unregisteredFieldPaths(kitchenSink()), isEmpty);
  });

  test('the runtime guard rejects an undeclared field on commit', () {
    final dir = Directory.systemTemp.createTempSync('nohut-guard');
    final store = PosStore(databaseFile: '${dir.path}/db');
    try {
      final s = store.read().data;
      (s['employees'] as List).first['salaryIban'] = 'TR00';
      expect(() => store.replace(s, store.read().revision),
          throwsA(isA<StateError>()));
    } finally {
      store.dispose();
      dir.deleteSync(recursive: true);
    }
  });

  test('allowlist is declared, and never contains personal contact data', () {
    expect(cloudAllowedFieldPaths.intersection(neverProjectedFieldPaths),
        isEmpty);
    for (final path in cloudAllowedFieldPaths) {
      expect(knownStateFieldPaths.contains(path), true, reason: path);
    }
    for (final path in cloudAllowedFieldPaths) {
      expect(path, isNot(matches(RegExp(r'phone|email|address|hash|secret',
          caseSensitive: false))), reason: path);
    }
  });

  test('cloud projection keeps money and history, drops contact data', () {
    final s = kitchenSink();
    final projected = projectForCloud(s);
    final text = jsonEncode(projected);
    // No phone, address, customer or reviewer names in the projection.
    for (final needle in ['0555', 'Atatürk Mah', 'Gülşen', 'Ayşe',
        'Mehmet Yılmaz', 'Özge']) {
      expect(text, isNot(contains(needle)), reason: needle);
    }
    expect(projected.containsKey('customers'), false);
    expect(projected.containsKey('settings'), false);
    expect(projected.containsKey('mobileDevices'), false);
    // Commercial history is complete: same orders, payments and totals.
    final orders = asMaps(s['orders']), out = asMaps(projected['orders']);
    expect(out.length, orders.length);
    int sum(List<Json> rows) => rows.fold(0, (n, o) => n + orderPaidCents(o));
    expect(sum(out), sum(orders));
    expect(asMaps(projected['trendyolGoOrders']).length,
        asMaps(s['trendyolGoOrders']).length);
    // Açık hesap link survives as a pseudonymous id only.
    final linked = out.where((o) => o['customer'] is Map &&
        (o['customer'] as Map)['id'] != null);
    expect(linked, isNotEmpty);
    expect(linked.first['customer'], {'id': isA<int>()});
  });

  test('PII replication scan: snapshots, audits and notices carry no contact '
      'data', () {
    final s = kitchenSink();
    for (final job in asMaps(s['printJobs'])) {
      final snap = jsonEncode(job['snapshot'] ?? {});
      expect(snap, isNot(contains('0555')));
      expect(snap, isNot(contains('phone')));
      expect('${job['text'] ?? ''}', isNot(contains('0555')));
    }
    for (final key in ['staffNotices', 'tgoOperationAudit', 'combinedPayments',
        'terminalAttempts']) {
      expect(jsonEncode(s[key] ?? []), isNot(contains('0555')), reason: key);
    }
    for (final o in asMaps(s['trendyolGoOrders'])) {
      expect(o.containsKey('customerEmail'), false);
    }
    // Staff command receipts are local-only (never projected); they may hold
    // the Gel-Al phone for idempotency, which is documented policy.
  });
}
