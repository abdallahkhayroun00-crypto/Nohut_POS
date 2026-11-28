/// First full cloud sync from Windows (contract
/// `docs/contracts/v1/initial-sync-and-recovery.md`, PR #46).
///
/// * The snapshot is frozen locally first ([planInitialSync]): every batch,
///   its canonical body hash and the manifest are fixed and stored in
///   SQLite before `begin`, because the server pins the manifest at
///   `begin`. A resumed upload sends byte-for-byte the same batches.
/// * Canonical JSON is the exact text `nohut_private.canonical_command_json`
///   produces: keys in UTF-8 byte order, no whitespace, Postgres string
///   escaping, safe integers only (money in kuruş; decimals as strings).
/// * Batches hold at most 500 events and stay under the server's 4 MB cap
///   measured on the `jsonb::text` form (which has spaces after `:`/`,`).
/// * [InitialSyncRunner] is resumable: it asks `migration_status` first,
///   uploads only the batches the server lacks and treats `duplicate` as
///   done. A conflict or a server-side abort stops it; nothing is skipped.
/// * Incremental sync stays paused while a plan is not active, so phones
///   never see increments ahead of the snapshot. On activation the outbox
///   is acknowledged through the snapshot's sequence number.
/// * No network call ever happens inside a SQLite transaction.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as hash;
import 'package:sqlite3/sqlite3.dart';

import 'sync_outbox.dart';

const maxBatchEvents = 500;

/// Server cap is 4,194,304 bytes of `p_events::text`; keep a margin.
const maxBatchTextBytes = 4000000;

const snapshotEntityTypes = {
  'employees', 'typed_catalog', 'shiftPlans', 'shifts', 'timesheetWeeks',
  'typed_order', 'typed_platform', 'typed_print', 'typed_finance',
  'typed_ledger', 'workforceSummaries', 'qrMenuState', 'dailyReports',
  'notifications',
};

const _safeInt = 9007199254740991;

class CanonicalJsonException implements Exception {
  const CanonicalJsonException(this.message);
  final String message;
  @override
  String toString() => 'CanonicalJsonException: $message';
}

/// Canonical text plus the length Postgres reports for `jsonb::text`.
class CanonicalText {
  const CanonicalText(this.text, this.jsonbTextBytes);
  final String text;
  final int jsonbTextBytes;
}

/// The exact text of `nohut_private.canonical_command_json(v::jsonb)`.
String postgresCanonicalJson(Object? value) => canonicalWithSize(value).text;

CanonicalText canonicalWithSize(Object? value) {
  final out = StringBuffer();
  var separators = 0;
  void write(Object? v) {
    if (v == null) {
      out.write('null');
    } else if (v is bool) {
      out.write(v ? 'true' : 'false');
    } else if (v is int) {
      if (v < -_safeInt || v > _safeInt) {
        throw const CanonicalJsonException('integer outside the safe range');
      }
      out.write(v);
    } else if (v is double) {
      throw const CanonicalJsonException(
          'decimal number (use kuruş integers or a string)');
    } else if (v is String) {
      _writeString(out, v);
    } else if (v is List) {
      out.write('[');
      for (var i = 0; i < v.length; i++) {
        if (i > 0) {
          out.write(',');
          separators++;
        }
        write(v[i]);
      }
      out.write(']');
    } else if (v is Map) {
      final keys = <String>[];
      for (final k in v.keys) {
        if (k is! String) throw const CanonicalJsonException('non-string key');
        for (final unit in k.codeUnits) {
          if (unit >= 0xD800 && unit <= 0xDFFF) {
            throw const CanonicalJsonException('object key above U+FFFF');
          }
        }
        keys.add(k);
      }
      // BMP only, so UTF-16 code-unit order equals UTF-8 byte order ("C").
      keys.sort();
      out.write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) {
          out.write(',');
          separators++;
        }
        _writeString(out, keys[i]);
        out.write(':');
        separators++;
        write(v[keys[i]]);
      }
      out.write('}');
    } else {
      throw CanonicalJsonException('unsupported value ${v.runtimeType}');
    }
  }

  write(value);
  final text = out.toString();
  return CanonicalText(text, utf8.encode(text).length + separators);
}

