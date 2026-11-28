// Phase 5C: Mesai Başlat / Bitir on the Windows authority. Synthetic data.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/remote_commands.dart';
import 'package:nohut_falafel_desktop/shifts.dart';

void main() {
  late Directory dir;
  late PosStore store;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('nohut-shifts');
    store = PosStore(databaseFile: '${dir.path}/db');
    expect(store.replace({...emptyPosState()}, store.read().revision).ok, true);
  });
  tearDown(() {
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  final t0 = DateTime.utc(2026, 11, 27, 9);

  test('clock in, clock out, worked minutes', () {
    submitShiftAction(store, {'requestId': 'shift_in_0001', 'action': 'clockIn', 'staffId': 2}, now: t0);
    expect(openShift(store.read().data, 2), isNotNull);
    expect(shiftMinutes(openShift(store.read().data, 2)!, t0.add(const Duration(minutes: 90))), 90);
    submitShiftAction(store, {'requestId': 'shift_out_0001', 'action': 'clockOut', 'staffId': 2}, now: t0.add(const Duration(hours: 8, minutes: 5)));
    final s = store.read().data;
    expect(openShift(s, 2), isNull);
    expect(workedMinutes(s, 2, DateTime.utc(2026, 11, 27), DateTime.utc(2026, 11, 28), t0), 485);
  });

  test('cannot open two shifts or close a missing one', () {
    submitShiftAction(store, {'requestId': 'shift_in_0002', 'action': 'clockIn', 'staffId': 2}, now: t0);
    expect(() => submitShiftAction(store, {'requestId': 'shift_in_0003', 'action': 'clockIn', 'staffId': 2}, now: t0),
        throwsA(isA<FormatException>()));
    expect(() => submitShiftAction(store, {'requestId': 'shift_out_0009', 'action': 'clockOut', 'staffId': 1}, now: t0),
        throwsA(isA<FormatException>()));
  });

  test('retry of the same request is idempotent', () {
    final p = {'requestId': 'shift_in_0004', 'action': 'clockIn', 'staffId': 2};
    submitShiftAction(store, p, now: t0);
    submitShiftAction(store, p, now: t0.add(const Duration(minutes: 1)));
    expect(shiftsOf(store.read().data), hasLength(1));
  });

  test('manager correction is audited, never silent', () {
    submitShiftAction(store, {'requestId': 'shift_in_0005', 'action': 'clockIn', 'staffId': 2}, now: t0);
    final id = shiftsOf(store.read().data).single['id'];
    expect(() => correctShift(store, {'requestId': 'fix_00000001', 'staffId': 1, 'shiftId': id, 'end': t0.add(const Duration(hours: 6)).toIso8601String()}),
        throwsA(isA<FormatException>())); // reason required
    correctShift(store, {
      'requestId': 'fix_00000002', 'staffId': 1, 'shiftId': id,
      'end': t0.add(const Duration(hours: 6)).toIso8601String(), 'reason': 'Mesai bitirmeyi unutmuş',
    });
    final shift = shiftsOf(store.read().data).single;
    expect(shift['end'], isNotNull);
    final c = asMaps(shift['corrections']).single;
    expect(c['reason'], 'Mesai bitirmeyi unutmuş');
    expect((c['before'] as Map)['end'], isNull);
    expect(() => correctShift(store, {
      'requestId': 'fix_00000003', 'staffId': 1, 'shiftId': id,
      'start': t0.toIso8601String(), 'end': t0.subtract(const Duration(hours: 1)).toIso8601String(), 'reason': 'x',
    }), throwsA(isA<FormatException>()));
  });

  test('correcting a manual Mesai keeps its break in both audit snapshots (Codex #39)', () {
    final st = store.read();
    final data = {...st.data, 'shifts': [
      {'id': 900, 'employeeId': 2, 'source': 'manual', 'start': '2026-11-24T07:00:00.000Z',
       'end': '2026-11-24T15:00:00.000Z', 'breakMinutes': 30},
    ]};
    expect(store.replace(data, st.revision).ok, true);
    // A corrected interval no longer than the break is refused.
    expect(() => correctShift(store, {'requestId': 'fix_brk_00000001', 'staffId': 1, 'shiftId': 900,
      'end': '2026-11-24T07:30:00.000Z', 'reason': 'Yanlış saat'}), throwsA(isA<FormatException>()));
    correctShift(store, {'requestId': 'fix_brk_00000002', 'staffId': 1, 'shiftId': 900,
      'end': '2026-11-24T14:00:00.000Z', 'reason': 'Erken çıktı'});
    final shift = shiftsOf(store.read().data).single;
    final c = asMaps(shift['corrections']).single;
    expect((c['before'] as Map)['breakMinutes'], 30);
    expect((c['after'] as Map)['breakMinutes'], 30);
    expect((c['after'] as Map)['end'], '2026-11-24T14:00:00.000Z');
    expect(shift['breakMinutes'], 30);
  });

  test('remote clock-in needs shifts.self and uses the envelope employee', () {
    Map<String, dynamic> env(List<String> grants, {String id = 'cmd_shift_0001'}) {
      final payload = {'action': 'clockIn', 'staffId': 999};
      return {
        'request_id': id, 'action_type': 'clock_in_out', 'client': 'personel',
        'actor': {'employee_id': 2, 'is_owner': false, 'grants': grants},
        'issued_at': t0.toIso8601String(), 'expires_at': t0.add(const Duration(minutes: 5)).toIso8601String(),
        'payload': payload, 'payload_sha256': payloadSha256(payload),
      };
    }

    expect(executeRemoteCommand(store, env(const []), now: t0).code, 'forbidden');
    final r = executeRemoteCommand(store, env(const ['shifts.self'], id: 'cmd_shift_0002'), now: t0);
    expect(r.outcome, CommandOutcome.confirmed, reason: r.result.toString());
    final shift = shiftsOf(store.read().data).single;
    expect(shift['employeeId'], 2);
    expect(shift['source'], 'remote');
  });
}
