/// V6.0 / V6.1 workforce: Vardiya (planned) and Mesai (actual) — both
/// entered manually by the employee, no approvals (spec §24.4, tasks W1/W2).
///
/// * **Vardiya** (`state['shiftPlans']`): an employee adds/edits/cancels their
///   own *future* plan; everyone sees names and times only; a manager with
///   `shifts.manage` may edit anyone's plan (audited in `history`). Planned
///   hours never become actual hours or pay.
/// * **Mesai** (`state['shifts']`, `source: 'manual'`): the employee records
///   their own actual work, including past days. Nothing is created
///   automatically. Edits keep the previous values in `corrections`; a wrong
///   record is voided with a reason, never deleted.
/// * **Haftalık gönderim** (`state['timesheetWeeks']`): Monday–Sunday,
///   Europe/Istanbul. Without a row the week is *Taslak*; "Haftalık
///   Mesailerimi Gönder" stores a snapshot. *Gönderildi* means communicated,
///   not approved. Later edits are allowed and show as *Gönderildi · değişti*
///   until sent again; every submission stays in `history`.
///
/// Every write goes through [PosStore.command] (idempotent request id, one
/// SQLite transaction) and checks the exact prior `updatedAt` on edits.
library;

import 'pos_logic.dart';
import 'pos_store.dart';
import 'shifts.dart' show shiftsOf;

final _day = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _hm = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
const _ist = Duration(hours: 3);

DateTime istanbulNow(DateTime now) => now.toUtc().add(_ist);
String dayOf(DateTime istanbulWall) => istanbulWall.toIso8601String().substring(0, 10);
String istanbulDayOfInstant(DateTime instant) => dayOf(instant.toUtc().add(_ist));

/// `YYYY-MM-DD` that is a real calendar day (rejects 2026-02-31, which
/// DateTime.parse would silently roll over to March).
bool isCalendarDay(Object? v) {
  if (v is! String || !_day.hasMatch(v)) return false;
  final d = DateTime.tryParse(v);
  return d != null && dayOf(d) == v;
}

/// Monday of the Istanbul week that contains [day].
String weekStartOf(String day) {
  final d = DateTime.parse(day);
  return dayOf(d.subtract(Duration(days: d.weekday - DateTime.monday)));
}

String addDays(String day, int n) => dayOf(DateTime.parse(day).add(Duration(days: n)));

/// UTC instant of Istanbul wall time [day] [hm].
DateTime instantOf(String day, String hm) {
  final d = DateTime.parse(day);
  return DateTime.utc(d.year, d.month, d.day, int.parse(hm.substring(0, 2)), int.parse(hm.substring(3)))
      .subtract(_ist);
}

String hmOf(DateTime instant) => instant.toUtc().add(_ist).toIso8601String().substring(11, 16);

class WorkforceConflict implements Exception {
  const WorkforceConflict([this.message = 'Kayıt değişti. Yenileyip tekrar deneyin.']);
  final String message;
  @override
  String toString() => message;
}

/// Overlap warning the client must confirm (`confirmOverlap: true`).
class OverlapWarning implements Exception {
  const OverlapWarning(this.message);
  final String message;
  @override
  String toString() => message;
}

Json _employee(Json state, Object? id) {
  final e = asMaps(state['employees']).where((e) => e['id'] == id && e['active'] != false).firstOrNull;
  if (e == null) throw const FormatException('Aktif personel bulunamadı');
  return e;
}

String _stamp(DateTime now) => now.toUtc().toIso8601String();

/// A new version stamp that is always later than [previous], so a stale
/// `expectedUpdatedAt` can never match even within the same microsecond.
String bumpVersion(Object? previous, DateTime now) => _bump(previous, now);

String _bump(Object? previous, DateTime now) {
  final p = DateTime.tryParse('${previous ?? ''}');
  final t = now.toUtc();
  return p != null && !t.isAfter(p) ? _stamp(p.add(const Duration(microseconds: 1))) : _stamp(t);
}

String _text(Object? v, int max, String field) {
  final t = '${v ?? ''}'.trim();
  if (t.length > max) throw FormatException('$field çok uzun');
  return t;
}

