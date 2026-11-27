/// Phase 2 / PR-06 (client side): the single incremental SyncWorker
/// (spec V5.1 §6.1–6.2, §18.1).
///
/// * Exactly one worker per POS. Manual "Şimdi Senkronize Et" and the
///   automatic debounce (2 s, max 5 s) both call [SyncWorker.flush], which is
///   single-flight.
/// * Outbox events are grouped by source revision into atomic transaction
///   groups (one POS commit = one group) matching the server tables
///   `nohut_private.sync_transactions` / `sync_event_ids`.
/// * Deterministic `tx_id` (UUID shape derived from epoch + revision) and a
///   group `body_sha256` over the ordered event hashes make retries
///   idempotent: a lost acknowledgement is resent and recognised as a
///   duplicate, never applied twice.
/// * Only a contiguous watermark is acknowledged locally; a conflict stops
///   the worker (no skipping); network errors back off exponentially.
/// * No network call ever happens inside a SQLite transaction.
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as hash;
import 'package:sqlite3/sqlite3.dart';

import 'sync_outbox.dart';

const syncSchemaVersion = 1;

class SyncEvent {
  const SyncEvent({
    required this.seq,
    required this.eventId,
    required this.entityType,
    required this.entityId,
    required this.op,
    required this.payloadJson,
    required this.payloadSha256,
    required this.ordinal,
  });
  final int seq, ordinal;
  final String eventId, entityType, entityId, op, payloadJson, payloadSha256;

  Map<String, Object?> toJson() => {
    'seq': seq,
    'event_id': eventId,
    'event_ordinal': ordinal,
    'entity_type': entityType,
    'entity_id': entityId,
    'op': op,
    'payload': jsonDecode(payloadJson),
    // Preserve exact UTF-8 bytes for server-side verification of the hash.
    'payload_json': payloadJson,
    'body_sha256': payloadSha256,
  };
}

/// One POS commit (all its events), sent and acknowledged atomically.
class SyncTransaction {
  SyncTransaction({
    required this.authorityEpoch,
    required this.sourceRevision,
    required this.events,
  });
  final String authorityEpoch;
  final int sourceRevision;
  final List<SyncEvent> events;

  int get firstSeq => events.first.seq;
  int get lastSeq => events.last.seq;

  /// Deterministic UUID-shaped id: same commit → same id on every retry.
  String get txId {
    final h = hash.sha256
        .convert(utf8.encode('nohut-tx:$authorityEpoch:$sourceRevision'))
        .toString();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-5${h.substring(13, 16)}-'
        'a${h.substring(17, 20)}-${h.substring(20, 32)}';
  }

  /// SHA-256 over the ordered event hashes (canonical, order-sensitive).
  String get bodySha256 => hash.sha256
      .convert(utf8.encode(events.map((e) => e.payloadSha256).join('\n')))
      .toString();

  Map<String, Object> toJson() => {
    'authority_epoch': authorityEpoch,
    'tx_id': txId,
    'source_revision': sourceRevision,
    'first_seq': firstSeq,
    'last_seq': lastSeq,
    'event_count': events.length,
    'schema_version': syncSchemaVersion,
    'body_sha256': bodySha256,
    'events': [for (final e in events) e.toJson()],
  };
}

enum IngestStatus { accepted, duplicate, conflict, gap }

class IngestResult {
  const IngestResult(this.status, {this.message = '', this.ackedThroughSeq});
  final IngestStatus status;
  final String message;

  /// Server's contiguous watermark after this call (if it reports one).
  final int? ackedThroughSeq;
}

/// Network boundary. Throw [SyncNetworkException] for retryable failures
/// (timeout, connection, 5xx, 429); return [IngestResult] for answers.
abstract class SyncTransport {
  Future<IngestResult> ingest(SyncTransaction tx);
}

class SyncNetworkException implements Exception {
  const SyncNetworkException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Permanent transport/auth/schema failure. Keep every event and require
/// owner reconciliation rather than throwing out of an automatic timer.
class SyncRejectedException implements Exception {
  const SyncRejectedException(this.code);
  final String code;
  @override
  String toString() => code;
}

/// Groups pending outbox rows (oldest first) into commit transactions.
List<SyncTransaction> groupPending(Database db, {int limitEvents = 500}) {
  final epoch = syncStateValue(db, 'authority_epoch');
  if (epoch == null) return const [];
  if (limitEvents < 1) throw ArgumentError.value(limitEvents, 'limitEvents');
  final rows = pendingOutbox(db, limit: limitEvents);
  // The limit is a soft batching target, never a transaction boundary.
  // Read the rest of the last selected revision, if any, in sequence order.
  if (rows.length == limitEvents) {
    final last = rows.last;
    for (final row in db.select(
      'SELECT * FROM sync_outbox WHERE acked_at IS NULL '
      'AND revision=? AND seq>? ORDER BY seq',
      [last['revision'], last['seq']],
    )) {
      rows.add({for (final k in row.keys) k: row[k]});
    }
  }
  final groups = <int, List<SyncEvent>>{};
  final order = <int>[];
  for (final r in rows) {
    final rev = r['revision'] as int;
    final list = groups.putIfAbsent(rev, () {
      order.add(rev);
      return <SyncEvent>[];
    });
    list.add(SyncEvent(
      seq: r['seq'] as int,
      ordinal: list.length,
      eventId: r['event_id'] as String,
      entityType: r['entity_type'] as String,
      entityId: r['entity_id'] as String,
      op: r['op'] as String,
      payloadJson: r['payload_json'] as String,
      payloadSha256: r['payload_sha256'] as String,
    ));
  }
  return [
    for (final rev in order)
      SyncTransaction(
        authorityEpoch: epoch,
        sourceRevision: rev,
        events: groups[rev]!,
      ),
  ];
}

class SyncStatus {
  const SyncStatus({
    required this.pending,
    required this.lastSuccessAt,
    required this.lastError,
    required this.stopped,
    required this.nextAttemptAt,
  });
  final int pending;
  final String? lastSuccessAt, lastError, nextAttemptAt;
  final bool stopped;
}

class SyncWorker {
  SyncWorker(
    this.db,
    this.transport, {
    DateTime Function()? clock,
    this.debounce = const Duration(seconds: 2),
    this.maxWait = const Duration(seconds: 5),
  }) : _clock = clock ?? (() => DateTime.now().toUtc());

