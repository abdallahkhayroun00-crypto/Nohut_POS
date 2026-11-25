import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_core/finance_wire.dart';
import 'package:nohut_falafel_desktop/finance_logic.dart';
import 'package:nohut_falafel_desktop/finance_sync_server.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';

void main() {
  test('manager commands use existing payroll and finance rules and reject stale writes', () {
    final dir = Directory.systemTemp.createTempSync('nohut-manager-finance-test');
    final store = PosStore(databaseFile: dir.path + '/test.sqlite3');
    addTearDown(() { store.dispose(); dir.deleteSync(recursive: true); });
    final initial = store.read();
    saveEmployeePay(initial.data, 1, 'Saatlik', 10000);
    expect(store.replace(initial.data, initial.revision).ok, true);
    final payroll = <String, dynamic>{
      'requestId': 'manager_payroll_test_123456',
      'operation': 'managerWrite', 'action': 'payroll_save',
      'data': {'employeeId': 1, 'weekStart': '2026-11-16',
        'expectedVersion': null, 'expectedRate': 10000,
        'expectedPayType': 'Saatlik', 'workedMinutes': 2400,
        'bonusCents': 10000, 'advanceCents': 5000, 'paid': false},
    };
    final first = FinanceSyncServer.managerWrite(store, payroll);
    expect(FinanceSyncServer.managerWrite(store, payroll), first);
    final pay = financeRows(store.read().data, 'weeklyPayroll').single;
    expect(pay['grossCents'], 410000);
    expect(pay['payableCents'], 405000);
    expect(() => FinanceSyncServer.managerWrite(store,
      {...payroll, 'requestId': 'manager_payroll_stale_123456'}),
      throwsA(isA<FinanceVersionConflict>()));
    final other = <String, dynamic>{
      'requestId': 'manager_other_test_123456',
      'operation': 'managerWrite', 'action': 'other_create',
      'data': {'date': '2026-11-16', 'category': 'Diğer',
        'name': 'Test', 'amountCents': 5000, 'paymentMethod': 'Nakit'},
    };
    final ack = FinanceSyncServer.managerWrite(store, other);
    expect(FinanceSyncServer.managerWrite(store, other), ack);
    final view = FinanceSyncServer.monthView(store.read().data, '2026-11');
    expect((view['summary'] as Map)['payrollCents'], 410000);
    expect((view['summary'] as Map)['otherCents'], 5000);
    expect((view['weeklyPayroll'] as List).length, 1);
    expect(view.containsKey('orders'), false);
    expect(view.containsKey('settings'), false);
  });

  test('encrypted finance envelopes reject wrong restaurant, key and response context', () async {
    final key = FinanceWire.createKey();
    final payload = <String, dynamic>{'operation': 'pull', 'afterId': 0};
    final envelope = await FinanceWire.seal(key, 'restaurant-a', 'request', payload);
    expect(envelope.containsKey('operation'), false);
    expect(await FinanceWire.open(key, 'restaurant-a', 'request', envelope), payload);
    await expectLater(FinanceWire.open(key, 'restaurant-b', 'request', envelope), throwsA(anything));
    await expectLater(FinanceWire.open(FinanceWire.createKey(), 'restaurant-a', 'request', envelope), throwsA(anything));
    await expectLater(FinanceWire.open(key, 'restaurant-a', 'response:wrong', envelope), throwsA(anything));
    final tampered = {...envelope, 'mac': 'AAAAAAAAAAAAAAAAAAAAAA=='};
    await expectLater(FinanceWire.open(key, 'restaurant-a', 'request', tampered), throwsA(anything));
  });

  test('finance command retries once and stale edits never overwrite PC changes', () {
    final dir = Directory.systemTemp.createTempSync('nohut-finance-sync-test');
    final store = PosStore(databaseFile: dir.path + '/test.sqlite3');
    addTearDown(() { store.dispose(); dir.deleteSync(recursive: true); });
    final payload = <String, dynamic>{
      'requestId': 'expense_test_123456789',
      'operation': 'create',
      'entry': {
        'date': '2026-10-15', 'storeBrand': 'BİM', 'market': 'BİM',
        'paymentMethod': 'Nakit', 'note': '', 'amountsCents': [5000, 6000, 30000],
      },
    };
    final first = FinanceSyncServer.apply(store, payload);
    expect(FinanceSyncServer.apply(store, payload), first);
    final records = financeRows(store.read().data, 'materials');
    expect(records.length, 1);
    expect(records.single['totalCents'], 41000);
    final record = first['record'] as Map;
    final edit = <String, dynamic>{
      'requestId': 'expense_edit_123456789',
      'operation': 'edit', 'recordId': record['id'],
      'expectedUpdatedAt': record['updatedAt'],
      'entry': {...(payload['entry'] as Map), 'amountsCents': [12000]},
    };
    final changed = FinanceSyncServer.apply(store, edit);
    expect(FinanceSyncServer.apply(store, edit), changed);
    expect(financeRows(store.read().data, 'materials').single['totalCents'], 12000);
    expect(() => FinanceSyncServer.apply(store,
      {...edit, 'requestId': 'expense_stale_123456789',
        'expectedUpdatedAt': 'old-version'}), throwsA(isA<FinanceVersionConflict>()));
    expect(financeRows(store.read().data, 'materials').single['totalCents'], 12000);
    final current = changed['record'] as Map;
    final cancel = <String, dynamic>{
      'requestId': 'expense_void_123456789',
      'operation': 'void', 'recordId': current['id'],
      'expectedUpdatedAt': current['updatedAt'],
    };
    final cancelled = FinanceSyncServer.apply(store, cancel);
    expect(FinanceSyncServer.apply(store, cancel), cancelled);
    expect(financeMonthSummary(store.read().data, '2026-10').materialsCents, 0);
  });
}
