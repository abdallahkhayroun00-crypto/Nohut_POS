/// V6.0 / V6.1 wages and weekly payroll (spec §24.5–§24.6, tasks W3/W4).
///
/// * **Rates** — `employees[].payHistory[]` `{effectiveFrom, payType,
///   rateCents, setAt, setBy}`; append-only. Hours keep the rate that was in
///   force on their day. No rate = *Ücret Tanımlanmadı* (never 0 TL); the
///   hours are still stored and the wage is marked incomplete.
/// * **Earned** — from manual Mesai only (never from Vardiya plans):
///   Σ(minutes × hourly rate of that day) / 60, rounded half-up once per
///   week; *Haftalık Sabit* = the weekly amount in force on the week's
///   Monday when the employee worked that week. Bonus is separate.
/// * **Payments** — `finance.payrollPayments[]`, immutable rows the manager
///   records after paying outside the POS (never initiated here): Nakit,
///   Havale/EFT or Karma with exact parts; `Avans` counts toward the week
///   once. A mistake is fixed with a reversal row, never by editing.
///   Ödendi / Kısmen Ödendi / Ödenmedi are *derived* from these rows.
/// * **Review** — `finance.payrollReviews[]`: an explicit "Ödenmedi"
///   acknowledgement (no money moves) that stops the "status missing"
///   reminders but not the outstanding-payment ones.
/// * Weeks that already have a legacy `finance.weeklyPayroll` row keep
///   their old flow; new payments are refused there (no double counting).
library;

import 'finance_logic.dart' show financeBook, financeRows;
import 'pos_logic.dart';
import 'pos_store.dart';
import 'workforce.dart';

const payTypes = ['Saatlik', 'Haftalık Sabit'];
const payrollMethods = ['Nakit', 'Havale/EFT', 'Karma'];
const payrollKinds = ['Ödeme', 'Avans'];

final _dayRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');

class PayrollConflict implements Exception {
  const PayrollConflict(this.message);
  final String message;
  @override
  String toString() => message;
}

String _stamp(DateTime now) => now.toUtc().toIso8601String();

Map _employeeRow(Json state, Object? id) {
  final list = state['employees'];
  final e = list is List ? list.cast<Map>().where((e) => e['id'] == id).firstOrNull : null;
  if (e == null) throw const FormatException('Personel bulunamadı');
  return e;
}

/// (payType, rateCents) in force on [day], or null when undefined.
(String, int)? payRateOn(Map employee, String day) {
  final history = asMaps(employee['payHistory'])
      .where((h) => '${h['effectiveFrom']}'.compareTo(day) <= 0).toList()
    ..sort((a, b) {
      final c = '${a['effectiveFrom']}'.compareTo('${b['effectiveFrom']}');
      return c != 0 ? c : '${a['setAt']}'.compareTo('${b['setAt']}');
    });
  if (history.isNotEmpty) {
    final h = history.last;
    return ('${h['payType']}', h['rateCents'] as int);
  }
  // Older records without history: the single current rate for all days,
  // unless history exists only for later dates (then: undefined before it).
  if (asMaps(employee['payHistory']).isNotEmpty) return null;
  final rate = employee['payRateCents'], type = employee['payType'];
  return rate is int && rate > 0 && payTypes.contains(type) ? ('$type', rate) : null;
}

