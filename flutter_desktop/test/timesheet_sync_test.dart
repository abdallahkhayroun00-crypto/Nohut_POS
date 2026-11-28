import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/sync_outbox.dart';
import 'package:nohut_falafel_desktop/workforce.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('weekly snapshots retain every submission and explicit no-work, never approvals', () {
    final dir = Directory.systemTemp.createTempSync('nohut-timesheet-sync');
    final store = PosStore(databaseFile: '${dir.path}/db');
    final db = sqlite3.open(store.filePath);
    addTearDown(() { db.dispose(); store.dispose(); dir.deleteSync(recursive: true); });
    final s = store.read();
    s.data['employees'] = [{'id': 2, 'name': 'Synthetic staff', 'active': true}];
    expect(store.replace(s.data, s.revision).ok, true);
    enableOutbox(db);
    final now = DateTime.utc(2026, 11, 24, 12);
    final first = applyWorkCommand(store, {'action': 'work_save', 'requestId': 'synthetic-work',
      'date': '2026-11-23', 'start': '09:00', 'end': '18:00', 'breakMinutes': 60}, actorId: 2, actorName: 'Synthetic staff', now: now);
    submitWeek(store, {'requestId': 'synthetic-submit', 'weekStart': '2026-11-23'}, actorId: 2, now: now);
    final edit = applyWorkCommand(store, {'action': 'work_save', 'requestId': 'synthetic-edit',
      'id': first['id'], 'expectedUpdatedAt': first['updatedAt'], 'date': '2026-11-23', 'start': '09:00', 'end': '18:00', 'breakMinutes': 30},
      actorId: 2, actorName: 'Synthetic staff', now: now);
    expect(weekStatus(store.read().data, 2, '2026-11-23')['status'], 'Değişti');
    submitWeek(store, {'requestId': 'synthetic-resubmit', 'weekStart': '2026-11-23'}, actorId: 2, now: now);
    applyWorkCommand(store, {'action': 'work_void', 'requestId': 'synthetic-void', 'id': first['id'],
      'expectedUpdatedAt': edit['updatedAt'], 'reason': 'Synthetic correction'}, actorId: 2, actorName: 'Synthetic staff', now: now);
    submitWeek(store, {'requestId': 'synthetic-no-work', 'weekStart': '2026-11-23', 'noWork': true}, actorId: 2, now: now);
    final events = pendingOutbox(db).where((e) => e['entity_type']=='timesheetWeeks').toList();
    expect(events, hasLength(3));
    final row = (jsonDecode(events.last['payload_json'] as String) as List).single as Map;
    expect(row['id'], 'tw_2_2026-11-23');
    expect((row['history'] as List).map((h) => h['minutes']), [480, 510, 0]);
    expect(row['history'][0]['entries'][0]['breakMinutes'], 60);
    expect(row['history'][1]['entries'][0]['breakMinutes'], 30);
    expect(row['noWork'], true);
    expect(weekStatus(store.read().data, 2, '2026-11-23')['status'], 'Çalışma yok');
  });
}
