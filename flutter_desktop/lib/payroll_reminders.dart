/// V6.1 weekly payroll reminders (spec §24.6, task W4). Derived from
/// committed state with stable ids — one event per employee/week/slot — so
/// polls, restarts and several clients never duplicate them. Only the
/// latest due slot is created (bounded catch-up after downtime). Lock-screen
/// text is generic; names and amounts stay inside the app.
library;

import 'payroll.dart';
import 'pos_logic.dart';
import 'workforce.dart';

final _hm = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

class PayrollReminderSettings {
  const PayrollReminderSettings({this.enabled = true, this.paydayOffset = 7,
      this.sundayTimes = const ['18:00', '21:30'], this.paydayTimes = const ['09:00', '14:00', '20:00'],
      this.dailyTime = '09:00'});
  final bool enabled;
  /// Days after the week's Monday; 7 = the following Monday.
  final int paydayOffset;
  final List<String> sundayTimes, paydayTimes;
  final String dailyTime;

  static PayrollReminderSettings of(Json state) {
    final settings = state['settings'];
    final raw = settings is Map ? settings['payrollReminders'] : null;
    if (raw is! Map) return const PayrollReminderSettings();
    List<String> times(Object? v, List<String> d) {
      final l = v is List ? [for (final t in v) if (_hm.hasMatch('$t')) '$t'] : [...d];
      return (l..sort()).take(4).toList();
    }
    final off = raw['paydayOffset'];
    return PayrollReminderSettings(
      enabled: raw['enabled'] != false,
      paydayOffset: off is int && off >= 7 && off <= 13 ? off : 7,
      sundayTimes: times(raw['sundayTimes'], const ['18:00', '21:30']),
      paydayTimes: times(raw['paydayTimes'], const ['09:00', '14:00', '20:00']),
      dailyTime: _hm.hasMatch('${raw['dailyTime']}') ? '${raw['dailyTime']}' : '09:00',
    );
  }
}

/// Latest slot of [times] on [day] that has passed at [now], or null.
String? _latestSlot(String day, List<String> times, DateTime now) {
  String? last;
  for (final t in times) {
    if (!now.isBefore(instantOf(day, t))) last = t;
  }
  return last;
}

Json _ev(String id, String category, String day, String slot, String title, String body,
        Json ref, {int? recipient, String? permission}) => {
  'eventId': id, 'category': category, 'createdAt': instantOf(day, slot).toIso8601String(),
  'title': title, 'body': body, 'ref': ref,
  if (recipient != null) 'recipientEmployeeId': recipient,
  if (permission != null) 'permission': permission,
};

List<Json> payrollReminderEvents(Json state, DateTime now) {
  final cfg = PayrollReminderSettings.of(state);
  final clock = now.toUtc();
  final today = dayOf(istanbulNow(clock));
  final events = <Json>[];
  // Payroll-eligible people only (never the owner by default). Sunday
  // reminders go to active staff; money owed to someone who left still
  // reminds the managers until it is settled.
  final eligible = asMaps(state['employees']).where(isPayrollEligible).toList();
  final employees = eligible.where((e) => e['active'] != false).toList();

  // Employees: payments recorded for them (own, private).
  for (final p in asMaps((state['finance'] is Map ? (state['finance'] as Map)['payrollPayments'] : null))) {
    final created = DateTime.tryParse('${p['createdAt']}');
    if (created == null) continue;
    events.add({'eventId': 'pp:${p['id']}', 'category': 'personal', 'createdAt': p['createdAt'],
      'title': (p['amountCents'] as int) < 0 ? 'Maaş kaydınız düzeltildi' : 'Maaş ödemeniz kaydedildi',
      'body': 'Ayrıntılar için Mesai › Maaş bölümüne bakın.',
      'ref': {'kind': 'payroll', 'key': '${p['weekStart']}'}, 'recipientEmployeeId': p['employeeId']});
  }
  // Managers: weekly submissions and revisions (communicated, not approval).
  for (final w in timesheetWeeksOf(state)) {
    final history = w['history'] is List ? w['history'] as List : const [];
    for (var i = 0; i < history.length; i++) {
      final h = history[i] as Map;
      events.add({'eventId': 'tsw:${w['employeeId']}:${w['weekStart']}:$i', 'category': 'shift',
        'createdAt': h['at'], 'title': i == 0 ? 'Haftalık mesai gönderildi' : 'Haftalık mesai güncellendi',
        'body': '${w['employeeName'] ?? ''} · ${w['weekStart']} haftası', 'ref': {'kind': 'timesheet', 'key': '${w['weekStart']}'}});
    }
  }
  if (!cfg.enabled) return events;

  // Sunday: unsubmitted (or changed) weeks remind their own employee.
  if (DateTime.parse(today).weekday == DateTime.sunday) {
    final slot = _latestSlot(today, cfg.sundayTimes, clock);
    if (slot != null) {
      final week = weekStartOf(today);
      for (final e in employees) {
        final st = weekStatus(state, e['id'] as int, week)['status'];
        if (st != 'Taslak' && st != 'Değişti') continue;
        events.add(_ev('tsr:${e['id']}:$week:$slot', 'personal', today, slot,
            'Haftalık mesainizi gönderin', 'Bu haftanın çalışma saatlerini kontrol edip gönderin.',
            {'kind': 'timesheet', 'key': week}, recipient: e['id'] as int));
      }
    }
  }

  // Payday and after: managers until every status is resolved/recorded.
  for (var back = 1; back <= 4; back++) {
    final week = addDays(weekStartOf(today), -7 * back);
    final due = addDays(week, cfg.paydayOffset);
    if (today.compareTo(due) < 0) continue;
    final open = eligible.where((e) {
      final st = payrollStatus(state, e['id'] as int, week, today: today, paydayOffset: cfg.paydayOffset);
      // Only actual outstanding earnings; unknown amounts are not "owed".
      return (st['remainingCents'] as int? ?? 0) > 0;
    }).length;
    if (open == 0) continue;
    final slot = today == due ? _latestSlot(today, cfg.paydayTimes, clock) : _latestSlot(today, [cfg.dailyTime], clock);
    if (slot == null) continue;
    events.add(_ev('payday:$week:$today:$slot', 'payroll', today, slot,
        today == due ? 'Maaş günü: ödemeleri kontrol edin' : 'Gecikmiş maaş ödemesi var',
        'Haftalık maaş ödeme durumlarını kaydedin.', {'kind': 'payroll', 'key': week},
        permission: 'payroll.manage'));
  }
  return events;
}