int _break(Object? v, int durationMinutes) {
  final b = v == null || v == '' ? 0 : v is int ? v : int.tryParse('$v');
  if (b == null || b < 0 || b > 600) throw const FormatException('Mola süresi geçersiz');
  if (durationMinutes > 0 && b >= durationMinutes) throw const FormatException('Mola çalışma süresinden uzun olamaz');
  return b;
}

// ---------------------------------------------------------------- Vardiya

List<Json> shiftPlansOf(Json state) => asMaps(state['shiftPlans']);

/// Start/end instants of a plan (overnight when `endsNextDay`).
(DateTime, DateTime) planWindow(Json p) {
  final start = instantOf('${p['date']}', '${p['start']}');
  final endDay = p['endsNextDay'] == true ? addDays('${p['date']}', 1) : '${p['date']}';
  return (start, instantOf(endDay, '${p['end']}'));
}

int planMinutes(Json p) {
  if (p['dayOff'] == true || p['cancelled'] == true) return 0;
  final (a, b) = planWindow(p);
  final m = b.difference(a).inMinutes - ((p['breakMinutes'] as int?) ?? 0);
  return m < 0 ? 0 : m;
}

/// `plan_save` (create/edit, optional bounded `repeatWeeks` 0–8),
/// `plan_cancel`, `plan_copy_week`. [actorId] is the signed-in employee;
/// [manager] = holds `shifts.manage` (may act for another employee and edit
/// past plans).
Json applyPlanCommand(PosStore store, Json payload, {required int? actorId,
    required String actorName, bool manager = false, DateTime? now}) {
  final requestId = payload['requestId'];
  if (requestId is! String) throw const FormatException('İstek kimliği gerekli');
  final clock = (now ?? DateTime.now()).toUtc();
  final today = dayOf(istanbulNow(clock));
  return store.command('wf_$requestId', payload, (s) {
    final targetId = payload['employeeId'] ?? actorId;
    if (targetId == null) throw const FormatException('Hesabınız bir personele bağlı değil');
    if (targetId != actorId && !manager) throw const FormatException('Yalnızca kendi vardiyanızı düzenleyebilirsiniz');
    final emp = _employee(s, targetId);
    final plans = (s['shiftPlans'] ??= <dynamic>[]) as List;
    List<Json> own() => [for (final p in plans.cast<Map>()) if (p['employeeId'] == emp['id'] && p['cancelled'] != true) Map<String, dynamic>.from(p)];
    void audit(Map p, String what, Map? before) {
      ((p['history'] ??= <dynamic>[]) as List).add({
        'at': _stamp(clock), 'by': actorName, 'byId': actorId, 'action': what,
        if (before != null) 'before': {for (final k in ['date', 'start', 'end', 'endsNextDay', 'breakMinutes', 'dayOff', 'note']) k: before[k]},
      });
    }
    Map find(Object? id) {
      final p = plans.cast<Map>().where((x) => x['id'] == id && x['employeeId'] == emp['id']).firstOrNull;
      if (p == null || p['cancelled'] == true) throw const WorkforceConflict('Vardiya bulunamadı');
      if (p['updatedAt'] != payload['expectedUpdatedAt']) throw const WorkforceConflict();
      if (!manager && '${p['date']}'.compareTo(today) < 0) throw const FormatException('Geçmiş vardiya değiştirilemez');
      return p;
    }
    switch (payload['action']) {
      case 'plan_save':
        final date = '${payload['date']}';
        if (!isCalendarDay(date)) throw const FormatException('Tarih geçersiz');
        if (!manager && date.compareTo(today) < 0) throw const FormatException('Vardiya bugün veya ileri bir tarih için girilir');
        if (date.compareTo(addDays(today, 400)) > 0) throw const FormatException('Tarih çok ileri');
        final dayOff = payload['dayOff'] == true;
        final start = dayOff ? '00:00' : '${payload['start']}';
        final end = dayOff ? '00:00' : '${payload['end']}';
        if (!dayOff && (!_hm.hasMatch(start) || !_hm.hasMatch(end))) throw const FormatException('Saat SS:DD olmalı');
        final endsNextDay = !dayOff && end.compareTo(start) <= 0;
        final draft = <String, dynamic>{'date': date, 'start': start, 'end': end,
          'endsNextDay': endsNextDay, 'dayOff': dayOff};
        final span = dayOff ? 0 : planWindow(draft).$2.difference(planWindow(draft).$1).inMinutes;
        if (span > 16 * 60) throw const FormatException('Vardiya 16 saatten uzun olamaz');
        draft['breakMinutes'] = dayOff ? 0 : _break(payload['breakMinutes'], span);
        draft['note'] = _text(payload['note'], 200, 'Not');
        final repeat = payload['repeatWeeks'] is int ? payload['repeatWeeks'] as int : 0;
        if (repeat < 0 || repeat > 8 || (payload['id'] != null && repeat > 0)) {
          throw const FormatException('Tekrar 0–8 hafta olmalı');
        }
        final editing = payload['id'] == null ? null : find(payload['id']);
        final warnings = <String>[];
        final saved = <String>[];
        for (var w = 0; w <= repeat; w++) {
          final p = {...draft, 'date': addDays(date, 7 * w)};
          if (!dayOff) {
            final (a, b) = planWindow(p);
            final clash = own().where((o) => o['id'] != editing?['id'] && o['dayOff'] != true).any((o) {
              final (c, d) = planWindow(o);
              return a.isBefore(d) && c.isBefore(b);
            });
            if (clash) warnings.add('${p['date']} tarihinde başka vardiyanız var');
          }
          if (editing != null) {
            final before = Map.of(editing);
            editing..addAll(p)..['updatedAt'] = _bump(editing['updatedAt'], clock)..['updatedBy'] = actorName;
            audit(editing, 'düzenlendi', before);
            saved.add('${editing['id']}');
          } else {
            final id = 'vp_${requestId}_$w';
            final row = {'id': id, 'employeeId': emp['id'], 'employeeName': emp['name'], ...p,
              'cancelled': false, 'createdAt': _stamp(clock), 'createdBy': actorName,
              'updatedAt': _stamp(clock), 'updatedBy': actorName, 'history': <dynamic>[]};
            plans.add(row);
            saved.add(id);
          }
        }
        if (warnings.isNotEmpty && payload['confirmOverlap'] != true) throw OverlapWarning(warnings.join('\n'));
        return {'ok': true, 'ids': saved, 'warnings': warnings};
      case 'plan_cancel':
        final p = find(payload['id']);
        p..['cancelled'] = true..['updatedAt'] = _bump(p['updatedAt'], clock)..['updatedBy'] = actorName;
        audit(p, 'iptal', null);
        return {'ok': true, 'id': p['id']};
      case 'plan_copy_week':
        final from = '${payload['fromWeekStart']}', to = '${payload['toWeekStart']}';
        if (!isCalendarDay(from) || !isCalendarDay(to) || weekStartOf(from) != from || weekStartOf(to) != to || from == to) {
          throw const FormatException('Hafta geçersiz');
        }
        if (!manager && addDays(to, 6).compareTo(today) < 0) throw const FormatException('Geçmiş haftaya kopyalanamaz');
        final source = own().where((p) => '${p['date']}'.compareTo(from) >= 0 && '${p['date']}'.compareTo(addDays(from, 6)) <= 0).toList();
        final copied = <String>[];
        var skipped = 0;
        for (final p in source) {
          final shift = DateTime.parse(to).difference(DateTime.parse(from)).inDays;
          final c = {...p, 'date': addDays('${p['date']}', shift)};
          if (!manager && '${c['date']}'.compareTo(today) < 0) { skipped++; continue; }
          final clash = own().any((o) {
            if (o['dayOff'] == true || c['dayOff'] == true) return o['date'] == c['date'];
            final (a, b) = planWindow(c);
            final (x, y) = planWindow(o);
            return a.isBefore(y) && x.isBefore(b);
          });
          if (clash) { skipped++; continue; }
          final id = 'vp_${requestId}_${copied.length}';
          plans.add({...c, 'id': id, 'createdAt': _stamp(clock), 'createdBy': actorName,
            'updatedAt': _stamp(clock), 'updatedBy': actorName, 'history': <dynamic>[]});
          copied.add(id);
        }
        return {'ok': true, 'ids': copied, 'skipped': skipped};
      default:
        throw const FormatException('Vardiya işlemi geçersiz');
    }
  });
}