/// Ücret Belirle / Ücreti Düzenle with an effective date (payroll.manage).
void setEmployeeRate(Json state, {required int employeeId, required String payType,
    required int rateCents, required String effectiveFrom, required String by, DateTime? now}) {
  if (!payTypes.contains(payType)) throw const FormatException('Ücret türü geçersiz');
  if (rateCents < 1 || rateCents > 100000000) throw const FormatException('Ücret geçersiz');
  if (!_dayRe.hasMatch(effectiveFrom)) throw const FormatException('Geçerlilik tarihi geçersiz');
  final clock = (now ?? DateTime.now()).toUtc();
  final e = _employeeRow(state, employeeId);
  // Never rewrite a week that already has recorded payments or a legacy
  // payroll row: a new rate may start only after the last settled week.
  final settled = [
    for (final p in financeRows(state, 'payrollPayments'))
      if (p['employeeId'] == employeeId) '${p['weekStart']}',
    for (final r in financeRows(state, 'weeklyPayroll'))
      if (r['employeeId'] == employeeId) '${r['weekStart']}',
  ];
  for (final w in settled) {
    if (effectiveFrom.compareTo(addDays(w, 7)) < 0) {
      throw PayrollConflict('Ödeme kaydı olan hafta ($w) geriye dönük değiştirilemez. '
          'Yeni ücret en erken ${addDays(w, 7)} tarihinden başlayabilir.');
    }
  }
  final history = (e['payHistory'] ??= <dynamic>[]) as List;
  // First history entry on an employee that already had a rate: keep the
  // old rate in force for earlier days.
  if (history.isEmpty && e['payRateCents'] is int && payTypes.contains(e['payType'])) {
    history.add({'effectiveFrom': '2000-01-01', 'payType': e['payType'], 'rateCents': e['payRateCents'],
      'setAt': _stamp(clock), 'setBy': 'önceki kayıt'});
  }
  history.add({'effectiveFrom': effectiveFrom, 'payType': payType, 'rateCents': rateCents,
    'setAt': _stamp(clock.add(const Duration(microseconds: 1))), 'setBy': by});
  final current = payRateOn(e, istanbulDayOfInstant(clock));
  if (current != null) {
    e['payType'] = current.$1;
    e['payRateCents'] = current.$2;
  }
}

/// Earned wage for one employee and week from manual Mesai.
Json weeklyEarnings(Json state, int employeeId, String weekStart) {
  final e = _employeeRow(state, employeeId);
  final st = weekStatus(state, employeeId, weekStart);
  final end = addDays(weekStart, 7);
  var minutes = 0, missingMinutes = 0, numerator = 0; // kuruş × minutes
  int? fixed;
  for (final w in asMaps(state['shifts'])) {
    if (w['employeeId'] != employeeId || w['voided'] == true || w['end'] == null) continue;
    final day = istanbulDayOfInstant(DateTime.parse('${w['start']}'));
    if (day.compareTo(weekStart) < 0 || day.compareTo(end) >= 0) continue;
    final m = workMinutes(w);
    minutes += m;
    final rate = payRateOn(e, day);
    if (rate == null) {
      missingMinutes += m;
    } else if (rate.$1 == 'Saatlik') {
      numerator += rate.$2 * m;
    } else {
      fixed = rate.$2;
    }
  }
  final weeklyRate = payRateOn(e, weekStart);
  if (minutes > 0 && fixed == null && weeklyRate?.$1 == 'Haftalık Sabit') fixed = weeklyRate!.$2;
  final hourlyPart = (numerator + 30) ~/ 60; // half-up, once per week
  final earned = missingMinutes > 0 ? null : hourlyPart + (fixed ?? 0);
  return {'minutes': minutes, 'missingRateMinutes': missingMinutes,
    'earnedCents': earned, 'rateComplete': missingMinutes == 0,
    'submission': st['status'], 'submittedAt': st['submittedAt']};
}

List<Json> payrollPaymentsFor(Json state, int employeeId, String weekStart) => [
  for (final p in financeRows(state, 'payrollPayments'))
    if (p['employeeId'] == employeeId && p['weekStart'] == weekStart) p,
];

