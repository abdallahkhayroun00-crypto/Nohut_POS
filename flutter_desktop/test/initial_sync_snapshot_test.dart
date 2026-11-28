// First-sync snapshot from a realistic synthetic POS: built with the same
// outbox projection and typed serializers as incremental sync, then frozen,
// uploaded and activated against the in-memory agent server.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/initial_sync.dart';
import 'package:nohut_falafel_desktop/initial_sync_snapshot.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/sync_outbox.dart';
import 'package:sqlite3/sqlite3.dart';

import 'initial_sync_test.dart' show FakeAgentServer;
import 'support/synthetic_platform_order.dart';
import 'support/synthetic_pos.dart';

void main() {
  late Directory dir;
  late PosStore store;
  late Database db;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nohut-snapshot');
    store = PosStore(databaseFile: '${dir.path}/db');
    store.replace(buildSyntheticState(60), store.read().revision);
    db = sqlite3.open('${dir.path}/db');
  });
  tearDown(() {
    db.dispose();
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  test('synthetic POS → typed snapshot → frozen plan → active', () async {
    enableOutbox(db);
    store.prepareCloudOrderIdentities();
    final snap = store.read();
    final build = buildSnapshotCategories(db, state: snap.data, revision: snap.revision,
        sourceUpdatedAt: snap.updatedAt, authorityEpoch: syncStateValue(db, 'authority_epoch')!,
        now: DateTime.utc(2026, 11, 28, 9));
    // The generic synthetic TGO rows lack supplier/store/package ids:
    // reported per record, never sent and never silently dropped.
    expect(build.rejected.keys, ['trendyolGoOrders']);
    expect(build.rejected['trendyolGoOrders'], hasLength((snap.data['trendyolGoOrders'] as List).length));
    expect(build.skipped, isEmpty);
    expect(build.categories.map((c) => c.name), containsAll(['employees', 'typed_order', 'workforceSummaries']));
    expect(build.categories.singleWhere((c) => c.name == 'typed_order').events,
        hasLength((snap.data['orders'] as List).length));
    final plan = planInitialSync(db, snapshotRevision: snap.revision, categories: build.categories);
    final server = FakeAgentServer();
    final r = await InitialSyncRunner(db, server)
        .run(backup: VerifiedBackup(backupId: 'b', revision: snap.revision));
    expect(r.outcome, InitialSyncOutcome.active, reason: r.message);
    final sent = server.batches[plan.migrationId]!.values
        .expand((b) => b['events'] as List).length;
    expect(sent, build.eventCount);
  });

  test('an API-shaped platform order becomes typed_platform', () {
    enableOutbox(db);
    final s = store.read().data..['trendyolGoOrders'] = [syntheticPlatformOrder()];
    store.replace(s, store.read().revision);
    store.prepareCloudOrderIdentities();
    final snap = store.read();
    final build = buildSnapshotCategories(db, state: snap.data, revision: snap.revision,
        sourceUpdatedAt: snap.updatedAt, authorityEpoch: syncStateValue(db, 'authority_epoch')!);
    expect(build.rejected, isEmpty);
    final platform = build.categories.singleWhere((c) => c.name == 'typed_platform').events.single;
    expect(platform['entity_id'], '12345:456:synthetic-package');
    expect('${platform['payload']}', isNot(contains('Private')), reason: 'no customer names in cloud');
  });
}