/// Shared schedule: names and times only, never wages or notes of others.
List<Json> sharedSchedule(Json state, String from, String to, {int? viewerId}) => [
  for (final p in shiftPlansOf(state))
    if (p['cancelled'] != true && '${p['date']}'.compareTo(from) >= 0 && '${p['date']}'.compareTo(to) <= 0)
      {
        for (final k in ['id', 'employeeId', 'employeeName', 'date', 'start', 'end', 'endsNextDay', 'dayOff', 'breakMinutes']) k: p[k],
        if (p['employeeId'] == viewerId) ...{'note': p['note'], 'updatedAt': p['updatedAt'], 'mine': true},
      },
]..sort((a, b) => '${a['date']} ${a['start']}'.compareTo('${b['date']} ${b['start']}'));

// ---------------------------------------------------------------- Mesai

bool isManualWork(Json w) => w['source'] == 'manual';

/// Worked minutes of a (closed, not voided) record, minus its break.
int workMinutes(Json w) {
  if (w['voided'] == true || w['end'] == null) return 0;
  final m = DateTime.parse('${w['end']}').difference(DateTime.parse('${w['start']}')).inMinutes -
      ((w['breakMinutes'] as int?) ?? 0);
  return m < 0 ? 0 : m;
}

/// `work_save` (create/edit own actual hours, past days allowed) and
/// `work_void` (with reason). Only the employee themself writes here; the
/// manager's exceptional correction stays the audited [correctShift].
Json applyWorkCommand(PosStore store, Json payload, {required int? actorId,
    required String actorName, DateTime? now}) {
  final requestId = payload['requestId'];
  if (requestId is! String) throw const FormatException('İstek kimliği gerekli');
  final clock = (now ?? DateTime.now()).toUtc();
  return store.command('wf_$requestId', payload, (s) {
    if (actorId == null) throw const FormatException('Hesabınız bir personele bağlı değil');
    final emp = _employee(s, actorId);
    final shifts = (s['shifts'] ??= <dynamic>[]) as List;
    Map find() {
      final r = shifts.cast<Map>().where((x) => x['id'] == payload['id']).firstOrNull;
      if (r == null || r['employeeId'] != emp['id'] || r['voided'] == true) {
        throw const WorkforceConflict('Mesai kaydı bulunamadı');
      }
      if (r['updatedAt'] != payload['expectedUpdatedAt']) throw const WorkforceConflict();
      return r;
    }
    void audit(Map r, String reason, Map before) {
      ((r['corrections'] ??= <dynamic>[]) as List).add({
        'at': _stamp(clock), 'byId': emp['id'], 'by': actorName,
        'before': {for (final k in ['start', 'end', 'breakMinutes']) k: before[k]},
        'after': {for (final k in ['start', 'end', 'breakMinutes']) k: r[k]},
        'reason': reason,
      });
    }
    switch (payload['action']) {
      case 'work_save':
        final date = '${payload['date']}', start = '${payload['start']}', end = '${payload['end']}';
        if (!isCalendarDay(date) || !_hm.hasMatch(start) || !_hm.hasMatch(end)) {
          throw const FormatException('Tarih ve saat gerekli');
        }
        final a = instantOf(date, start);
        final b = instantOf(end.compareTo(start) <= 0 ? addDays(date, 1) : date, end);
        final span = b.difference(a).inMinutes;
        if (span <= 0 || span > 16 * 60) throw const FormatException('Mesai 16 saatten uzun olamaz');
        if (b.isAfter(clock.add(const Duration(minutes: 5)))) throw const FormatException('Gelecek saat için mesai girilemez');
        if (a.isBefore(clock.subtract(const Duration(days: 400)))) throw const FormatException('Tarih çok eski');
        final breakMinutes = _break(payload['breakMinutes'], span);
        final note = _text(payload['note'], 200, 'Not');
        final editing = payload['id'] == null ? null : find();
        final overlap = shiftsOf(s).any((x) => x['employeeId'] == emp['id'] && x['voided'] != true &&
            x['id'] != editing?['id'] && () {
              final c = DateTime.parse('${x['start']}');
              final d = x['end'] == null ? clock : DateTime.parse('${x['end']}');
              return a.isBefore(d) && c.isBefore(b);
            }());
        if (overlap) throw const FormatException('Bu saatlerde başka mesai kaydınız var');
        final values = {'start': _stamp(a), 'end': _stamp(b), 'breakMinutes': breakMinutes, 'note': note};
        if (editing != null) {
          final before = Map.of(editing);
          editing..addAll(values)..['updatedAt'] = _bump(editing['updatedAt'], clock);
          audit(editing, 'Personel düzenlemesi', before);
          return {'ok': true, 'id': editing['id'], 'updatedAt': editing['updatedAt']};
        }
        final row = {'id': 'mw_$requestId', 'employeeId': emp['id'], 'employeeName': emp['name'],
          ...values, 'source': 'manual', 'createdAt': _stamp(clock), 'updatedAt': _stamp(clock),
          'corrections': <dynamic>[]};
        shifts.add(row);
        return {'ok': true, 'id': row['id'], 'updatedAt': row['updatedAt']};
      case 'work_void':
        final r = find();
        final reason = _text(payload['reason'], 200, 'Neden');
        if (reason.isEmpty) throw const FormatException('İptal nedeni gerekli');
        final before = Map.of(r);
        r..['voided'] = true..['voidedAt'] = _stamp(clock)..['voidReason'] = reason..['updatedAt'] = _bump(r['updatedAt'], clock);
        audit(r, 'İptal: $reason', before);
        return {'ok': true, 'id': r['id']};
      default:
        throw const FormatException('Mesai işlemi geçersiz');
    }
  });
}