/// Postgres `escape_json`: \" \\ \b \f \n \r \t, other controls as \u00xx
/// (lowercase), everything else raw. jsonb cannot hold U+0000.
void _writeString(StringBuffer out, String s) {
  out.write('"');
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c >= 0xD800 && c <= 0xDBFF) {
      if (i + 1 >= s.length) {
        throw const CanonicalJsonException('broken surrogate pair');
      }
      final d = s.codeUnitAt(i + 1);
      if (d < 0xDC00 || d > 0xDFFF) {
        throw const CanonicalJsonException('broken surrogate pair');
      }
      out.writeCharCode(c);
      out.writeCharCode(d);
      i++;
      continue;
    }
    if (c >= 0xDC00 && c <= 0xDFFF) {
      throw const CanonicalJsonException('broken surrogate pair');
    }
    switch (c) {
      case 0:
        throw const CanonicalJsonException('U+0000 is not allowed');
      case 0x22:
        out.write(r'\"');
      case 0x5C:
        out.write(r'\\');
      case 0x08:
        out.write(r'\b');
      case 0x0C:
        out.write(r'\f');
      case 0x0A:
        out.write(r'\n');
      case 0x0D:
        out.write(r'\r');
      case 0x09:
        out.write(r'\t');
      default:
        if (c < 0x20) {
          out.write(r'\u');
          out.write(c.toRadixString(16).padLeft(4, '0'));
        } else {
          out.writeCharCode(c);
        }
    }
  }
  out.write('"');
}

String sha256Hex(String text) => hash.sha256.convert(utf8.encode(text)).toString();

/// One staged snapshot event, as the server promotes it.
Map<String, Object?> snapshotEvent(String entityType, String entityId, Object? payload) {
  if (!snapshotEntityTypes.contains(entityType)) {
    throw CanonicalJsonException('unsupported snapshot entity type $entityType');
  }
  return {'entity_type': entityType, 'entity_id': entityId, 'payload': payload};
}

class SnapshotCategory {
  const SnapshotCategory(this.name, this.events);
  final String name;
  final List<Map<String, Object?>> events;
}

class PlannedBatch {
  const PlannedBatch({
    required this.ordinal,
    required this.batchId,
    required this.category,
    required this.itemCount,
    required this.bodySha256,
    required this.eventsJson,
  });
  final int ordinal, itemCount;
  final String batchId, category, bodySha256, eventsJson;

  String get manifestLine => '$category:$batchId:$itemCount:$bodySha256';
}

/// UUID-shaped id derived from the migration and the batch position, so a
/// re-planned identical snapshot never produces a second set of ids.
String deterministicBatchId(String migrationId, String category, int index) {
  final h = sha256Hex('nohut-snapshot-batch:$migrationId:$category:$index');
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-5${h.substring(13, 16)}-'
      'a${h.substring(17, 20)}-${h.substring(20, 32)}';
}

/// Same digest as `nohut_private.compute_migration_manifest_sha256`.
String manifestSha256(Iterable<PlannedBatch> batches) {
  final lines = [for (final b in batches) (b.batchId, b.manifestLine)]
    ..sort((a, b) => a.$1.compareTo(b.$1));
  return sha256Hex(lines.map((l) => l.$2).join('\n'));
}

