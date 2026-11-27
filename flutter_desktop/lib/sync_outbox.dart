/// Phase 2 / PR-04: local transactional outbox (spec V5.1 §4.4, §18.1).
///
/// * Events are written in the SAME SQLite transaction as the business
///   change they describe (no network call ever happens inside it).
/// * One event per changed entity row (`upsert` / `delete`) and per changed
///   top-level core key, carrying only the cloud-allowlisted projection
///   ([projectForCloud]); personal contact data never enters the outbox.
/// * Deterministic `event_id` = `<epoch>:<revision>:<type>:<id>` and a
///   SHA-256 over canonical JSON make retries idempotent.
/// * Disabled by default: the owner's first-sync wizard turns it on
///   (spec §5.1 step 8). While disabled nothing is recorded.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as hash;
import 'package:sqlite3/sqlite3.dart';

import 'entity_storage.dart';
import 'sync_field_registry.dart';

void createSyncTables(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS sync_outbox(
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      event_id TEXT UNIQUE NOT NULL,
      revision INTEGER NOT NULL,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      op TEXT NOT NULL CHECK(op IN ('upsert','delete')),
      payload_json TEXT NOT NULL,
      payload_sha256 TEXT NOT NULL,
      created_at TEXT NOT NULL,
      sent_at TEXT,
      acked_at TEXT,
      retry_count INTEGER NOT NULL DEFAULT 0,
      last_error TEXT
    )
  ''');
  db.execute(
    'CREATE TABLE IF NOT EXISTS sync_state(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  );
}

String? syncStateValue(Database db, String key) {
  final rows = db.select('SELECT value FROM sync_state WHERE key=?', [key]);
  return rows.isEmpty ? null : rows.single['value'] as String;
}

void setSyncState(Database db, String key, String value) => db.execute(
  'INSERT OR REPLACE INTO sync_state(key,value) VALUES(?,?)',
  [key, value],
);

bool outboxEnabled(Database db) => syncStateValue(db, 'outbox_enabled') == '1';

/// Turns recording on and mints the authority epoch if there is none.
void enableOutbox(Database db) {
  // The outbox is fed by the per-entity diff; on a legacy single-JSON
  // database it would silently record nothing. Refuse instead.
  if (!isNormalized(db)) {
    throw const FormatException(
      'Senkronizasyon için veri taşıma (Phase 1B) tamamlanmış olmalı.',
    );
  }
  if (syncStateValue(db, 'authority_epoch') == null) {
    final r = Random.secure();
    final epoch = List.generate(16, (_) => r.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    setSyncState(db, 'authority_epoch', epoch);
  }
  setSyncState(db, 'outbox_enabled', '1');
}

/// Canonical JSON: map keys sorted recursively, no whitespace. The same
/// canonical form must be used by the server when it re-hashes (§18.1).
String canonicalJson(Object? value) {
  Object? sort(Object? v) {
    if (v is Map) {
      final keys = v.keys.map((k) => '$k').toList()..sort();
      return {for (final k in keys) k: sort(v[k])};
    }
    if (v is List) return [for (final x in v) sort(x)];
    return v;
  }

  return jsonEncode(sort(value));
}

class OutboxChange {
  const OutboxChange(this.entityType, this.entityId, this.op, this.row);
  final String entityType, entityId, op;

  /// Full local row (projected before storing); null for `delete`.
  final Object? row;
}

/// Projects one entity row through the cloud allowlist.
Object? projectRow(String stateKey, Object? row) {
  final projected = projectForCloud({stateKey: [row]});
  final list = projected[stateKey];
  return list is List && list.isNotEmpty ? list.single : null;
}

/// Projects one core top-level value; null when the key is not syncable.
Object? projectCore(String key, Object? value) =>
    projectForCloud({key: value})[key];

/// Diff the previous and next committed state using the cloud projection.
/// Receipt snapshots are intentionally deferred to their dedicated Phase 2
/// contract. Local-only keys must not produce even deletion events.
/// This only records local events; it is not a cloud transport or an
/// authorization to activate sync on production data.
List<OutboxChange> collectOutboxChanges(
  Map<String, dynamic> previous,
  Map<String, dynamic> next,
) {
  final changes = <OutboxChange>[];
  final entityKeys = {for (final kind in entityKinds) kind.stateKey};
  for (final kind in entityKinds) {
    final key = kind.stateKey;
    if (key == 'printJobs') continue;
    Map<String, Object?> byId(Map<String, dynamic> state) {
      final rows = state[key];
      if (rows is! List) return {};
      if (rows.any((row) => row is! Map)) {
        throw const FormatException('Invalid sync entity row');
      }
      final ids = rowKeys(kind, rows);
      if (ids.toSet().length != ids.length) {
        throw const FormatException('Duplicate sync entity identity');
      }
      return {for (var i = 0; i < rows.length; i++) ids[i]: rows[i]};
    }

    final before = byId(previous), after = byId(next);
    for (final id in {...before.keys, ...after.keys}) {
      final oldRow = before[id], newRow = after[id];
      if (jsonEquals(oldRow, newRow)) continue;
      final oldProjection = oldRow == null ? null : projectRow(key, oldRow);
      final newProjection = newRow == null ? null : projectRow(key, newRow);
      if (jsonEquals(oldProjection, newProjection)) continue;
      changes.add(OutboxChange(
        key, id, newProjection == null ? 'delete' : 'upsert', newRow,
      ));
    }
  }
  for (final key in {...previous.keys, ...next.keys}) {
    if (entityKeys.contains(key)) continue;
    if (jsonEquals(previous[key], next[key])) continue;
    final oldProjection = projectCore(key, previous[key]);
    final newProjection = projectCore(key, next[key]);
    if (jsonEquals(oldProjection, newProjection)) continue;
    changes.add(OutboxChange(
      key, 'core', newProjection == null ? 'delete' : 'upsert', next[key],
    ));
  }
  return changes;
}

/// Writes the events for one committed revision. Call inside the business
/// transaction, after the state rows are written.
int writeOutboxEvents(
  Database db, {
  required int revision,
  required String createdAt,
  required List<OutboxChange> changes,
}) {
  if (!outboxEnabled(db)) return 0;
  final epoch = syncStateValue(db, 'authority_epoch');
  if (epoch == null || epoch.isEmpty) {
    throw const FormatException('Sync authority epoch missing');
  }
  final insert = db.prepare(
    'INSERT INTO sync_outbox(event_id,revision,entity_type,entity_id,op,'
    'payload_json,payload_sha256,created_at) VALUES(?,?,?,?,?,?,?,?)',
  );
  var written = 0;
  try {
    for (final change in changes) {
      final Object? payload;
      if (change.op == 'delete') {
        payload = null;
      } else {
        payload = change.entityId == 'core'
            ? projectCore(change.entityType, change.row)
            : projectRow(change.entityType, change.row);
        // Not syncable (e.g. device settings, contact directory): skip.
        if (payload == null) continue;
      }
      final body = canonicalJson(payload);
      insert.execute([
        '$epoch:$revision:${change.entityType}:${change.entityId}',
        revision,
        change.entityType,
        change.entityId,
        change.op,
        body,
        hash.sha256.convert(utf8.encode(body)).toString(),
        createdAt,
      ]);
      written++;
    }
  } finally {
    insert.dispose();
  }
  return written;
}

/// Pending (not yet acknowledged) events, oldest first.
List<Map<String, Object?>> pendingOutbox(Database db, {int limit = 500}) => [
  for (final row in db.select(
    'SELECT * FROM sync_outbox WHERE acked_at IS NULL ORDER BY seq LIMIT ?',
    [limit],
  ))
    {for (final k in row.keys) k: row[k]},
];

/// Marks events up to and including [seq] acknowledged by the cloud. Only
/// a contiguous watermark may be acknowledged (spec §18.1: never skip a gap).
void ackOutboxThrough(Database db, int seq, String at) {
  final gap = db.select(
    'SELECT min(seq) AS m FROM sync_outbox WHERE acked_at IS NULL',
  ).single['m'];
  if (gap == null) return;
  db.execute(
    'UPDATE sync_outbox SET acked_at=? WHERE acked_at IS NULL AND seq<=?',
    [at, seq],
  );
}