// ------------------------------------------------------- Weekly submission

List<Json> timesheetWeeksOf(Json state) => asMaps(state['timesheetWeeks']);

List<Json> _weekWork(Json state, int employeeId, String weekStart) {
  final end = addDays(weekStart, 7);
  return [
    for (final w in shiftsOf(state))
      if (w['employeeId'] == employeeId && w['start'] != null && () {
        final d = istanbulDayOfInstant(DateTime.parse('${w['start']}'));
        return d.compareTo(weekStart) >= 0 && d.compareTo(end) < 0;
      }()) w,
  ];
}

/// Taslak | Gönderildi | Değişti (edited after sending) | Çalışma yok.
Json weekStatus(Json state, int employeeId, String weekStart) {
  final row = timesheetWeeksOf(state)
      .where((w) => w['employeeId'] == employeeId && w['weekStart'] == weekStart).firstOrNull;
  final work = _weekWork(state, employeeId, weekStart);
  final minutes = work.fold<int>(0, (n, s) => n + workMinutes(s));
  final days = {for (final w in work.where((w) => w['voided'] != true)) istanbulDayOfInstant(DateTime.parse('${w['start']}'))};
  String status = 'Taslak';
  if (row != null) {
    // Changed = the live records differ from the last submitted snapshot.
    final last = (row['history'] as List?)?.lastOrNull;
    String key(Object? e) { final m = e as Map; return '${m['id']}|${m['start']}|${m['end']}|${m['breakMinutes'] ?? 0}'; }
    final sent = {for (final e in (last is Map ? last['entries'] as List? ?? const [] : const [])) key(e)};
    final live = {for (final w in work.where((w) => w['voided'] != true)) key(w)};
    final changed = sent.length != live.length || !sent.containsAll(live);
    status = changed ? 'Değişti' : row['noWork'] == true ? 'Çalışma yok' : 'Gönderildi';
  }
  return {
    'weekStart': weekStart, 'weekEnd': addDays(weekStart, 6), 'status': status,
    'submittedAt': row?['submittedAt'], 'submissions': (row?['history'] as List?)?.length ?? 0,
    'minutes': minutes, 'daysWorked': days.length,
    'openRecords': work.where((w) => w['end'] == null && w['voided'] != true).length,
  };
}

