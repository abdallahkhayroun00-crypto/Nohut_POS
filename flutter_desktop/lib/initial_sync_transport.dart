/// HTTPS adapter for the first-sync RPCs over the scoped Windows agent
/// token ([SupabaseAgentTransport]). Retryable failures become
/// [InitialSyncNetworkException]; refusals become [InitialSyncException].
library;

import 'dart:convert';

import 'initial_sync.dart';
import 'supabase_agent_transport.dart';
import 'sync_worker.dart' show SyncNetworkException;

typedef AgentRpc = Future<Object?> Function(String method, Map<String, Object?> args);

class AgentInitialSyncTransport implements InitialSyncTransport {
  AgentInitialSyncTransport(this._rpc);
  factory AgentInitialSyncTransport.over(SupabaseAgentTransport agent) =>
      AgentInitialSyncTransport(agent.initialSyncRpc);
  final AgentRpc _rpc;

  Future<Map<String, Object?>> _call(String method, Map<String, Object?> args) async {
    final Object? r;
    try {
      r = await _rpc(method, args);
    } on SyncNetworkException catch (e) {
      throw InitialSyncNetworkException(e.message);
    } on AgentTransportException catch (e) {
      throw InitialSyncException(e.code, 'Bulut isteği reddetti ($method: ${e.code}).');
    }
    if (r is! Map) throw InitialSyncException('invalid_response', 'Bulut yanıtı okunamadı ($method).');
    return Map<String, Object?>.from(r);
  }

  @override
  Future<Map<String, Object?>> begin({required String migrationId, required int snapshotRevision,
      required int snapshotSeq, required String manifestSha256, required bool backupVerified}) =>
      _call('nohut_agent_begin_initial_sync', {
        'p_migration_id': migrationId, 'p_snapshot_revision': snapshotRevision,
        'p_snapshot_seq': snapshotSeq, 'p_manifest_sha256': manifestSha256,
        'p_backup_verified': backupVerified,
      });

  @override
  Future<Map<String, Object?>> uploadBatch({required String migrationId, required String batchId,
      required String category, required int itemCount, required String bodySha256,
      required String eventsJson}) =>
      _call('nohut_agent_upload_snapshot_batch', {
        'p_migration_id': migrationId, 'p_batch_id': batchId, 'p_category': category,
        'p_item_count': itemCount, 'p_body_sha256': bodySha256,
        // A JSON array (jsonb), not a string; the server re-canonicalizes it.
        'p_events': jsonDecode(eventsJson),
      });

  @override
  Future<Map<String, Object?>> activate({required String migrationId, required int expectedBatches,
      required String manifestSha256}) =>
      _call('nohut_agent_activate_initial_sync', {
        'p_migration_id': migrationId, 'p_expected_batches': expectedBatches,
        'p_expected_manifest_sha256': manifestSha256,
      });

  @override
  Future<Map<String, Object?>> abort({required String migrationId, String? reason}) =>
      _call('nohut_agent_abort_initial_sync', {'p_migration_id': migrationId, 'p_reason': reason});

  @override
  Future<Map<String, Object?>> status({String? migrationId}) =>
      _call('nohut_agent_migration_status', {'p_migration_id': migrationId});
}
