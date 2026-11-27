import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/payroll.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/sync_outbox.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('actual Windows wage changes retain history in one durable private projection', () {
    final folder = Directory.systemTemp.createTempSync('nohut-wage-sync');
    final store = PosStore(databaseFile: '${folder.path}/pos.sqlite3');
    final db = sqlite3.open(store.filePath);
    addTearDown(() { db.dispose(); store.dispose(); folder.deleteSync(recursive: true); });
    final state = store.read();
    state.data['employees'] = [
      {'id': 1, 'name': 'Synthetic owner', 'active': true, 'payrollEligible': false},
      {'id': 2, 'name': 'Synthetic staff', 'active': true},
    ];
    expect(store.replace(state.data, state.revision).ok, true);
    enableOutbox(db);
    final next = store.read();
    setEmployeeRate(next.data, employeeId: 2, payType: 'Saatlik', rateCents: 10000,
        effectiveFrom: '2026-11-23', by: 'Synthetic manager', now: DateTime.utc(2026, 11, 22));
    setEmployeeRate(next.data, employeeId: 2, payType: 'Saatlik', rateCents: 12000,
        effectiveFrom: '2026-11-25', by: 'Synthetic manager', now: DateTime.utc(2026, 11, 24));
    expect(store.replace(next.data, next.revision).ok, true);
    final event = pendingOutbox(db).single;
    expect(event['entity_type'], 'employees');
    final rows = jsonDecode(event['payload_json'] as String) as List;
    expect(rows.first['payrollEligible'], false);
    final staff = rows[1] as Map;
    expect((staff['payHistory'] as List).map((r) => r['rateCents']), [10000, 12000]);
    expect(payRateOn(Map.from(staff), '2026-11-23')?.$2, 10000);
    expect(payRateOn(Map.from(staff), '2026-11-25')?.$2, 12000);
    expect(staff.keys, isNot(contains('password')));
  });
}