/// `week_submit` {weekStart, noWork?}: communicates the week; not approval.
Json submitWeek(PosStore store, Json payload, {required int? actorId, DateTime? now}) {
  final requestId = payload['requestId'];
  if (requestId is! String) throw const FormatException('İstek kimliği gerekli');
  final clock = (now ?? DateTime.now()).toUtc();
  return store.command('wf_$requestId', payload, (s) {
    if (actorId == null) throw const FormatException('Hesabınız bir personele bağlı değil');
    final emp = _employee(s, actorId);
    final week = '${payload['weekStart']}';
    if (!isCalendarDay(week) || weekStartOf(week) != week) throw const FormatException('Hafta geçersiz');
    if (week.compareTo(dayOf(istanbulNow(clock))) > 0) throw const FormatException('Gelecek hafta gönderilemez');
    final work = _weekWork(s, emp['id'] as int, week).where((x) => x['voided'] != true).toList();
    final noWork = payload['noWork'] == true;
    if (noWork && work.isNotEmpty) throw const FormatException('Bu hafta mesai kaydınız var');
    if (!noWork && work.isEmpty) throw const FormatException('Gönderilecek mesai yok. Çalışmadıysanız “Bu hafta çalışmadım” seçin.');
    if (work.any((x) => x['end'] == null)) throw const FormatException('Açık mesai kaydını önce tamamlayın');
    final weeks = (s['timesheetWeeks'] ??= <dynamic>[]) as List;
    var row = weeks.cast<Map>().where((w) => w['employeeId'] == emp['id'] && w['weekStart'] == week).firstOrNull;
    if (row == null) {
      row = {'id': 'tw_${emp['id']}_$week', 'employeeId': emp['id'], 'employeeName': emp['name'],
        'weekStart': week, 'history': <dynamic>[]};
      weeks.add(row);
    }
    final minutes = work.fold<int>(0, (n, x) => n + workMinutes(x));
    row..['submittedAt'] = _stamp(clock)..['noWork'] = noWork..['minutes'] = minutes;
    (row['history'] as List).add({'at': _stamp(clock), 'minutes': minutes, 'noWork': noWork,
      'entries': [for (final x in work) {'id': x['id'], 'start': x['start'], 'end': x['end'], 'breakMinutes': x['breakMinutes'] ?? 0}]});
    return {'ok': true, 'weekStart': week, 'submittedAt': row['submittedAt']};
  });
}

