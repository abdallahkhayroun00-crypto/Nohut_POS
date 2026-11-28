import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/cloud_finance_serializer.dart';
import 'package:nohut_falafel_desktop/finance_logic.dart';
import 'package:nohut_falafel_desktop/payroll.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/sync_outbox.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('authoritative partial/mixed payroll and reversal preserve IDs and exact facts', () {
    final dir = Directory.systemTemp.createTempSync('nohut-payroll-sync');
    final store = PosStore(databaseFile: '${dir.path}/db');
    final db = sqlite3.open(store.filePath);
    addTearDown(() { db.dispose(); store.dispose(); dir.deleteSync(recursive: true); });
    final state = store.read();
    state.data['employees'] = [{'id': 2, 'name': 'Synthetic staff', 'active': true}];
    expect(store.replace(state.data, state.revision).ok, true);
    enableOutbox(db);
    final payload = {'employeeId': 2, 'weekStart': '2026-11-23', 'paidOn': '2026-11-30',
      'method': 'Karma', 'cashCents': 30000, 'bankCents': 50000, 'requestId': 'synthetic-payment'};
    final now = DateTime.utc(2026, 11, 30, 10);
    store.command('synthetic-payroll', {}, (s) {
      final first = recordPayrollPayment(s, payload, by: 'Synthetic manager', now: now);
      expect(recordPayrollPayment(s, payload, by: 'Synthetic manager', now: now)['id'], first['id']);
      acknowledgeUnpaid(s, {'employeeId': 2, 'weekStart': '2026-11-23'}, by: 'Synthetic manager', now: now);
      reversePayrollPayment(s, {'id': first['id'], 'reason': 'Synthetic correction'}, by: 'Synthetic manager', now: now);
      return {'ok': true};
    });
    final raw = jsonDecode(pendingOutbox(db).single['payload_json'] as String) as Map;
    expect((raw['payrollPayments'] as List), hasLength(2));
    final ids = CloudIdentityMap(db);
    final rows = serializeFinance(Map<String,dynamic>.from(raw), ids);
    final payments = rows.where((r) => r.table=='payroll_payments').toList();
    expect(payments.map((r) => r.data['amount_kurus']), [80000, -80000]);
    expect(payments.last.data['reverses_id'], payments.first.data['payment_id']);
    expect(payments.last.data['cash_kurus'], -30000);
    expect(payments.last.data['bank_kurus'], -50000);
    expect(rows.where((r) => r.table=='payroll_reviews').single.data['state'], 'Ödenmedi');
    expect(serializeFinance(financeBook(store.read().data), ids).map((r) => r.toJson()).toList(),
        rows.map((r) => r.toJson()).toList());
  });
}