/// Splits categories into capped batches (pure; no database).
List<PlannedBatch> planBatches(String migrationId, List<SnapshotCategory> categories,
    {int maxEvents = maxBatchEvents, int maxBytes = maxBatchTextBytes}) {
  final out = <PlannedBatch>[];
  final seen = <String>{};
  for (final cat in categories) {
    final name = cat.name;
    if (name.trim().isEmpty || name.length > 64 || name.trim() != name) {
      throw CanonicalJsonException('invalid category "$name"');
    }
    if (!seen.add(name)) throw CanonicalJsonException('duplicate category $name');
    var index = 0;
    var current = <String>[];
    var bytes = 2; // [ ]
    void flush() {
      if (current.isEmpty) return;
      final body = '[${current.join(',')}]';
      out.add(PlannedBatch(
        ordinal: out.length,
        batchId: deterministicBatchId(migrationId, name, index++),
        category: name,
        itemCount: current.length,
        bodySha256: sha256Hex(body),
        eventsJson: body,
      ));
      current = [];
      bytes = 2;
    }

    for (final ev in cat.events) {
      final type = ev['entity_type'];
      if (type is! String || !snapshotEntityTypes.contains(type)) {
        throw CanonicalJsonException('unsupported snapshot entity type $type');
      }
      final c = canonicalWithSize(ev);
      if (c.jsonbTextBytes + 2 > maxBytes) {
        throw CanonicalJsonException('one $type event is larger than a batch');
      }
      final extra = c.jsonbTextBytes + (current.isEmpty ? 0 : 2); // ", "
      if (current.length == maxEvents || bytes + extra > maxBytes) flush();
      bytes += c.jsonbTextBytes + (current.isEmpty ? 0 : 2);
      current.add(c.text);
    }
    flush();
  }
  return out;
}

void createInitialSyncTables(Database db) {
  createSyncTables(db);
  db.execute('''
    CREATE TABLE IF NOT EXISTS initial_sync_plan(
      migration_id TEXT PRIMARY KEY,
      authority_epoch TEXT NOT NULL,
      snapshot_revision INTEGER NOT NULL,
      snapshot_seq INTEGER NOT NULL,
      manifest_sha256 TEXT NOT NULL,
      batch_count INTEGER NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('planned','uploading','active','aborted')),
      backup_id TEXT,
      created_at TEXT NOT NULL,
      finished_at TEXT,
      last_error TEXT
    )
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS initial_sync_batches(
      migration_id TEXT NOT NULL,
      ordinal INTEGER NOT NULL,
      batch_id TEXT NOT NULL,
      category TEXT NOT NULL,
      item_count INTEGER NOT NULL,
      body_sha256 TEXT NOT NULL,
      events_json TEXT NOT NULL,
      uploaded_at TEXT,
      PRIMARY KEY(migration_id, batch_id)
    )
  ''');
}

class InitialSyncPlan {
  const InitialSyncPlan({
    required this.migrationId,
    required this.authorityEpoch,
    required this.snapshotRevision,
    required this.snapshotSeq,
    required this.manifestSha256,
    required this.batchCount,
    required this.status,
    this.backupId,
    this.lastError,
  });
  final String migrationId, authorityEpoch, manifestSha256, status;
  final int snapshotRevision, snapshotSeq, batchCount;
  final String? backupId, lastError;
}

/// The plan that is still in progress, or the last finished one.
InitialSyncPlan? currentInitialSyncPlan(Database db) {
  final rows = db.select(
      "SELECT * FROM initial_sync_plan ORDER BY (status IN ('planned','uploading')) DESC, "
      'created_at DESC LIMIT 1');
  if (rows.isEmpty) return null;
  final r = rows.single;
  return InitialSyncPlan(
    migrationId: r['migration_id'] as String,
    authorityEpoch: r['authority_epoch'] as String,
    snapshotRevision: r['snapshot_revision'] as int,
    snapshotSeq: r['snapshot_seq'] as int,
    manifestSha256: r['manifest_sha256'] as String,
    batchCount: r['batch_count'] as int,
    status: r['status'] as String,
    backupId: r['backup_id'] as String?,
    lastError: r['last_error'] as String?,
  );
}

List<PlannedBatch> plannedBatches(Database db, String migrationId) => [
  for (final r in db.select(
      'SELECT * FROM initial_sync_batches WHERE migration_id=? ORDER BY ordinal',
      [migrationId]))
    PlannedBatch(
      ordinal: r['ordinal'] as int,
      batchId: r['batch_id'] as String,
      category: r['category'] as String,
      itemCount: r['item_count'] as int,
      bodySha256: r['body_sha256'] as String,
      eventsJson: r['events_json'] as String,
    ),
];

/// True while a first sync is planned but not active: incremental events
/// must wait so the server checkpoint starts at the snapshot.
bool initialSyncHoldsIncremental(Database db) {
  final s = syncStateValue(db, 'initial_sync_state');
  return s != null && s != 'active';
}

