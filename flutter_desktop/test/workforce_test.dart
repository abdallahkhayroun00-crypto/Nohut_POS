import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/lan_auth_gate.dart';
import 'package:nohut_falafel_desktop/lan_server.dart';
import 'package:nohut_falafel_desktop/local_accounts.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/workforce.dart';

void main() {
  late Directory dir;
  late PosStore store;
  late int ayse, mehmet;
  // Friday 2026-11-20 15:00 Istanbul.
  final now = DateTime.utc(2026, 11, 20, 12);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nohut-workforce');
    store = PosStore(databaseFile: '${dir.path}/db');
    final people = asMaps(store.read().data['employees']);
    ayse = people[0]['id'] as int;
    mehmet = people[1]['id'] as int;
  });
  tearDown(() {
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  Json plan(String id, Map<String, dynamic> p, {int? actor, bool manager = false}) =>
      applyPlanCommand(store, {'requestId': id, 'action': 'plan_save', ...p},
          actorId: actor ?? ayse, actorName: 'ayse', manager: manager, now: now);
  Json work(String id, Map<String, dynamic> p, {int? actor}) =>
      applyWorkCommand(store, {'requestId': id, ...p}, actorId: actor ?? ayse, actorName: 'ayse', now: now);

  group('Vardiya', () {
    test('own future plans, overnight, overlap warning, repeat, no approval', () {
      final r = plan('plan-0001', {'date': '2026-11-21', 'start': '18:00', 'end': '02:00', 'breakMinutes': 30});
      final p = shiftPlansOf(store.read().data).single;
      expect(p['endsNextDay'], true);
      expect(planMinutes(p), 7 * 60 + 30);
      expect(p.containsKey('approved'), false);
      expect(r['ids'], hasLength(1));
      // Overlapping own plan needs confirmation; nothing is saved until then.
      expect(() => plan('plan-0002', {'date': '2026-11-21', 'start': '20:00', 'end': '23:00'}),
          throwsA(isA<OverlapWarning>()));
      expect(shiftPlansOf(store.read().data), hasLength(1));
      plan('plan-0003', {'date': '2026-11-21', 'start': '20:00', 'end': '23:00', 'confirmOverlap': true});
      expect(shiftPlansOf(store.read().data), hasLength(2));
      // A coworker overlapping is fine (no warning).
      plan('plan-0004', {'date': '2026-11-21', 'start': '18:00', 'end': '22:00'}, actor: mehmet);
      // Bounded repeat.
      plan('plan-0005', {'date': '2026-11-23', 'start': '10:00', 'end': '16:00', 'repeatWeeks': 2});
      expect(shiftPlansOf(store.read().data).where((p) => p['start'] == '10:00').map((p) => p['date']),
          ['2026-11-23', '2026-11-30', '2026-12-07']);
      expect(() => plan('plan-0006', {'date': '2026-11-23', 'start': '10:00', 'end': '16:00', 'repeatWeeks': 9}),
          throwsFormatException);
    });

    test('past dates refused for staff; editing others needs shifts.manage; audited', () {
      expect(() => plan('plan-0101', {'date': '2026-11-19', 'start': '10:00', 'end': '16:00'}), throwsFormatException);
      plan('plan-0102', {'date': '2026-11-22', 'start': '10:00', 'end': '16:00'});
      final p = shiftPlansOf(store.read().data).single;
      expect(() => applyPlanCommand(store, {'requestId': 'plan-0103', 'action': 'plan_cancel', 'id': p['id'],
          'expectedUpdatedAt': p['updatedAt'], 'employeeId': ayse}, actorId: mehmet, actorName: 'mehmet', now: now),
          throwsFormatException);
      applyPlanCommand(store, {'requestId': 'plan-0104', 'action': 'plan_save', 'id': p['id'],
          'expectedUpdatedAt': p['updatedAt'], 'employeeId': ayse, 'date': '2026-11-22', 'start': '12:00', 'end': '18:00'},
          actorId: mehmet, actorName: 'mudur', manager: true, now: now);
      final edited = shiftPlansOf(store.read().data).single;
      expect(edited['start'], '12:00');
      expect((edited['history'] as List).single['before']['start'], '10:00');
      expect((edited['history'] as List).single['by'], 'mudur');
      // Stale version is a conflict, not an overwrite.
      expect(() => applyPlanCommand(store, {'requestId': 'plan-0105', 'action': 'plan_cancel', 'id': p['id'],
          'expectedUpdatedAt': p['updatedAt']}, actorId: ayse, actorName: 'ayse', now: now),
          throwsA(isA<WorkforceConflict>()));
    });

    test('shared schedule shows names and times only', () {
      plan('plan-0201', {'date': '2026-11-22', 'start': '10:00', 'end': '16:00', 'note': 'özel not'});
      final seen = sharedSchedule(store.read().data, '2026-11-16', '2026-11-22', viewerId: mehmet).single;
      expect(seen.containsKey('note'), false);
      expect(seen['employeeName'], isNotNull);
      expect(sharedSchedule(store.read().data, '2026-11-16', '2026-11-22', viewerId: ayse).single['note'], 'özel not');
    });

    test('copy last week into this week skips past days and clashes', () {
      plan('plan-0301', {'date': '2026-11-16', 'start': '10:00', 'end': '16:00'}, manager: true);
      plan('plan-0302', {'date': '2026-11-21', 'start': '10:00', 'end': '16:00'});
      plan('plan-0303', {'date': '2026-11-14', 'start': '10:00', 'end': '16:00'}, manager: true);
      // From week of 11-09 → week of 11-16 (staff): 11-14 → 11-21 clashes, others none.
      final r = applyPlanCommand(store, {'requestId': 'plan-0304', 'action': 'plan_copy_week',
        'fromWeekStart': '2026-11-09', 'toWeekStart': '2026-11-16'}, actorId: ayse, actorName: 'ayse', now: now);
      expect(r['ids'], isEmpty);
      expect(r['skipped'], 1);
      final r2 = applyPlanCommand(store, {'requestId': 'plan-0305', 'action': 'plan_copy_week',
        'fromWeekStart': '2026-11-16', 'toWeekStart': '2026-11-23'}, actorId: ayse, actorName: 'ayse', now: now);
      expect(r2['ids'], hasLength(2));
    });
  });

  group('Mesai', () {
    test('manual own entry incl. past day, overnight, break; no future, no overlap', () {
      work('work-0001', {'action': 'work_save', 'date': '2026-11-18', 'start': '17:00', 'end': '01:30', 'breakMinutes': 30});
      final s = store.read().data;
      final rec = asMaps(s['shifts']).single;
      expect(rec['source'], 'manual');
      expect(workMinutes(rec), 8 * 60);
      expect(() => work('work-0002', {'action': 'work_save', 'date': '2026-11-20', 'start': '14:00', 'end': '18:00'}),
          throwsFormatException, reason: 'future end');
      expect(() => work('work-0003', {'action': 'work_save', 'date': '2026-11-18', 'start': '23:00', 'end': '23:59'}),
          throwsFormatException, reason: 'overlap');
      expect(() => work('work-0004', {'action': 'work_save', 'date': '2026-11-17', 'start': '10:00', 'end': '11:00', 'breakMinutes': 60}),
          throwsFormatException, reason: 'break too long');
      // Duplicate request (lost ACK) saves once.
      work('work-0005', {'action': 'work_save', 'date': '2026-11-19', 'start': '10:00', 'end': '14:00'});
      work('work-0005', {'action': 'work_save', 'date': '2026-11-19', 'start': '10:00', 'end': '14:00'});
      expect(asMaps(store.read().data['shifts']), hasLength(2));
    });

    test('edit keeps previous values; void with reason; nothing automatic; own only', () {
      work('work-0101', {'action': 'work_save', 'date': '2026-11-19', 'start': '10:00', 'end': '14:00'});
      final rec = asMaps(store.read().data['shifts']).single;
      work('work-0102', {'action': 'work_save', 'id': rec['id'], 'expectedUpdatedAt': rec['updatedAt'],
        'date': '2026-11-19', 'start': '09:30', 'end': '14:00'});
      final edited = asMaps(store.read().data['shifts']).single;
      expect(hmOf(DateTime.parse('${edited['start']}')), '09:30');
      expect((edited['corrections'] as List).single['before']['start'], rec['start']);
      expect(() => applyWorkCommand(store, {'requestId': 'work-0103', 'action': 'work_void', 'id': rec['id'],
          'expectedUpdatedAt': edited['updatedAt'], 'reason': 'x'}, actorId: mehmet, actorName: 'm', now: now),
          throwsA(isA<WorkforceConflict>()), reason: 'someone else cannot touch it');
      expect(() => work('work-0104', {'action': 'work_void', 'id': rec['id'], 'expectedUpdatedAt': edited['updatedAt']}),
          throwsFormatException, reason: 'reason required');
      work('work-0105', {'action': 'work_void', 'id': rec['id'], 'expectedUpdatedAt': edited['updatedAt'], 'reason': 'Yanlış gün'});
      final voided = asMaps(store.read().data['shifts']).single;
      expect(voided['voided'], true);
      expect(workMinutes(voided), 0);
      // Planned shifts never create actual hours.
      plan('plan-0106', {'date': '2026-11-21', 'start': '10:00', 'end': '16:00'});
      expect(asMaps(store.read().data['shifts']), hasLength(1));
    });

    test('weekly submission: Taslak → Gönderildi → Değişti → resend; no-work week', () {
      String status() => weekStatus(store.read().data, ayse, '2026-11-16')['status'] as String;
      expect(status(), 'Taslak');
      expect(() => submitWeek(store, {'requestId': 'week-0001', 'weekStart': '2026-11-16'}, actorId: ayse, now: now),
          throwsFormatException, reason: 'nothing to send');
      work('work-0201', {'action': 'work_save', 'date': '2026-11-17', 'start': '10:00', 'end': '18:00', 'breakMinutes': 30});
      submitWeek(store, {'requestId': 'week-0002', 'weekStart': '2026-11-16'}, actorId: ayse, now: now);
      expect(status(), 'Gönderildi');
      expect(weekStatus(store.read().data, ayse, '2026-11-16')['minutes'], 450);
      final rec = asMaps(store.read().data['shifts']).single;
      work('work-0202', {'action': 'work_save', 'id': rec['id'], 'expectedUpdatedAt': rec['updatedAt'],
        'date': '2026-11-17', 'start': '10:00', 'end': '19:00', 'breakMinutes': 30},);
      // Edits after sending are allowed, flagged, and need sending again.
      final later = now.add(const Duration(minutes: 1));
      expect(status(), 'Değişti');
      submitWeek(store, {'requestId': 'week-0003', 'weekStart': '2026-11-16'}, actorId: ayse, now: later);
      expect(status(), 'Gönderildi');
      final row = timesheetWeeksOf(store.read().data).single;
      expect((row['history'] as List).map((h) => h['minutes']), [450, 510]);
      // A week without work is marked explicitly, never assumed zero.
      expect(() => submitWeek(store, {'requestId': 'week-0004', 'weekStart': '2026-11-16', 'noWork': true}, actorId: ayse, now: later),
          throwsFormatException);
      submitWeek(store, {'requestId': 'week-0005', 'weekStart': '2026-11-09', 'noWork': true}, actorId: mehmet, now: later);
      expect(weekStatus(store.read().data, mehmet, '2026-11-09')['status'], 'Çalışma yok');
      expect(teamWeek(store.read().data, '2026-11-16').firstWhere((t) => t['employeeId'] == mehmet)['status'], 'Taslak');
    });
  });

  test('LAN /api/work needs an individual login; acting employee comes from the session', () async {
    final auth = LocalAuth(store.authDatabase, iterations: 1000);
    await auth.createUser(username: 'sahip', password: 'owner-pass-1', role: 'Yönetici', isOwner: true);
    await auth.createUser(username: 'ayse', password: 'staff-pass-1', role: 'Personel', employeeId: ayse);
    await auth.createUser(username: 'mudur', password: 'mudur-pass-1', role: 'Müdür', employeeId: mehmet);
    final server = PosLanServer(store, port: 0, staffHtml: '<p>', yoneticiHtml: '<p>', authGate: LanAuthGate(auth));
    await server.start();
    addTearDown(() async { await server.stop(); server.dispose(); });
    Future<(int, Map)> call(String m, String path, {Object? body, String? cookie}) async {
      final c = HttpClient();
      try {
        final r = await c.openUrl(m, Uri.parse('http://127.0.0.1:${server.port}$path'));
        if (cookie != null) r.headers.set(HttpHeaders.cookieHeader, cookie);
        if (body != null) { r.headers.contentType = ContentType.json; r.write(jsonEncode(body)); }
        final res = await r.close();
        return (res.statusCode, jsonDecode(await res.transform(utf8.decoder).join()) as Map);
      } finally { c.close(force: true); }
    }
    Future<String> login(String u, String p, String client) async {
      final c = HttpClient();
      try {
        final r = await c.openUrl('POST', Uri.parse('http://127.0.0.1:${server.port}/api/auth/login'));
        r.headers.contentType = ContentType.json;
        r.write(jsonEncode({'username': u, 'password': p, 'deviceId': 'device-$u-000000', 'client': client}));
        final res = await r.close();
        await res.drain<void>();
        return res.headers.value(HttpHeaders.setCookieHeader)!.split(';').first;
      } finally { c.close(force: true); }
    }
    // Legacy shared panel mode is still on, but /api/work needs a person.
    expect(auth.lanLoginRequired, false);
    expect((await call('GET', '/api/work/week')).$1, 401);
    final staff = await login('ayse', 'staff-pass-1', 'personel');
    final today = dayOf(istanbulNow(DateTime.now()));
    final yesterday = addDays(today, -1);
    // Pretending to be someone else is ignored for actual hours.
    final (w1, b1) = await call('POST', '/api/work/write', cookie: staff, body: {'requestId': 'lan-work-0001',
      'action': 'work_save', 'employeeId': mehmet, 'date': yesterday, 'start': '10:00', 'end': '12:00'});
    expect(w1, 200, reason: '$b1');
    final rec = asMaps(store.read().data['shifts']).single;
    expect(rec['employeeId'], ayse);
    final (wk, wb) = await call('GET', '/api/work/week?weekStart=$yesterday', cookie: staff);
    expect(wk, 200);
    expect(((wb['week'] as Map)['work'] as List), hasLength(1));
    // Asking for another employee's week (hours, pay, rate) returns your own.
    final (spy, sb) = await call('GET', '/api/work/week?weekStart=$yesterday&employeeId=$mehmet', cookie: staff);
    expect(spy, 200);
    expect(((sb['week'] as Map)['employee'] as Map)['id'], ayse);
    expect(sb['self'], true);
    // Staff cannot see the team view or edit another person's plan.
    expect((await call('GET', '/api/work/team', cookie: staff)).$1, 403);
    final (p1, _) = await call('POST', '/api/work/write', cookie: staff, body: {'requestId': 'lan-plan-0001',
      'action': 'plan_save', 'employeeId': mehmet, 'date': addDays(today, 1), 'start': '10:00', 'end': '12:00'});
    expect(p1, 422);
    final manager = await login('mudur', 'mudur-pass-1', 'yonetici');
    final (t, tb) = await call('GET', '/api/work/team?client=yonetici', cookie: manager);
    expect(t, 200);
    expect((tb['team'] as List).firstWhere((r) => r['employeeId'] == ayse)['minutes'], 120);
    // Overlap returns a confirmable warning.
    await call('POST', '/api/work/write', cookie: staff, body: {'requestId': 'lan-plan-0002',
      'action': 'plan_save', 'date': addDays(today, 1), 'start': '10:00', 'end': '14:00'});
    final (o, ob) = await call('POST', '/api/work/write', cookie: staff, body: {'requestId': 'lan-plan-0003',
      'action': 'plan_save', 'date': addDays(today, 1), 'start': '12:00', 'end': '16:00'});
    expect(o, 409);
    expect(ob['error'], 'overlap');
  });

  test('impossible calendar days are refused for Vardiya and Mesai', () {
    expect(() => plan('plan-bad-day-01', {'date': '2026-02-31', 'start': '10:00', 'end': '12:00'}), throwsFormatException);
    expect(() => work('work-bad-day-01', {'action': 'work_save', 'date': '2026-11-31', 'start': '10:00', 'end': '12:00'}),
        throwsFormatException);
    expect(shiftPlansOf(store.read().data), isEmpty);
  });
}