/// The employee's own week: plans, actual records (with history), status.
Json ownWeek(Json state, int employeeId, String weekStart) {
  final end = addDays(weekStart, 6);
  final emp = asMaps(state['employees']).where((e) => e['id'] == employeeId).firstOrNull;
  return {
    'weekStart': weekStart,
    'employee': {'id': employeeId, 'name': emp?['name'],
      'payType': emp?['payType'], 'payRateCents': emp?['payRateCents']},
    'status': weekStatus(state, employeeId, weekStart),
    'plans': [for (final p in sharedSchedule(state, weekStart, end, viewerId: employeeId)) if (p['mine'] == true) p],
    'plannedMinutes': shiftPlansOf(state).where((p) => p['employeeId'] == employeeId &&
        '${p['date']}'.compareTo(weekStart) >= 0 && '${p['date']}'.compareTo(end) <= 0).fold<int>(0, (n, p) => n + planMinutes(p)),
    'work': [
      for (final w in _weekWork(state, employeeId, weekStart))
        {for (final k in ['id', 'start', 'end', 'breakMinutes', 'note', 'source', 'voided', 'voidReason', 'updatedAt', 'corrections']) k: w[k],
         'date': istanbulDayOfInstant(DateTime.parse('${w['start']}')),
         'from': hmOf(DateTime.parse('${w['start']}')),
         'to': w['end'] == null ? null : hmOf(DateTime.parse('${w['end']}')),
         'minutes': workMinutes(w), 'editable': isManualWork(w) && w['voided'] != true && w['end'] != null},
    ],
  };
}

/// Manager view (`shifts.manage`): every active employee's week. Wages are
/// not included here (payroll grants, W3).
List<Json> teamWeek(Json state, String weekStart) => [
  for (final e in asMaps(state['employees']).where((e) => e['active'] != false))
    {'employeeId': e['id'], 'name': e['name'], ...weekStatus(state, e['id'] as int, weekStart),
     'plannedMinutes': shiftPlansOf(state).where((p) => p['employeeId'] == e['id'] &&
        '${p['date']}'.compareTo(weekStart) >= 0 && '${p['date']}'.compareTo(addDays(weekStart, 6)) <= 0)
        .fold<int>(0, (n, p) => n + planMinutes(p))},
];
