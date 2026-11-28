import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/cloud_workforce_summary.dart';
import 'package:nohut_falafel_desktop/payroll.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/workforce.dart';

void main() {
  test('serializeWorkforceSummaries matches authoritative payrollWeek & ownWeek (owner acceptance + missing rate + owner exclusion + departed)', () {
    final dir = Directory.systemTemp.createTempSync('nohut-wf-summary');
    final store = PosStore(databaseFile: '${dir.path}/pos.sqlite3');
    addTearDown(() {
      store.dispose();
      dir.deleteSync(recursive: true);
    });

    final s0 = store.read();
    s0.data['employees'] = [
      {'id': 1, 'name': 'Synthetic Owner', 'active': true, 'payrollEligible': false},
      {'id': 2, 'name': 'Synthetic Staff A', 'active': true},
      {'id': 3, 'name': 'Synthetic Staff NoRate', 'active': true},
      {'id': 4, 'name': 'Synthetic Departed', 'active': true},
    ];
    expect(store.replace(s0.data, s0.revision).ok, isTrue);

    // Owner acceptance scenario on Staff A (id=2):
    // Mon 2026-11-23: 8h @ 100 TL = 800 TL
    // Wed 2026-11-25: 8h @ 120 TL = 960 TL -> Total 1,760 TL
    final s1 = store.read();
    setEmployeeRate(s1.data, employeeId: 2, payType: 'Saatlik', rateCents: 10000,
        effectiveFrom: '2026-11-23', by: 'Synthetic Owner', now: DateTime.utc(2026, 11, 22));
    setEmployeeRate(s1.data, employeeId: 2, payType: 'Saatlik', rateCents: 12000,
        effectiveFrom: '2026-11-25', by: 'Synthetic Owner', now: DateTime.utc(2026, 11, 24));
    setEmployeeRate(s1.data, employeeId: 4, payType: 'Saatlik', rateCents: 10000,
        effectiveFrom: '2026-11-23', by: 'Synthetic Owner', now: DateTime.utc(2026, 11, 22));
    expect(store.replace(s1.data, s1.revision).ok, isTrue);

    // Manual Mesai entries
    applyWorkCommand(store, {
      'action': 'work_save', 'requestId': 'w-a-1',
      'date': '2026-11-23', 'start': '09:00', 'end': '18:00', 'breakMinutes': 60,
    }, actorId: 2, actorName: 'Synthetic Staff A', now: DateTime.utc(2026, 11, 23, 18));
    applyWorkCommand(store, {
      'action': 'work_save', 'requestId': 'w-a-2',
      'date': '2026-11-25', 'start': '09:00', 'end': '18:00', 'breakMinutes': 60,
    }, actorId: 2, actorName: 'Synthetic Staff A', now: DateTime.utc(2026, 11, 25, 18));
    applyWorkCommand(store, {
      'action': 'work_save', 'requestId': 'w-nr-1',
      'date': '2026-11-23', 'start': '10:00', 'end': '14:00', 'breakMinutes': 0,
    }, actorId: 3, actorName: 'Synthetic Staff NoRate', now: DateTime.utc(2026, 11, 23, 14));
    applyWorkCommand(store, {
      'action': 'work_save', 'requestId': 'w-dep-1',
      'date': '2026-11-23', 'start': '10:00', 'end': '14:00', 'breakMinutes': 0,
    }, actorId: 4, actorName: 'Synthetic Departed', now: DateTime.utc(2026, 11, 23, 14));

    // Deactivate employee 4 after working (departed with unpaid dues)
    final sDep = store.read();
    (sDep.data['employees'] as List).cast<Map>().firstWhere((e) => e['id'] == 4)['active'] = false;
    expect(store.replace(sDep.data, sDep.revision).ok, isTrue);

    // First partial payment 800 TL on Staff A
    store.command('synthetic-pay-a-1', {}, (s) {
      recordPayrollPayment(s, {
        'employeeId': 2, 'weekStart': '2026-11-23', 'paidOn': '2026-11-30',
        'method': 'Nakit', 'cashCents': 80000, 'bankCents': 0, 'requestId': 'synthetic-pp-a-1',
      }, by: 'Synthetic Owner', now: DateTime.utc(2026, 11, 30, 10));
      return {'ok': true};
    });

    final now = DateTime.utc(2026, 11, 30, 12);
    final payload = serializeWorkforceSummaries(store.read().data, now: now, weeks: ['2026-11-23']);
    final rows = (payload['rows'] as List).cast<Map<String, dynamic>>();
    expect(rows, hasLength(4));

    final owner = rows.firstWhere((r) => r['employeeLocalId'] == 1);
    expect(owner['payrollEligible'], isFalse);

    final staffA = rows.firstWhere((r) => r['employeeLocalId'] == 2);
    expect(staffA['workedMinutes'], 960);
    expect(staffA['earnedKurus'], 176000);
    expect(staffA['paidKurus'], 80000);
    expect(staffA['remainingKurus'], 96000);
    expect(staffA['financialStatus'], 'Kısmen Ödendi');

    // Missing wage must stay null, never fabricated 0
    final noRate = rows.firstWhere((r) => r['employeeLocalId'] == 3);
    expect(noRate['workedMinutes'], 240);
    expect(noRate['earnedKurus'], isNull);
    expect(noRate['remainingKurus'], isNull);
    expect(noRate['financialStatus'], 'Ücret belirlenmedi');

    // Departed employee with unpaid hours is retained
    final departed = rows.firstWhere((r) => r['employeeLocalId'] == 4);
    expect(departed['workedMinutes'], 240);
    expect(departed['earnedKurus'], 40000);
    expect(departed['remainingKurus'], 40000);
    expect(departed['financialStatus'], 'Ödenmedi');

    // Second payment 960 TL -> Ödendi, 0 remaining
    store.command('synthetic-pay-a-2', {}, (s) {
      recordPayrollPayment(s, {
        'employeeId': 2, 'weekStart': '2026-11-23', 'paidOn': '2026-11-30',
        'method': 'Havale/EFT', 'cashCents': 0, 'bankCents': 96000, 'requestId': 'synthetic-pp-a-2',
      }, by: 'Synthetic Owner', now: DateTime.utc(2026, 11, 30, 11));
      return {'ok': true};
    });
    final payload2 = serializeWorkforceSummaries(store.read().data, now: now, weeks: ['2026-11-23']);
    final staffA2 = (payload2['rows'] as List).cast<Map<String, dynamic>>().firstWhere((r) => r['employeeLocalId'] == 2);
    expect(staffA2['paidKurus'], 176000);
    expect(staffA2['remainingKurus'], 0);
    expect(staffA2['financialStatus'], 'Ödendi');
  });
}