/// Derived status for one employee and week. [today] decides Gecikmiş.
Json payrollStatus(Json state, int employeeId, String weekStart, {required String today, int paydayOffset = 7}) {
  final earned = weeklyEarnings(state, employeeId, weekStart);
  final legacy = financeRows(state, 'weeklyPayroll')
      .where((r) => r['employeeId'] == employeeId && r['weekStart'] == weekStart).firstOrNull;
  final rows = payrollPaymentsFor(state, employeeId, weekStart);
  final paid = rows.fold<int>(0, (n, p) => n + (p['amountCents'] as int));
  final advances = rows.where((p) => p['kind'] == 'Avans').fold<int>(0, (n, p) => n + (p['amountCents'] as int));
  final e = earned['earnedCents'] as int?;
  final due = addDays(weekStart, paydayOffset);
  final ack = financeRows(state, 'payrollReviews')
      .where((r) => r['employeeId'] == employeeId && r['weekStart'] == weekStart).lastOrNull;
  final nothingOwed = legacy == null && (earned['minutes'] as int) == 0 && paid == 0;
  // Never classify money we cannot compute: no work and no rate are states
  // of their own, not Ödenmedi / Ödendi (owner rule 2026-11-27).
  String financial;
  if (legacy != null) {
    financial = legacy['paid'] == true ? 'Ödendi' : 'Ödenmedi';
  } else if (nothingOwed) {
    financial = 'Çalışma kaydı yok';
  } else if (e == null) {
    financial = 'Ücret belirlenmedi';
  } else if (paid <= 0) {
    financial = 'Ödenmedi';
  } else if (paid >= e) {
    financial = 'Ödendi';
  } else {
    financial = 'Kısmen Ödendi';
  }
  final remaining = legacy != null ? (legacy['paid'] == true ? 0 : legacy['payableCents'] as int?)
      : e == null ? null : (e - paid < 0 ? 0 : e - paid);
  final resolved = nothingOwed || financial == 'Ödendi';
  // Manager review: an explicit Ödenmedi acknowledgement or any payment.
  final review = resolved || paid > 0 || legacy != null ? 'Belirtildi'
      : ack != null ? 'Ödenmedi (belirtildi)' : 'Belirtilmedi';
  final lastPaid = rows.where((p) => (p['amountCents'] as int) > 0).map((p) => '${p['paidOn']}').fold<String?>(null,
      (a, b) => a == null || b.compareTo(a) > 0 ? b : a);
  return {
    'employeeId': employeeId, 'weekStart': weekStart, 'weekEnd': addDays(weekStart, 6), 'dueDate': due,
    'payrollEligible': isPayrollEligible(_employeeRow(state, employeeId)),
    ...earned,
    'legacy': legacy != null,
    'paidCents': legacy != null ? (legacy['paid'] == true ? legacy['payableCents'] : 0) : paid,
    'advanceCents': advances,
    'overpaidCents': e != null && paid > e ? paid - e : 0,
    'remainingCents': remaining,
    'financialStatus': financial,
    'reviewStatus': review,
    'resolved': resolved,
    'overdue': (remaining ?? 0) > 0 && today.compareTo(due) > 0,
    'lastPaidOn': lastPaid,
    'methods': {for (final p in rows) '${p['method']}'}.toList(),
  };
}

/// Records a real payment made outside the POS (payroll.manage).
Json recordPayrollPayment(Json state, Json d, {required String by, DateTime? now}) {
  final clock = (now ?? DateTime.now()).toUtc();
  final employeeId = d['employeeId'];
  final week = '${d['weekStart']}';
  final paidOn = '${d['paidOn']}';
  final method = '${d['method']}';
  final kind = '${d['kind'] ?? 'Ödeme'}';
  if (employeeId is! int) throw const FormatException('Personel seçin');
  final e = _employeeRow(state, employeeId);
  if (!_dayRe.hasMatch(week) || weekStartOf(week) != week) throw const FormatException('Hafta geçersiz');
  if (!_dayRe.hasMatch(paidOn) || paidOn.compareTo(istanbulDayOfInstant(clock)) > 0) {
    throw const FormatException('Ödeme tarihi geçersiz (gelecek olamaz)');
  }
  if (!payrollMethods.contains(method)) throw const FormatException('Ödeme yöntemi geçersiz');
  if (!payrollKinds.contains(kind)) throw const FormatException('Ödeme türü geçersiz');
  int part(String k) {
    final v = d[k] ?? 0;
    if (v is! int || v < 0 || v > 100000000000) throw const FormatException('Tutar geçersiz');
    return v;
  }
  final cash = method == 'Havale/EFT' ? 0 : part('cashCents');
  final bank = method == 'Nakit' ? 0 : part('bankCents');
  if (method == 'Karma' && (cash == 0 || bank == 0)) throw const FormatException('Karma ödemede nakit ve havale tutarını girin');
  final amount = cash + bank;
  if (amount <= 0) throw const FormatException('Tutar girin');
  if (financeRows(state, 'weeklyPayroll').any((r) => r['employeeId'] == employeeId && r['weekStart'] == week)) {
    throw const PayrollConflict('Bu hafta eski bordro kaydıyla yönetiliyor; ödeme orada işaretlenir.');
  }
  final book = financeBook(state);
  final rows = (book['payrollPayments'] ??= <dynamic>[]) as List;
  final note = '${d['note'] ?? ''}'.trim();
  if (note.length > 300) throw const FormatException('Not çok uzun');
  final row = {
    'id': 'pp_${d['requestId'] ?? clock.microsecondsSinceEpoch}',
    'employeeId': employeeId, 'employeeName': e['name'], 'weekStart': week,
    'kind': kind, 'method': method, 'cashCents': cash, 'bankCents': bank, 'amountCents': amount,
    'paidOn': paidOn, 'note': note, 'createdAt': _stamp(clock), 'createdBy': by,
  };
  rows.add(row);
  return row;
}

