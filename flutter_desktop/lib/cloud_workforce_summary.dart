/// QA-09 / O-03: Authoritative Windows-calculated weekly workforce & payroll
/// summaries for cloud projection (`workforceSummaries`).
///
/// Reuses Claude's authoritative `payrollStatus`, `ownWeek`, `payRateOn` and
/// `weekStartOf` functions — never recomputes wages independently in SQL.
library;

import 'finance_logic.dart' show financeRows;
import 'payroll.dart';
import 'pos_logic.dart';
import 'workforce.dart';

/// Collects every Monday weekStart that has any shift, plan, submission,
/// payroll payment, payroll review, or legacy payroll row, plus the current
/// and previous Istanbul week.
List<String> collectRelevantWeeks(Json state, {required String today}) {
  final cur = weekStartOf(today);
  final weeks = <String>{cur, addDays(cur, -7)};
  for (final s in asMaps(state['shifts'])) {
    final start = DateTime.tryParse('${s['start'] ?? ''}');
    if (start != null) weeks.add(weekStartOf(istanbulDayOfInstant(start)));
  }
  for (final p in asMaps(state['shiftPlans'])) {
    final day = '${p['date'] ?? ''}';
    if (isCalendarDay(day)) weeks.add(weekStartOf(day));
  }
  for (final tw in asMaps(state['timesheetWeeks'])) {
    final ws = '${tw['weekStart'] ?? ''}';
    if (isCalendarDay(ws)) weeks.add(weekStartOf(ws));
  }
  for (final key in ['payrollPayments', 'payrollReviews', 'weeklyPayroll']) {
    for (final row in financeRows(state, key)) {
      final ws = '${row['weekStart'] ?? ''}';
      if (isCalendarDay(ws)) weeks.add(weekStartOf(ws));
    }
  }
  return weeks.toList()..sort();
}

/// Builds the exact `workforceSummaries` cloud projection payload for
/// `nohut_private.apply_workforce_summary_projection`.
///
/// Missing wages stay `null` (never fabricated `0`); owner exclusion
/// (`payrollEligible: false`) and departed employees with unpaid work/payments
/// are preserved faithfully from `payrollStatus`.
Json serializeWorkforceSummaries(Json state, {DateTime? now, List<String>? weeks}) {
  final ts = (now ?? DateTime.now()).toUtc();
  final today = istanbulDayOfInstant(ts);
  final targetWeeks = weeks ?? collectRelevantWeeks(state, today: today);
  final rows = <Json>[];

  for (final e in asMaps(state['employees'])) {
    final id = e['id'];
    if (id is! int || id <= 0) continue;
    final name = '${e['name'] ?? ''}'.trim();
    if (name.isEmpty) continue;
    final active = e['active'] != false;
    final eligible = isPayrollEligible(e);

    for (final ws in targetWeeks) {
      final st = payrollStatus(state, id, ws, today: today);
      final ow = ownWeek(state, id, ws);
      final worked = st['minutes'] as int;
      final planned = ow['plannedMinutes'] as int;
      final paid = st['paidCents'] as int;
      final legacy = st['legacy'] == true;
      // Include active employees and any departed employee who has work, plans, or payments in this week.
      if (!active && worked == 0 && planned == 0 && paid == 0 && !legacy) continue;

      final rate = payRateOn(e, ws);
      rows.add({
        'employeeLocalId': id,
        'employeeName': name,
        'weekStart': ws,
        'weekEnd': st['weekEnd'],
        'dueDate': st['dueDate'],
        'payrollEligible': eligible,
        'workedMinutes': worked,
        'plannedMinutes': planned,
        'missingRateMinutes': st['missingRateMinutes'] as int,
        'rateComplete': st['rateComplete'] == true,
        'payType': rate?.$1,
        'rateKurus': rate?.$2,
        'earnedKurus': st['earnedCents'],
        'paidKurus': paid,
        'advanceKurus': st['advanceCents'] as int,
        'overpaidKurus': st['overpaidCents'] as int,
        'remainingKurus': st['remainingCents'],
        'financialStatus': st['financialStatus'],
        'reviewStatus': st['reviewStatus'],
        'submissionStatus': st['submission'],
        'submittedAt': st['submittedAt'],
        'overdue': st['overdue'] == true,
        'legacy': legacy,
        'lastPaidOn': st['lastPaidOn'],
      });
    }
  }

  return {
    'as_of_day': today,
    'calculated_at': ts.toIso8601String(),
    'rows': rows,
  };
}
