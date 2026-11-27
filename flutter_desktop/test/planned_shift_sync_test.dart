import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/sync_outbox.dart';
import 'package:nohut_falafel_desktop/workforce.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('planned overnight edit/cancellation keeps identity/history and never creates work', () {
    final dir = Directory.systemTemp.createTempSync('nohut-plan-sync');
    final store = PosStore(databaseFile: '${dir.path}/db');
    final db = sqlite3.open(store.filePath);
    addTearDown(() { db.dispose(); store.dispose(); dir.deleteSync(recursive: true); });
    final s = store.read();
    s.data['employees'] = [{'id': 2, 'name': 'Synthetic staff', 'active': true}];
    expect(store.replace(s.data, s.revision).ok, true);
    enableOutbox(db);
    final now = DateTime.utc(2026, 11, 26, 10);
    final first = applyPlanCommand(store, {'action': 'plan_save', 'requestId': 'synthetic-plan',
      'date': '2026-11-27', 'start': '22:00', 'end': '06:00', 'breakMinutes': 60},
      actorId: 2, actorName: 'Synthetic staff', now: now);
    final id = (first['ids'] as List).single;
    final original = shiftPlansOf(store.read().data).single;
    applyPlanCommand(store, {'action': 'plan_save', 'requestId': 'synthetic-edit', 'id': id,
      'expectedUpdatedAt': original['updatedAt'], 'date': '2026-11-27', 'start': '22:00', 'end': '07:00', 'breakMinutes': 30},
      actorId: 2, actorName: 'Synthetic staff', now: now);
    final updated = shiftPlansOf(store.read().data).single;
    applyPlanCommand(store, {'action': 'plan_cancel', 'requestId': 'synthetic-cancel', 'id': id,
      'expectedUpdatedAt': updated['updatedAt']}, actorId: 2, actorName: 'Synthetic staff', now: now);
    final events = pendingOutbox(db);
    expect(events, hasLength(3));
    final row = (jsonDecode(events.last['payload_json'] as String) as List).single as Map;
    expect(row['id'], id);
    expect(row['cancelled'], true);
    expect(row['endsNextDay'], true);
    expect((row['history'] as List), hasLength(2));
    expect(row['history'][0]['before']['breakMinutes'], 60);
    expect(row['history'][1]['action'], 'iptal');
    expect(store.read().data['shifts'] ?? [], isEmpty);
    expect(store.read().data['finance']?['payrollPayments'] ?? [], isEmpty);
  });
}