/// Audited correction: a negative row that cancels one earlier payment.
Json reversePayrollPayment(Json state, Json d, {required String by, DateTime? now}) {
  final clock = (now ?? DateTime.now()).toUtc();
  final rows = (financeBook(state)['payrollPayments'] ??= <dynamic>[]) as List;
  final original = rows.cast<Map>().where((p) => p['id'] == d['id']).firstOrNull;
  if (original == null || (original['amountCents'] as int) <= 0) throw const PayrollConflict('Ödeme bulunamadı');
  if (rows.cast<Map>().any((p) => p['reverses'] == original['id'])) throw const PayrollConflict('Bu ödeme zaten düzeltildi');
  final reason = '${d['reason'] ?? ''}'.trim();
  if (reason.isEmpty || reason.length > 300) throw const FormatException('Düzeltme nedeni gerekli');
  final row = {
    ...original.map((k, v) => MapEntry('$k', v)),
    'id': 'pr_${original['id']}', 'reverses': original['id'], 'kind': 'Düzeltme',
    'cashCents': -(original['cashCents'] as int), 'bankCents': -(original['bankCents'] as int),
    'amountCents': -(original['amountCents'] as int), 'paidOn': istanbulDayOfInstant(clock),
    'note': reason, 'createdAt': _stamp(clock), 'createdBy': by,
  };
  rows.add(row);
  return row;
}

/// Explicit "Ödenmedi" acknowledgement (no financial movement).
void acknowledgeUnpaid(Json state, Json d, {required String by, DateTime? now}) {
  final employeeId = d['employeeId'];
  final week = '${d['weekStart']}';
  if (employeeId is! int || !_dayRe.hasMatch(week) || weekStartOf(week) != week) {
    throw const FormatException('Personel ve hafta gerekli');
  }
  _employeeRow(state, employeeId);
  final rows = (financeBook(state)['payrollReviews'] ??= <dynamic>[]) as List;
  rows.add({'employeeId': employeeId, 'weekStart': week, 'state': 'Ödenmedi',
    'note': '${d['note'] ?? ''}'.trim(), 'at': _stamp((now ?? DateTime.now()).toUtc()), 'by': by});
}

/// "Haftalık Maaş Ödemeleri" panel rows for [weekStart].
/// Payroll covers people who are paid as employees. The owner (or anyone
/// marked `payrollEligible: false`) is excluded unless explicitly enabled.
bool isPayrollEligible(Map e) => e['payrollEligible'] != false;

/// One-time default: an employee profile linked to the owner account is not
/// a salaried employee. An explicit choice made later is never overridden.
bool applyOwnerPayrollDefault(Json state, Iterable<int> ownerEmployeeIds) {
  var changed = false;
  for (final e in (state['employees'] is List ? state['employees'] as List : const []).cast<Map>()) {
    if (ownerEmployeeIds.contains(e['id']) && !e.containsKey('payrollEligible')) {
      e['payrollEligible'] = false;
      changed = true;
    }
  }
  return changed;
}

/// Applies [applyOwnerPayrollDefault] to the store when anything changes.
void ensureOwnerPayrollDefault(PosStore store, List<int> ownerEmployeeIds) {
  if (ownerEmployeeIds.isEmpty) return;
  final snap = store.read();
  if (applyOwnerPayrollDefault(snap.data, ownerEmployeeIds)) store.replace(snap.data, snap.revision);
}

/// Sets payroll eligibility explicitly (owner/payroll.manage decision).
void setPayrollEligible(Json state, int employeeId, bool eligible) =>
    _employeeRow(state, employeeId)['payrollEligible'] = eligible;

List<Json> payrollWeek(Json state, String weekStart, {required String today}) => [
  // Eligible active people, plus anyone who already has payments that week
  // (history stays visible after a change of eligibility or deactivation).
  for (final e in asMaps(state['employees']).where((e) =>
      (e['active'] != false && isPayrollEligible(e)) ||
      payrollPaymentsFor(state, e['id'] as int, weekStart).isNotEmpty))
    {'name': e['name'], 'rate': () {
      final r = payRateOn(e, weekStart);
      return r == null ? null : {'payType': r.$1, 'rateCents': r.$2};
    }(), ...payrollStatus(state, e['id'] as int, weekStart, today: today)},
];