String _uuid4() {
  final r = Random.secure();
  final b = List.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// Freezes the snapshot of [snapshotRevision]. [categories] must be built
/// from that revision's state; if the POS committed since, this refuses
/// (build again). Turns the outbox on in the same transaction so every
/// later change is an increment after `snapshot_seq`.
InitialSyncPlan planInitialSync(Database db, {
  required int snapshotRevision,
  required List<SnapshotCategory> categories,
  DateTime Function()? clock,
  String? migrationId,
}) {
  createInitialSyncTables(db);
  final now = (clock ?? () => DateTime.now().toUtc())().toIso8601String();
  final id = migrationId ?? _uuid4();
  final batches = planBatches(id, categories);
  final manifest = manifestSha256(batches);
  db.execute('BEGIN IMMEDIATE');
  try {
    final open = db.select(
        "SELECT 1 FROM initial_sync_plan WHERE status IN ('planned','uploading')");
    if (open.isNotEmpty) {
      throw const InitialSyncException('already_planned',
          'Bir ilk senkronizasyon zaten sürüyor. Devam edin veya iptal edin.');
    }
    final head = db.select('SELECT revision FROM state_snapshot WHERE id=1');
    if (head.isEmpty || head.single['revision'] != snapshotRevision) {
      throw const InitialSyncException('stale_snapshot',
          'Veriler bu sırada değişti. Anlık görüntü yeniden alınmalı.');
    }
    enableOutbox(db);
    final epoch = syncStateValue(db, 'authority_epoch')!;
    final seq = db.select('SELECT coalesce(max(seq),0) AS s FROM sync_outbox')
        .single['s'] as int;
    db.execute(
        'INSERT INTO initial_sync_plan(migration_id,authority_epoch,snapshot_revision,'
        'snapshot_seq,manifest_sha256,batch_count,status,created_at) '
        "VALUES(?,?,?,?,?,?,'planned',?)",
        [id, epoch, snapshotRevision, seq, manifest, batches.length, now]);
    final insert = db.prepare(
        'INSERT INTO initial_sync_batches(migration_id,ordinal,batch_id,category,'
        'item_count,body_sha256,events_json) VALUES(?,?,?,?,?,?,?)');
    try {
      for (final b in batches) {
        insert.execute([id, b.ordinal, b.batchId, b.category, b.itemCount,
          b.bodySha256, b.eventsJson]);
      }
    } finally {
      insert.dispose();
    }
    setSyncState(db, 'initial_sync_state', 'planned');
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
  return currentInitialSyncPlan(db)!;
}

class InitialSyncException implements Exception {
  const InitialSyncException(this.code, this.message);
  final String code, message;
  @override
  String toString() => 'InitialSyncException($code): $message';
}

/// Retryable transport failure (timeout, connection, 5xx, 429).
class InitialSyncNetworkException implements Exception {
  const InitialSyncNetworkException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The five Windows-agent RPCs. Implementations add the agent token;
/// server errors (4xx with a message) become [InitialSyncException].
abstract class InitialSyncTransport {
  Future<Map<String, Object?>> begin({
    required String migrationId,
    required int snapshotRevision,
    required int snapshotSeq,
    required String manifestSha256,
    required bool backupVerified,
  });

  /// [eventsJson] is the stored canonical array text, sent as `p_events`.
  Future<Map<String, Object?>> uploadBatch({
    required String migrationId,
    required String batchId,
    required String category,
    required int itemCount,
    required String bodySha256,
    required String eventsJson,
  });

  Future<Map<String, Object?>> activate({
    required String migrationId,
    required int expectedBatches,
    required String manifestSha256,
  });

  Future<Map<String, Object?>> abort({required String migrationId, String? reason});

  Future<Map<String, Object?>> status({String? migrationId});
}

/// Proof that an encrypted backup covering the snapshot was written and
/// read back successfully (see `BackupContainer.verify`).
class VerifiedBackup {
  const VerifiedBackup({required this.backupId, required this.revision});
  final String backupId;
  final int revision;
}

enum InitialSyncOutcome { active, retryLater, stopped }

class InitialSyncProgress {
  const InitialSyncProgress(this.outcome, {this.uploaded = 0, this.total = 0, this.message = ''});
  final InitialSyncOutcome outcome;
  final int uploaded, total;
  final String message;
}

class InitialSyncRunner {
  InitialSyncRunner(this.db, this.transport, {DateTime Function()? clock})
      : _clock = clock ?? (() => DateTime.now().toUtc());
  final Database db;
  final InitialSyncTransport transport;
  final DateTime Function() _clock;
  bool _running = false;

  String get _now => _clock().toIso8601String();

  void _setPlan(String id, String status, {String? error, bool finished = false}) {
    db.execute(
        'UPDATE initial_sync_plan SET status=?, last_error=?, '
        'finished_at=CASE WHEN ? THEN ? ELSE finished_at END WHERE migration_id=?',
        [status, error, finished ? 1 : 0, _now, id]);
  }

  void _stop(String id, String message) =>
      db.execute('UPDATE initial_sync_plan SET last_error=? WHERE migration_id=?', [message, id]);

  /// Runs or resumes the plan. [backup] is required the first time (before
  /// `begin`); a resume of a migration the server already knows needs none.
  Future<InitialSyncProgress> run({VerifiedBackup? backup,
      void Function(int uploaded, int total)? onProgress}) async {
    if (_running) {
      return const InitialSyncProgress(InitialSyncOutcome.retryLater,
          message: 'İlk senkronizasyon zaten çalışıyor.');
    }
    _running = true;
    try {
      return await _run(backup, onProgress);
    } finally {
      _running = false;
    }
  }

  Future<InitialSyncProgress> _run(VerifiedBackup? backup,
      void Function(int, int)? onProgress) async {
    final plan = currentInitialSyncPlan(db);
    if (plan == null || plan.status == 'aborted') {
      return const InitialSyncProgress(InitialSyncOutcome.stopped,
          message: 'Önce anlık görüntü alınmalı.');
    }
    if (plan.status == 'active') {
      return InitialSyncProgress(InitialSyncOutcome.active,
          uploaded: plan.batchCount, total: plan.batchCount);
    }
    final id = plan.migrationId;
    final batches = plannedBatches(db, id);
    if (batches.length != plan.batchCount || manifestSha256(batches) != plan.manifestSha256) {
      _stop(id, 'local_plan_corrupt');
      return const InitialSyncProgress(InitialSyncOutcome.stopped,
          message: 'Yerel senkronizasyon planı bozuk. İptal edip yeniden başlatın.');
    }
    try {
      var server = await transport.status(migrationId: id);
      if (server['exists'] != true) {
        if (backup == null || backup.revision < plan.snapshotRevision) {
          return const InitialSyncProgress(InitialSyncOutcome.stopped,
              message: 'Başlamadan önce bu verileri içeren doğrulanmış bir yedek gerekli.');
        }
        final r = await transport.begin(
          migrationId: id,
          snapshotRevision: plan.snapshotRevision,
          snapshotSeq: plan.snapshotSeq,
          manifestSha256: plan.manifestSha256,
          backupVerified: true,
        );
        if (r['status'] == 'conflict') {
          _stop(id, 'begin_conflict');
          return const InitialSyncProgress(InitialSyncOutcome.stopped,
              message: 'Bulut bu kimlikle farklı bir senkronizasyon biliyor.');
        }
        db.execute('UPDATE initial_sync_plan SET backup_id=?, status=? WHERE migration_id=?',
            [backup.backupId, 'uploading', id]);
        server = await transport.status(migrationId: id);
      }
      if (server['manifest_sha256'] != null && server['manifest_sha256'] != plan.manifestSha256) {
        _stop(id, 'manifest_mismatch');
        return const InitialSyncProgress(InitialSyncOutcome.stopped,
            message: 'Buluttaki plan bu bilgisayardakiyle aynı değil.');
      }
      final state = server['status'];
      if (state == 'active') return _finish(plan, batches.length);
      if (state == 'safely_aborted' || state == 'failed') {
        _setPlan(id, 'aborted', error: 'server_$state', finished: true);
        return const InitialSyncProgress(InitialSyncOutcome.stopped,
            message: 'Bulut bu senkronizasyonu iptal etti. Yeniden başlatın.');
      }
      if (plan.status == 'planned') _setPlan(id, 'uploading');
      final known = <String, Map>{
        for (final b in (server['batches'] as List? ?? const []))
          if (b is Map) '${b['batch_id']}': b,
      };
      var done = 0;
      for (final b in batches) {
        final k = known[b.batchId];
        if (k != null) {
          if (k['body_sha256'] != b.bodySha256 || k['item_count'] != b.itemCount ||
              k['category'] != b.category) {
            _stop(id, 'batch_conflict');
            return const InitialSyncProgress(InitialSyncOutcome.stopped,
                message: 'Buluttaki bir parti bu bilgisayardakiyle aynı değil.');
          }
        } else {
          final r = await transport.uploadBatch(
            migrationId: id, batchId: b.batchId, category: b.category,
            itemCount: b.itemCount, bodySha256: b.bodySha256, eventsJson: b.eventsJson);
          if (r['status'] != 'accepted' && r['status'] != 'duplicate') {
            _stop(id, 'batch_${r['status']}');
            return const InitialSyncProgress(InitialSyncOutcome.stopped,
                message: 'Bulut bir veri partisini kabul etmedi.');
          }
        }
        db.execute('UPDATE initial_sync_batches SET uploaded_at=coalesce(uploaded_at,?) '
            'WHERE migration_id=? AND batch_id=?', [_now, id, b.batchId]);
        onProgress?.call(++done, batches.length);
      }
      final a = await transport.activate(
          migrationId: id, expectedBatches: batches.length, manifestSha256: plan.manifestSha256);
      if (a['status'] != 'accepted' && a['status'] != 'duplicate') {
        _stop(id, 'activate_${a['status']}');
        return const InitialSyncProgress(InitialSyncOutcome.stopped,
            message: 'Bulut senkronizasyonu etkinleştirmedi.');
      }
      return _finish(plan, batches.length);
    } on InitialSyncNetworkException catch (e) {
      _stop(id, 'network: ${e.message}');
      return InitialSyncProgress(InitialSyncOutcome.retryLater,
          message: 'Buluta ulaşılamadı; kaldığı yerden devam edilecek.');
    } on InitialSyncException catch (e) {
      _stop(id, e.code);
      return InitialSyncProgress(InitialSyncOutcome.stopped, message: e.message);
    }
  }

  InitialSyncProgress _finish(InitialSyncPlan plan, int total) {
    db.execute('BEGIN IMMEDIATE');
    try {
      // The snapshot already contains every change up to snapshot_seq, so
      // the cloud checkpoint starts there (activate sets the same values).
      db.execute('UPDATE sync_outbox SET acked_at=? WHERE acked_at IS NULL AND seq<=?',
          [_now, plan.snapshotSeq]);
      setSyncState(db, 'last_acked_seq', '${plan.snapshotSeq}');
      setSyncState(db, 'last_acked_revision', '${plan.snapshotRevision}');
      setSyncState(db, 'last_sync_at', _now);
      _setPlan(plan.migrationId, 'active', finished: true);
      setSyncState(db, 'initial_sync_state', 'active');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    return InitialSyncProgress(InitialSyncOutcome.active, uploaded: total, total: total);
  }

  /// Aborts the plan locally and, when the server knows it, remotely.
  /// Incremental sync stays paused until a new plan becomes active.
  Future<void> abort({String reason = 'aborted_by_owner'}) async {
    final plan = currentInitialSyncPlan(db);
    if (plan == null || plan.status == 'active' || plan.status == 'aborted') return;
    final server = await transport.status(migrationId: plan.migrationId);
    if (server['exists'] == true && server['status'] != 'safely_aborted') {
      await transport.abort(migrationId: plan.migrationId, reason: reason);
    }
    _setPlan(plan.migrationId, 'aborted', error: reason, finished: true);
  }
}
