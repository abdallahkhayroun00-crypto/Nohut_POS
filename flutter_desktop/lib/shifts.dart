/// Phase 5C: employee shifts (Mesai Başlat / Mesai Bitir) on the Windows
/// authority (spec §10.1 item 8, §22.2).
///
/// `state['shifts']` = list of
/// `{id, employeeId, employeeName, start, end?, source, corrections[]}`.
/// * at most one open shift per employee;
/// * a correction never overwrites silently: before → after, who, when and
///   why are appended to `corrections` (visible to the employee);
/// * shifts are never deleted — a wrong one is corrected to zero length
///   with a reason;
/// * every write goes through [PosStore.command], so it is idempotent and
///   committed in the same transaction as its receipt.
library;

import 'pos_logic.dart';
import 'pos_store.dart';

List<Json> shiftsOf(Json state) => asMaps(state['shifts']);

Json? openShift(Json state, int employeeId) =>
    shiftsOf(state).where((x) => x['employeeId'] == employeeId && x['end'] == null).firstOrNull;

/// Worked minutes of a shift; an open shift counts up to [now].
int shiftMinutes(Json shift, DateTime now) {
  final start = DateTime.parse('${shift['start']}');
  final end = shift['end'] == null ? now : DateTime.parse('${shift['end']}');
  final m = end.difference(start).inMinutes;
  return m < 0 ? 0 : m;
}

/// Minutes worked by [employeeId] in shifts that START in [from, to).
int workedMinutes(Json state, int employeeId, DateTime from, DateTime to, DateTime now) => shiftsOf(state)
    .where((x) => x['employeeId'] == employeeId)
    .where((x) {
      final start = DateTime.parse('${x['start']}');
      return !start.isBefore(from) && start.isBefore(to);
    })
    .fold(0, (n, x) => n + shiftMinutes(x, now));

Json _activeEmployee(Json state, Object? id) {
  final e = asMaps(state['employees']).where((e) => e['id'] == id && e['active'] == true).firstOrNull;
  if (e == null) throw const FormatException('Aktif personel seçin');
  return e;
}

/// `action`: `clockIn` | `clockOut`. The employee is the actor (`staffId`).
Json submitShiftAction(PosStore store, Json payload, {DateTime? now}) {
  final id = payload['requestId'];
  if (id is! String) throw const FormatException('İstek kimliği gerekli');
  final at = (now ?? DateTime.now()).toUtc().toIso8601String();
  return store.command(id, payload, (s) {
    final staff = _activeEmployee(s, payload['staffId']);
    final employeeId = staff['id'] as int;
    final shifts = (s['shifts'] ??= <dynamic>[]) as List;
    final open = openShift(s, employeeId);
    switch (payload['action']) {
      case 'clockIn':
        if (open != null) throw const FormatException('Mesai zaten açık');
        final shift = {
          'id': 'sh_$id',
          'employeeId': employeeId,
          'employeeName': staff['name'],
          'start': at,
          'source': payload['source'] == 'pos' ? 'pos' : 'remote',
          'corrections': <dynamic>[],
        };
        shifts.add(shift);
        return {'ok': true, 'shiftId': shift['id'], 'start': at};
      case 'clockOut':
        if (open == null) throw const FormatException('Açık mesai yok');
        final mutable = shifts.cast<Map>().firstWhere((x) => x['id'] == open['id']);
        mutable['end'] = at;
        return {'ok': true, 'shiftId': open['id'], 'end': at};
      default:
        throw const FormatException('Mesai işlemi geçersiz');
    }
  });
}

/// Audited manager correction (`shifts.manage`). Times are ISO-8601 UTC.
Json correctShift(PosStore store, Json payload) {
  final id = payload['requestId'];
  if (id is! String) throw const FormatException('İstek kimliği gerekli');
  return store.command(id, payload, (s) {
    final by = _activeEmployee(s, payload['staffId']);
    final reason = '${payload['reason'] ?? ''}'.trim();
    if (reason.isEmpty || reason.length > 300) throw const FormatException('Düzeltme nedeni gerekli');
    final shift = ((s['shifts'] ?? const []) as List).cast<Map>().where((x) => x['id'] == payload['shiftId']).firstOrNull;
    if (shift == null) throw const FormatException('Mesai kaydı yok');
    final start = DateTime.tryParse('${payload['start'] ?? shift['start']}');
    final endRaw = payload.containsKey('end') ? payload['end'] : shift['end'];
    final end = endRaw == null ? null : DateTime.tryParse('$endRaw');
    if (start == null || (endRaw != null && end == null)) throw const FormatException('Saat geçersiz');
    if (end != null && end.isBefore(start)) throw const FormatException('Bitiş başlangıçtan önce olamaz');
    final other = openShift(s, shift['employeeId'] as int);
    if (end == null && other != null && other['id'] != shift['id']) {
      throw const FormatException('Bu personelin başka açık mesaisi var');
    }
    final before = {'start': shift['start'], 'end': shift['end']};
    shift['start'] = start.toUtc().toIso8601String();
    if (end == null) {
      shift.remove('end');
    } else {
      shift['end'] = end.toUtc().toIso8601String();
    }
    ((shift['corrections'] ??= <dynamic>[]) as List).add({
      'at': DateTime.now().toUtc().toIso8601String(),
      'byId': by['id'],
      'by': by['name'],
      'before': before,
      'after': {'start': shift['start'], 'end': shift['end']},
      'reason': reason,
    });
    return {'ok': true, 'shiftId': shift['id']};
  });
}
