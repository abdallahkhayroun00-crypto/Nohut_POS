import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/sync_outbox.dart';
import 'package:nohut_falafel_desktop/workforce.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('manual create/edit/void outbox retains exact break and correction history', () {
    final dir = Directory.systemTemp.createTempSync('nohut-manual-sync');
    final store = PosStore(databaseFile: '${dir.path}/db');
    final db = sqlite3.open(store.filePath);
    addTearDown(() { db.dispose(); store.dispose(); dir.deleteSync(recursive: true); });
    final state = store.read();
    state.data['employees'] = [{'id': 2, 'name': 'Synthetic staff', 'active': true}];
    expect(store.replace(state.data, state.revision).ok, true);
    enableOutbox(db);
    final now = DateTime.utc(2026, 11, 24, 12);
    final first = applyWorkCommand(store, {'action': 'work_save', 'requestId': 'synthetic-work',
      'date': '2026-11-23', 'start': '09:00', 'end': '18:00', 'breakMinutes': 60, 'note': 'Synthetic work'},
      actorId: 2, actorName: 'Synthetic staff', now: now);
    final edited = applyWorkCommand(store, {'action': 'work_save', 'requestId': 'synthetic-edit',
      'id': first['id'], 'expectedUpdatedAt': first['updatedAt'],
      'date': '2026-11-23', 'start': '09:00', 'end': '18:00', 'breakMinutes': 30, 'note': 'Synthetic work'},
      actorId: 2, actorName: 'Synthetic staff', now: now);
    applyWorkCommand(store, {'action': 'work_void', 'requestId': 'synthetic-void', 'id': first['id'],
      'expectedUpdatedAt': edited['updatedAt'], 'reason': 'Synthetic correction'},
      actorId: 2, actorName: 'Synthetic staff', now: now);
    final events = pendingOutbox(db);
    expect(events, hasLength(3));
    final firstRow = (jsonDecode(events.first['payload_json'] as String) as List).single as Map;
    final last = (jsonDecode(events.last['payload_json'] as String) as List).single as Map;
    expect(workMinutes(Map<String,dynamic>.from(firstRow)), 480);
    expect(last['id'], firstRow['id']);
    expect(last['breakMinutes'], 30);
    expect(last['voided'], true);
    expect((last['corrections'] as List), hasLength(2));
    expect(last['corrections'][0]['before']['breakMinutes'], 60);
    expect(last['corrections'][0]['after']['breakMinutes'], 30);
    expect(workMinutes(Map<String,dynamic>.from(last)), 0);
  });
}
