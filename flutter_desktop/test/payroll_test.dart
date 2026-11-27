import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/finance_logic.dart';
import 'package:nohut_falafel_desktop/finance_sync_server.dart';
import 'package:nohut_falafel_desktop/local_accounts.dart';
import 'package:nohut_falafel_desktop/notification_events.dart';
import 'package:nohut_falafel_desktop/payroll.dart';
import 'package:nohut_falafel_desktop/payroll_reminders.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/workforce.dart';

void main() {
  late Directory dir;
  late PosStore store;
  late int ayse, mehmet;
  const week = '2026-11-16'; // Mon; payday Mon 2026-11-23
  final friday = DateTime.utc(2026, 11, 20, 12);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nohut-payroll');
    store = PosStore(databaseFile: '${dir.path}/db');
    final people = asMaps(store.read().data['employees']);
    ayse = people[0]['id'] as int;
    mehmet = people[1]['id'] as int;
    // Keep two active employees only, so reminder counts are exact.
    final s = store.read();
    for (final e in (s.data['employees'] as List).cast<Map>().skip(2)) {
      e['active'] = false;
    }
    store.replace(s.data, s.revision);
  });
  tearDown(() { store.dispose(); dir.deleteSync(recursive: true); });

  void work(int who, String id, String date, String start, String end, {int breakMinutes = 0}) =>
      applyWorkCommand(store, {'requestId': id, 'action': 'work_save', 'date': date, 'start': start,
        'end': end, 'breakMinutes': breakMinutes}, actorId: who, actorName: 'x', now: friday);
  Json mgr(String id, String action, Map<String, dynamic> data) => FinanceSyncServer.managerWrite(store,
      {'requestId': 'req-payroll-$id', 'operation': 'managerWrite', 'action': action, 'data': data, 'actor': 'mudur'});
  Json status(int who, {String today = '2026-11-24'}) =>
      payrollStatus(store.read().data, who, week, today: today);

  test('missing rate is incomplete, never 0 TL; hours are kept', () {
    work(ayse, 'w-0001', '2026-11-17', '10:00', '18:00', breakMinutes: 30);
    final s = status(ayse);
    expect(s['minutes'], 450);
    expect(s['earnedCents'], isNull);
    expect(s['rateComplete'], false);
    expect(s['remainingCents'], isNull);
  });

  test('effective-dated rates: each day uses its own rate; history is append-only', () {
    mgr('rate-00000001', 'payroll_rate', {'employeeId': ayse, 'payType': 'Saatlik', 'rateCents': 10000, 'effectiveFrom': '2026-11-01'});
    mgr('rate-00000002', 'payroll_rate', {'employeeId': ayse, 'payType': 'Saatlik', 'rateCents': 12050, 'effectiveFrom': '2026-11-18'});
    work(ayse, 'w-0101', '2026-11-17', '10:00', '13:00'); // 3h × 100,00
    work(ayse, 'w-0102', '2026-11-18', '10:00', '12:20'); // 140 min × 120,50
    final s = status(ayse);
    // 3×10000 + 140×12050/60 = 30000 + 28116.67 → 58117 (half-up once)
    expect(s['earnedCents'], 58117);
    final e = asMaps(store.read().data['employees']).firstWhere((e) => e['id'] == ayse);
    expect((e['payHistory'] as List).map((h) => h['rateCents']), [10000, 12050]);
    expect(payRateOn(e, '2026-11-17')!.$2, 10000);
    expect(payRateOn(e, '2026-10-01'), isNull, reason: 'no rate before first effective date');
  });

  test('owner acceptance: 8h@100 + 8h@120 = 1760; pay 800 → Kısmen; pay 960 → Ödendi; no retroactive change', () {
    mgr('acc-rate-0001', 'payroll_rate', {'employeeId': ayse, 'payType': 'Saatlik', 'rateCents': 10000, 'effectiveFrom': '2026-11-01'});
    mgr('acc-rate-0002', 'payroll_rate', {'employeeId': ayse, 'payType': 'Saatlik', 'rateCents': 12000, 'effectiveFrom': '2026-11-18'});
    work(ayse, 'acc-w-001', '2026-11-17', '09:00', '17:00'); // 8h × 100 TL
    work(ayse, 'acc-w-002', '2026-11-18', '09:00', '17:00'); // 8h × 120 TL
    expect(status(ayse)['earnedCents'], 176000);
    mgr('acc-pay-0001', 'payroll_payment', {'employeeId': ayse, 'weekStart': week, 'paidOn': '2026-11-23',
      'method': 'Nakit', 'cashCents': 80000});
    var st = status(ayse);
    expect([st['paidCents'], st['remainingCents'], st['financialStatus']], [80000, 96000, 'Kısmen Ödendi']);
    mgr('acc-pay-0002', 'payroll_payment', {'employeeId': ayse, 'weekStart': week, 'paidOn': '2026-11-24',
      'method': 'Havale/EFT', 'bankCents': 96000});
    st = status(ayse);
    expect([st['paidCents'], st['remainingCents'], st['financialStatus']], [176000, 0, 'Ödendi']);
    // A rate back-dated into a paid week is refused; the week stays as paid.
    expect(() => mgr('acc-rate-0009', 'payroll_rate', {'employeeId': ayse, 'payType': 'Saatlik',
      'rateCents': 20000, 'effectiveFrom': '2026-11-20'}), throwsA(isA<PayrollConflict>()));
    expect(status(ayse)['earnedCents'], 176000);
    // A later raise does not change this week's earnings.
    mgr('acc-rate-0003', 'payroll_rate', {'employeeId': ayse, 'payType': 'Saatlik', 'rateCents': 15000, 'effectiveFrom': '2026-11-25'});
    expect(status(ayse)['earnedCents'], 176000);
    expect(status(ayse)['financialStatus'], 'Ödendi');
  });

  test('partial, mixed and full payments; status derived; reversal audited; no double count', () {
    mgr('rate-00000101', 'payroll_rate', {'employeeId': ayse, 'payType': 'Saatlik', 'rateCents': 15000, 'effectiveFrom': '2026-11-01'});
    work(ayse, 'w-0201', '2026-11-17', '10:00', '18:00'); // 8h → 1200,00
    expect(status(ayse)['financialStatus'], 'Ödenmedi');
    expect(status(ayse)['reviewStatus'], 'Belirtilmedi');
    expect(status(ayse)['overdue'], true);
    mgr('pay-000000001', 'payroll_payment', {'employeeId': ayse, 'weekStart': week, 'kind': 'Avans',
      'method': 'Nakit', 'cashCents': 20000, 'paidOn': '2026-11-19'});
    expect(status(ayse)['financialStatus'], 'Kısmen Ödendi');
    expect(status(ayse)['remainingCents'], 100000);
    expect(() => mgr('pay-000000002', 'payroll_payment', {'employeeId': ayse, 'weekStart': week,
      'method': 'Karma', 'cashCents': 50000, 'bankCents': 0, 'paidOn': '2026-11-20'}), throwsFormatException);
    mgr('pay-000000003', 'payroll_payment', {'employeeId': ayse, 'weekStart': week,
      'method': 'Karma', 'cashCents': 50000, 'bankCents': 50000, 'paidOn': '2026-11-20', 'expectedPaidCents': 20000});
    // Retry of the same request (lost ACK) records once.
    mgr('pay-000000003', 'payroll_payment', {'employeeId': ayse, 'weekStart': week,
      'method': 'Karma', 'cashCents': 50000, 'bankCents': 50000, 'paidOn': '2026-11-20', 'expectedPaidCents': 20000});
    final full = status(ayse);
    expect(full['financialStatus'], 'Ödendi');
    expect(full['paidCents'], 120000);
    expect(full['resolved'], true);
    // Stale screen (expected 20000 paid) cannot add another payment.
    expect(() => mgr('pay-000000004', 'payroll_payment', {'employeeId': ayse, 'weekStart': week,
      'method': 'Nakit', 'cashCents': 100, 'paidOn': '2026-11-20', 'expectedPaidCents': 20000}),
      throwsA(isA<FinanceVersionConflict>()));
    // Monthly expense = net payments once (Nov, week ends 22nd).
    expect(financeMonthSummary(store.read().data, '2026-11').payrollCents, 120000);
    // Correction by reversal, never edit.
    final pid = financeRows(store.read().data, 'payrollPayments').last['id'];
    mgr('rev-000000001', 'payroll_reverse', {'id': pid, 'reason': 'Yanlış tutar'});
    expect(() => mgr('rev-000000002', 'payroll_reverse', {'id': pid, 'reason': 'tekrar'}), throwsA(isA<PayrollConflict>()));
    expect(status(ayse)['financialStatus'], 'Kısmen Ödendi');
    expect(financeRows(store.read().data, 'payrollPayments'), hasLength(3));
    expect(financeMonthSummary(store.read().data, '2026-11').payrollCents, 20000);
    // Paid-hours edit: more hours later reopens the balance.
    final rec = asMaps(store.read().data['shifts']).single;
    applyWorkCommand(store, {'requestId': 'w-0202', 'action': 'work_save', 'id': rec['id'],
      'expectedUpdatedAt': rec['updatedAt'], 'date': '2026-11-17', 'start': '09:00', 'end': '18:00'},
      actorId: ayse, actorName: 'x', now: friday.add(const Duration(minutes: 1)));
    expect(status(ayse)['earnedCents'], 135000);
    expect(status(ayse)['remainingCents'], 115000);
  });

  test('legacy weeklyPayroll weeks refuse ledger payments (no double counting)', () {
    final s = store.read();
    saveEmployeePay(s.data, mehmet, 'Saatlik', 10000);
    saveWeeklyPayroll(s.data, employeeId: mehmet, weekStart: week, workedMinutes: 600);
    store.replace(s.data, s.revision);
    expect(() => mgr('pay-000000101', 'payroll_payment', {'employeeId': mehmet, 'weekStart': week,
      'method': 'Nakit', 'cashCents': 100, 'paidOn': '2026-11-20'}), throwsA(isA<PayrollConflict>()));
    expect(status(mehmet)['legacy'], true);
  });

  test('explicit Ödenmedi is review, not money; reminders keep running while owed', () {
    mgr('rate-00000301', 'payroll_rate', {'employeeId': ayse, 'payType': 'Haftalık Sabit', 'rateCents': 500000, 'effectiveFrom': '2026-11-02'});
    work(ayse, 'w-0301', '2026-11-17', '10:00', '12:00');
    expect(status(ayse)['earnedCents'], 500000);
    mgr('ack-000000001', 'payroll_unpaid', {'employeeId': ayse, 'weekStart': week});
    final s = status(ayse);
    expect(s['reviewStatus'], 'Ödenmedi (belirtildi)');
    expect(s['financialStatus'], 'Ödenmedi');
    expect(s['paidCents'], 0);
    expect(s['resolved'], false);
  });

  test('native Yönetici payroll (ownerPayroll) shows the same rows and money as the LAN page', () {
    mgr('own-rate-0001', 'payroll_rate', {'employeeId': ayse, 'payType': 'Saatlik', 'rateCents': 10000, 'effectiveFrom': '2026-11-01'});
    mgr('own-rate-0002', 'payroll_rate', {'employeeId': ayse, 'payType': 'Saatlik', 'rateCents': 12000, 'effectiveFrom': '2026-11-18'});
    work(ayse, 'own-w-001', '2026-11-17', '09:00', '17:00');
    work(ayse, 'own-w-002', '2026-11-18', '09:00', '17:00');
    mgr('own-pay-0001', 'payroll_payment', {'employeeId': ayse, 'weekStart': week, 'paidOn': '2026-11-23',
      'method': 'Nakit', 'cashCents': 80000, 'expectedPaidCents': 0});
    final now = DateTime.utc(2026, 11, 24, 9);
    // Any day of the week selects its Monday; the owner is excluded by default.
    final v = FinanceSyncServer.ownerPayroll(store, '2026-11-19', ownerIds: [mehmet], now: now);
    expect(v['weekStart'], week);
    final rows = (v['rows'] as List).cast<Map>();
    expect(rows.map((r) => r['employeeId']), isNot(contains(mehmet)));
    final a = rows.firstWhere((r) => r['employeeId'] == ayse);
    expect(a, payrollWeek(store.read().data, week, today: '2026-11-24').firstWhere((r) => r['employeeId'] == ayse));
    expect([a['earnedCents'], a['paidCents'], a['remainingCents'], a['financialStatus']],
        [176000, 80000, 96000, 'Kısmen Ödendi']);
    expect((v['payments'] as List).single['amountCents'], 80000);
    // No week given: last week (the one being paid out).
    expect(FinanceSyncServer.ownerPayroll(store, '', ownerIds: [mehmet], now: now)['weekStart'], week);
    // A stale screen (it still thinks nothing was paid) cannot pay twice.
    expect(() => mgr('own-pay-0002', 'payroll_payment', {'employeeId': ayse, 'weekStart': week,
      'paidOn': '2026-11-24', 'method': 'Nakit', 'cashCents': 96000, 'expectedPaidCents': 0}),
        throwsA(isA<FinanceVersionConflict>()));
  });

  group('owner business rules (2026-11-27)', () {
    DateTime ist(String day, int h) => instantOf(day, '${h.toString().padLeft(2, '0')}:00');

    test('owner profile is excluded by default, also from Sunday and payday reminders', () {
      // ayse's profile is linked to the owner account; she works, no salary.
      final s = store.read();
      expect(applyOwnerPayrollDefault(s.data, [ayse]), true);
      store.replace(s.data, s.revision);
      work(ayse, 'own-w-001', '2026-11-17', '10:00', '20:00');
      final rows = payrollWeek(store.read().data, week, today: '2026-11-24');
      expect(rows.map((r) => r['employeeId']), [mehmet]);
      final sunday = payrollReminderEvents(store.read().data, ist('2026-11-22', 19));
      expect(sunday.where((e) => e['recipientEmployeeId'] == ayse), isEmpty);
      // An explicit later choice is never overridden by the default.
      final s2 = store.read();
      setPayrollEligible(s2.data, ayse, true);
      expect(applyOwnerPayrollDefault(s2.data, [ayse]), false);
      store.replace(s2.data, s2.revision);
      expect(payrollWeek(store.read().data, week, today: '2026-11-24').map((r) => r['employeeId']), [ayse, mehmet]);
    });

    test('statuses: Çalışma kaydı yok, Ücret belirlenmedi, never a fake paid/unpaid', () {
      expect(status(mehmet)['financialStatus'], 'Çalışma kaydı yok');
      expect(status(mehmet)['resolved'], true);
      work(mehmet, 'st-w-0001', '2026-11-18', '10:00', '14:00');
      final s = status(mehmet);
      expect(s['financialStatus'], 'Ücret belirlenmedi');
      expect([s['earnedCents'], s['remainingCents']], [null, null]);
    });

    test('payday reminders only for eligible people with real outstanding earnings', () {
      List<Json> payday(DateTime t) => [for (final e in payrollReminderEvents(store.read().data, t))
          if ('${e['eventId']}'.startsWith('payday:')) e];
      work(mehmet, 'pd-w-0001', '2026-11-18', '10:00', '14:00'); // no rate: amount unknown
      expect(payday(ist('2026-11-23', 10)), isEmpty);
      mgr('pd-rate-0001', 'payroll_rate', {'employeeId': mehmet, 'payType': 'Saatlik', 'rateCents': 10000, 'effectiveFrom': '2026-11-01'});
      expect(payday(ist('2026-11-23', 10)), hasLength(1));
      mgr('pd-pay-0001', 'payroll_payment', {'employeeId': mehmet, 'weekStart': week, 'paidOn': '2026-11-23',
        'method': 'Karma', 'cashCents': 10000, 'bankCents': 30000});
      expect(status(mehmet)['financialStatus'], 'Ödendi');
      expect(payday(ist('2026-11-23', 15)), isEmpty);
    });

    test('duplicate payment request after a lost response records one payment', () {
      mgr('dup-rate-0001', 'payroll_rate', {'employeeId': mehmet, 'payType': 'Saatlik', 'rateCents': 10000, 'effectiveFrom': '2026-11-01'});
      work(mehmet, 'dup-w-0001', '2026-11-18', '10:00', '14:00');
      final body = {'employeeId': mehmet, 'weekStart': week, 'paidOn': '2026-11-23', 'method': 'Nakit', 'cashCents': 15000};
      mgr('dup-pay-0001', 'payroll_payment', body);
      mgr('dup-pay-0001', 'payroll_payment', body); // retry with the same request id
      expect(payrollPaymentsFor(store.read().data, mehmet, week), hasLength(1));
      expect(status(mehmet)['financialStatus'], 'Kısmen Ödendi');
    });
  });

  group('reminders', () {
    DateTime ist(String day, int h, [int m = 0]) => instantOf(day, '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}');

    test('Sunday 18:00 / 21:30 to employees with unsubmitted weeks; stops after sending', () {
      work(ayse, 'w-0401', '2026-11-17', '10:00', '12:00');
      List<Json> at(DateTime t) => payrollReminderEvents(store.read().data, t).where((e) => '${e['eventId']}'.startsWith('tsr:')).toList();
      expect(at(ist('2026-11-22', 17, 59)), isEmpty);
      final e18 = at(ist('2026-11-22', 18, 1));
      expect(e18.map((e) => e['recipientEmployeeId']).toSet(), {ayse, mehmet});
      expect(e18.first['title'], 'Haftalık mesainizi gönderin');
      expect('${e18.first}', isNot(contains('₺')));
      // After 21:30 only the latest slot is produced (bounded catch-up).
      expect(at(ist('2026-11-22', 23)).map((e) => e['eventId']).every((id) => '$id'.endsWith(':21:30')), true);
      submitWeek(store, {'requestId': 'week-0401', 'weekStart': week}, actorId: ayse, now: ist('2026-11-22', 19));
      expect(at(ist('2026-11-22', 23)).map((e) => e['recipientEmployeeId']), [mehmet]);
    });

    test('payday Monday 09/14/20 then daily; stop when resolved; one event per slot across restarts', () {
      mgr('rate-00000501', 'payroll_rate', {'employeeId': ayse, 'payType': 'Saatlik', 'rateCents': 10000, 'effectiveFrom': '2026-11-01'});
      work(ayse, 'w-0501', '2026-11-17', '10:00', '12:00');
      List<String> ids(DateTime t) => [for (final e in payrollReminderEvents(store.read().data, t)) if ('${e['eventId']}'.startsWith('payday:')) '${e['eventId']}'];
      expect(ids(ist('2026-11-23', 8, 59)), isEmpty);
      expect(ids(ist('2026-11-23', 9, 5)), ['payday:$week:2026-11-23:09:00']);
      expect(ids(ist('2026-11-23', 20, 30)), ['payday:$week:2026-11-23:20:00']);
      expect(ids(ist('2026-11-24', 9, 1)), ['payday:$week:2026-11-24:09:00']);
      // Durable dedup through the notification history.
      final t = ist('2026-11-23', 9, 5);
      final added = recordOperationalNotifications(store, clock: () => t);
      expect(added.where((id) => id.startsWith('payday:')), hasLength(1));
      expect(recordOperationalNotifications(store, clock: () => t.add(const Duration(minutes: 3))).where((id) => id.startsWith('payday:')), isEmpty);
      final row = asMaps(store.read().data['notifications']).firstWhere((r) => '${r['eventId']}'.startsWith('payday:'));
      expect(row['permission'], 'payroll.manage');
      // Pay in full → reminders stop.
      mgr('pay-000000501', 'payroll_payment', {'employeeId': ayse, 'weekStart': week,
        'method': 'Havale/EFT', 'bankCents': 20000, 'paidOn': '2026-11-23'});
      expect(ids(ist('2026-11-24', 9, 1)), isEmpty);
      // The employee is told privately that a payment was recorded.
      final personal = payrollReminderEvents(store.read().data, ist('2026-11-24', 9, 1))
          .where((e) => '${e['eventId']}'.startsWith('pp:')).single;
      expect(personal['recipientEmployeeId'], ayse);
      expect('${personal['title']}${personal['body']}', isNot(contains('200')));
    });

    test('personal events are visible only to their employee', () async {
      final auth = LocalAuth(store.authDatabase, iterations: 1000);
      await auth.createUser(username: 'sahip', password: 'owner-pass-1', role: 'Yönetici', isOwner: true);
      await auth.createUser(username: 'ayse', password: 'staff-pass-1', role: 'Personel', employeeId: ayse);
      await auth.createUser(username: 'mehmet', password: 'staff-pass-2', role: 'Personel', employeeId: mehmet);
      work(ayse, 'w-0601', '2026-11-17', '10:00', '12:00');
      submitWeek(store, {'requestId': 'week-0601', 'weekStart': week}, actorId: ayse, now: ist('2026-11-22', 17));
      recordOperationalNotifications(store, clock: () => ist('2026-11-22', 18, 5));
      final rows = store.read().data['notifications'] as List;
      final a = await auth.login(username: 'ayse', password: 'staff-pass-1', deviceId: 'dev-ayse-00000001', client: 'personel');
      final m = await auth.login(username: 'mehmet', password: 'staff-pass-2', deviceId: 'dev-mehm-00000001', client: 'personel');
      final forAyse = visibleNotifications(rows, auth, a.context).where((e) => e['category'] == 'personal');
      final forMehmet = visibleNotifications(rows, auth, m.context).where((e) => e['category'] == 'personal');
      expect(forAyse, isEmpty, reason: 'Ayşe already sent her week');
      expect(forMehmet.single['title'], 'Haftalık mesainizi gönderin');
    });
  });

  group('independent review fixes (Gemini, 2026-11-27)', () {
    test('a retried payment request records one row; a different payment under the same id is refused', () {
      final s = store.read();
      setEmployeeRate(s.data, employeeId: ayse, payType: 'Saatlik', rateCents: 10000, effectiveFrom: '2026-11-02', by: 'x');
      final pay = {'requestId': 'req-dup-000000001', 'employeeId': ayse, 'weekStart': week,
        'method': 'Nakit', 'cashCents': 5000, 'paidOn': '2026-11-20'};
      final a = recordPayrollPayment(s.data, pay, by: 'x', now: friday);
      final b = recordPayrollPayment(s.data, Map<String, dynamic>.from(pay), by: 'x', now: friday);
      expect(b['id'], a['id']);
      expect(payrollPaymentsFor(s.data, ayse, week), hasLength(1));
      expect(() => recordPayrollPayment(s.data, {...pay, 'cashCents': 6000}, by: 'x', now: friday),
        throwsA(isA<PayrollConflict>()));
      expect(payrollPaymentsFor(s.data, ayse, week), hasLength(1));
    });

    test('someone who left with unpaid hours stays in payroll and in payday reminders', () {
      mgr('rate-00000901', 'payroll_rate', {'employeeId': mehmet, 'payType': 'Saatlik', 'rateCents': 10000, 'effectiveFrom': '2026-11-02'});
      work(mehmet, 'w-0901', '2026-11-17', '10:00', '14:00');
      final s = store.read();
      for (final e in (s.data['employees'] as List).cast<Map>()) {
        if (e['id'] == mehmet) e['active'] = false;
      }
      store.replace(s.data, s.revision);
      final rows = payrollWeek(store.read().data, week, today: '2026-11-24');
      final row = rows.firstWhere((r) => r['employeeId'] == mehmet);
      expect(row['remainingCents'], 40000);
      final payday = payrollReminderEvents(store.read().data, DateTime.utc(2026, 11, 23, 20));
      expect(payday.where((e) => '${e['eventId']}'.startsWith('payday:$week:')), isNotEmpty);
    });

    test('a switch to or from Haftalık Sabit starts on a Monday; a fixed week pays once', () {
      final s = store.read();
      setEmployeeRate(s.data, employeeId: ayse, payType: 'Saatlik', rateCents: 10000, effectiveFrom: '2026-11-02', by: 'x');
      expect(() => setEmployeeRate(s.data, employeeId: ayse, payType: 'Haftalık Sabit', rateCents: 500000,
        effectiveFrom: '2026-11-18', by: 'x'), throwsFormatException);
      setEmployeeRate(s.data, employeeId: ayse, payType: 'Haftalık Sabit', rateCents: 500000, effectiveFrom: week, by: 'x');
      store.replace(s.data, s.revision);
      work(ayse, 'w-0911', '2026-11-17', '10:00', '18:00');
      work(ayse, 'w-0912', '2026-11-19', '10:00', '18:00');
      expect(status(ayse)['earnedCents'], 500000);
    });

    test('impossible calendar days are refused', () {
      expect(isCalendarDay('2026-02-31'), false);
      expect(isCalendarDay('2026-02-28'), true);
      final s = store.read();
      expect(() => setEmployeeRate(s.data, employeeId: ayse, payType: 'Saatlik', rateCents: 10000,
        effectiveFrom: '2026-02-31', by: 'x'), throwsFormatException);
      expect(() => recordPayrollPayment(s.data, {'requestId': 'req-bad-day-0000001', 'employeeId': ayse,
        'weekStart': week, 'method': 'Nakit', 'cashCents': 100, 'paidOn': '2026-11-31'}, by: 'x', now: friday),
        throwsFormatException);
    });
  });
}