  /// A dedicated connection to the POS database (WAL allows concurrent
  /// readers; acknowledgements are tiny writes).
  final Database db;
  final SyncTransport transport;
  final Duration debounce, maxWait;
  final DateTime Function() _clock;

  bool _flushing = false;
  Timer? _debounceTimer;
  DateTime? _firstSignal;
  int _failures = 0;

  /// Exponential backoff after retryable failures: 2 s … 5 min.
  Duration get backoff {
    if (_failures == 0) return Duration.zero;
    final seconds = 2 << (_failures - 1).clamp(0, 8);
    return Duration(seconds: seconds > 300 ? 300 : seconds);
  }

  SyncStatus status() => SyncStatus(
    pending: (db.select(
      'SELECT count(*) AS n FROM sync_outbox WHERE acked_at IS NULL',
    ).single['n'] as int),
    lastSuccessAt: syncStateValue(db, 'last_sync_at'),
    lastError: syncStateValue(db, 'last_sync_error'),
    stopped: syncStateValue(db, 'sync_stopped') == '1',
    nextAttemptAt: syncStateValue(db, 'next_attempt_at'),
  );

  /// Debounced trigger after a local commit (2 s, at most 5 s after the
  /// first signal) so rapid edits share one request.
  void notifyCommitted() {
    _firstSignal ??= _clock();
    _debounceTimer?.cancel();
    final waited = _clock().difference(_firstSignal!);
    final delay = waited >= maxWait ? Duration.zero : debounce;
    _debounceTimer = Timer(delay, () {
      _firstSignal = null;
      unawaited(flush());
    });
  }

  void dispose() => _debounceTimer?.cancel();

  /// Sends all complete pending groups in order. Single-flight: a second
  /// call while one runs returns the running one's outcome count of 0.
  /// Returns the number of acknowledged events.
  Future<int> flush({bool manual = false}) async {
    if (_flushing) return 0;
    if (!outboxEnabled(db)) return 0;
    if (syncStateValue(db, 'remote_execution_blocked') != null) return 0;
    if (syncStateValue(db, 'sync_stopped') == '1' && !manual) return 0;
    final next = DateTime.tryParse(syncStateValue(db, 'next_attempt_at') ?? '');
    if (!manual && next != null && _clock().isBefore(next)) return 0;
    _flushing = true;
    var acked = 0;
    try {
      while (true) {
        final txs = groupPending(db);
        if (txs.isEmpty) break;
        for (final tx in txs) {
          final IngestResult result;
          try {
            result = await transport.ingest(tx);
          } on SyncNetworkException catch (e) {
            _failures++;
            setSyncState(db, 'last_sync_error', 'Ağ: ${e.message}');
            setSyncState(db, 'next_attempt_at',
                _clock().add(backoff).toIso8601String());
            return acked;
          } on SyncRejectedException catch (e) {
            setSyncState(db, 'sync_stopped', '1');
            setSyncState(db, 'last_sync_error', 'transport: ${e.code}');
            return acked;
          }
          switch (result.status) {
            case IngestStatus.accepted:
            case IngestStatus.duplicate:
              // Duplicate = the server already committed this exact group
              // (e.g. the previous acknowledgement was lost).
              final watermark = result.ackedThroughSeq;
              if (watermark == null || watermark < tx.lastSeq) {
                setSyncState(db, 'sync_stopped', '1');
                setSyncState(db, 'last_sync_error',
                    'conflict: invalid or missing server checkpoint');
                return acked;
              }
              ackOutboxThrough(db, tx.lastSeq, _clock().toIso8601String());
              acked += tx.events.length;
              _failures = 0;
              setSyncState(db, 'last_sync_at', _clock().toIso8601String());
              db.execute("DELETE FROM sync_state WHERE key IN "
                  "('last_sync_error','next_attempt_at')");
            case IngestStatus.conflict:
            case IngestStatus.gap:
              // Never skip: stop and surface for owner reconciliation.
              setSyncState(db, 'sync_stopped', '1');
              setSyncState(db, 'last_sync_error',
                  '${result.status.name}: ${result.message}');
              return acked;
          }
        }
      }
      if (manual) db.execute("DELETE FROM sync_state WHERE key='sync_stopped'");
      return acked;
    } finally {
      _flushing = false;
    }
  }
}
