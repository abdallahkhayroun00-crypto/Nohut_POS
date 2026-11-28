// The first-sync HTTPS adapter sends the contract's parameter names, sends
// p_events as a JSON array, and maps failures the runner understands.
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/initial_sync.dart';
import 'package:nohut_falafel_desktop/initial_sync_transport.dart';
import 'package:nohut_falafel_desktop/supabase_agent_transport.dart';
import 'package:nohut_falafel_desktop/sync_worker.dart';

void main() {
  test('parameter names, array body and error mapping', () async {
    final calls = <(String, Map<String, Object?>)>[];
    Object? next = {'status': 'accepted'};
    Object? fail;
    final t = AgentInitialSyncTransport((m, a) async {
      calls.add((m, a));
      final f = fail;
      if (f != null) throw f;
      return next;
    });
    await t.begin(migrationId: 'm', snapshotRevision: 7, snapshotSeq: 3,
        manifestSha256: 'a' * 64, backupVerified: true);
    await t.uploadBatch(migrationId: 'm', batchId: 'b', category: 'employees', itemCount: 1,
        bodySha256: 'c' * 64, eventsJson: '[{"entity_id":"core","entity_type":"employees","payload":[]}]');
    await t.activate(migrationId: 'm', expectedBatches: 1, manifestSha256: 'a' * 64);
    await t.status(migrationId: 'm');
    await t.abort(migrationId: 'm', reason: 'x');
    expect(calls.map((c) => c.$1), [
      'nohut_agent_begin_initial_sync', 'nohut_agent_upload_snapshot_batch',
      'nohut_agent_activate_initial_sync', 'nohut_agent_migration_status',
      'nohut_agent_abort_initial_sync',
    ]);
    expect(calls[0].$2.keys, ['p_migration_id', 'p_snapshot_revision', 'p_snapshot_seq',
      'p_manifest_sha256', 'p_backup_verified']);
    expect(calls[1].$2['p_events'], isA<List>());
    expect(calls[2].$2.keys, contains('p_expected_manifest_sha256'));

    fail = const SyncNetworkException('down');
    await expectLater(t.status(), throwsA(isA<InitialSyncNetworkException>()));
    fail = const AgentTransportException('rpc_refused');
    await expectLater(t.status(), throwsA(isA<InitialSyncException>()
        .having((e) => e.code, 'code', 'rpc_refused')));
    fail = null;
    next = 'not a map';
    await expectLater(t.status(), throwsA(isA<InitialSyncException>()));
  });
}
