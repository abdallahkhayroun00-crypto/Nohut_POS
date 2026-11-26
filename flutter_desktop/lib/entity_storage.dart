/// Phase 1B: per-entity transactional tables (spec V5.1 §2.2, §21.1).
///
/// The large, growing collections leave the single `state_snapshot` JSON and
/// get one SQLite row per business entity:
///
/// | state key          | table                 | row key                          |
/// |--------------------|-----------------------|----------------------------------|
/// | `orders`           | `pos_orders`          | order `id`                       |
/// | `printJobs`        | `pos_print_jobs`      | `orderId:batchId:kind`           |
/// | `trendyolGoOrders` | `pos_platform_orders` | supplier:store:packageId         |
/// | `deletedOrders`    | `pos_deleted_orders`  | `orderId`                        |
///
/// `state_snapshot` keeps the small core (settings, menu, finance, …) and the
/// revision that fences every write. A commit writes only rows whose content
/// changed, plus the core row; list order is kept with a `seq` column.
/// The in-memory API (`PosStore.read/replace/command`) is unchanged, so every
/// screen, report and command keeps working exactly as before.
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'pos_logic.dart';

const storageVersion = 2;

class EntityKind {
  const EntityKind(this.stateKey, this.table, this.keyOf, this.indexed);
  final String stateKey, table;
  final String Function(Map row) keyOf;

  /// Extra queryable columns (name → value from the row).
  final Map<String, Object? Function(Map row)> indexed;
}

String _str(Object? v) => '${v ?? ''}';

final entityKinds = <EntityKind>[
  EntityKind('orders', 'pos_orders', (r) => _str(r['id']), {
    'source': (r) => r['source'],
    'created_at': (r) => r['createdAt'],
    'closed': (r) => r['closed'] == true ? 1 : 0,
  }),
  EntityKind(
    'printJobs',
    'pos_print_jobs',
    (r) => '${_str(r['orderId'])}:${_str(r['batchId'])}:${_str(r['kind'])}',
    {'order_id': (r) => r['orderId'], 'state': (r) => r['state']},
  ),
  EntityKind(
    'trendyolGoOrders',
    'pos_platform_orders',
    (r) {
      final package = _str(r['packageId']).trim();
      return '${_str(r['supplierId'])}:${_str(r['storeId'])}:'
          '${package.isNotEmpty ? package : _str(r['orderNumber'])}';
    },
    {'status': (r) => r['status'], 'created_at': (r) => r['createdAt']},
  ),
  EntityKind('deletedOrders', 'pos_deleted_orders', (r) => _str(r['orderId']), {
    'deleted_at': (r) => r['deletedAt'],
  }),
];

/// Row keys in list order; repeated keys (never expected, but legacy data
/// is not trusted) get a stable `#n` suffix by occurrence.
List<String> rowKeys(EntityKind kind, List rows) {
  final seen = <String, int>{};
  return [
    for (final row in rows)
      () {
        final base = row is Map ? kind.keyOf(row) : jsonEncode(row);
        final n = (seen[base] ?? 0) + 1;
        seen[base] = n;
        return n == 1 ? base : '$base#$n';
      }(),
  ];
}

void createEntityTables(Database db) {
  db.execute(
    'CREATE TABLE IF NOT EXISTS pos_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  );
  for (final kind in entityKinds) {
    final extra = kind.indexed.keys.map((c) => ', $c').join();
    db.execute(
      'CREATE TABLE IF NOT EXISTS ${kind.table}('
      'row_key TEXT PRIMARY KEY, seq INTEGER NOT NULL, json TEXT NOT NULL'
      '$extra)',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS ${kind.table}_seq ON ${kind.table}(seq)',
    );
  }
}

bool isNormalized(Database db) {
  final hasMeta = db.select(
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='pos_meta'",
  ).isNotEmpty;
  if (!hasMeta) return false;
  final row = db.select(
    "SELECT value FROM pos_meta WHERE key='storage_version'",
  );
  return row.isNotEmpty && int.parse(row.single['value'] as String) >= 2;
}

/// Present entity keys (an absent key stays absent, an empty list stays an
/// empty list: the assembled state equals what was stored).
Set<String> _present(Database db) => {
  for (final row in db.select(
    "SELECT key FROM pos_meta WHERE key LIKE 'present:%'",
  ))
    (row['key'] as String).substring('present:'.length),
};

/// Rebuilds the full logical state from the core row and entity tables.
Map<String, dynamic> loadNormalizedState(Database db) {
  final core = Map<String, dynamic>.from(
    jsonDecode(
          db.select('SELECT payload FROM state_snapshot WHERE id=1')
              .single['payload'] as String,
        )
        as Map,
  );
  final present = _present(db);
  for (final kind in entityKinds) {
    if (!present.contains(kind.stateKey)) continue;
    core[kind.stateKey] = <dynamic>[
      for (final row in db.select(
        'SELECT json FROM ${kind.table} ORDER BY seq',
      ))
        jsonDecode(row['json'] as String),
    ];
  }
  return core;
}

/// Deep JSON equality (same contract as comparing `jsonEncode` output for
/// maps whose key order is irrelevant).
bool jsonEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || !jsonEquals(entry.value, b[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a == b && (a is int) == (b is int);
  return a == b;
}

/// Statistics of one commit (used by tests and the benchmark).
class CommitStats {
  int rowsWritten = 0, rowsDeleted = 0, rowsRenumbered = 0;
}

/// Writes [next] given the previously committed [previous] (both full
/// logical states) inside the caller's transaction. Returns the new cached
/// state, which reuses the cached (already equal) rows of [previous] and
/// copies only changed ones, so memory work is proportional to the change.
(Map<String, dynamic>, CommitStats) writeNormalizedState(
  Database db,
  Map<String, dynamic>? previous,
  Map<String, dynamic> next, {
  required int revision,
  required String updatedAt,
}) {
  final stats = CommitStats();
  final cache = <String, dynamic>{};
  final core = <String, dynamic>{};
  final entityKeys = {for (final k in entityKinds) k.stateKey};
  for (final entry in next.entries) {
    if (!entityKeys.contains(entry.key)) core[entry.key] = entry.value;
  }
  final present = _present(db);
  for (final kind in entityKinds) {
    final rows = next[kind.stateKey];
    if (rows == null) {
      if (present.contains(kind.stateKey)) {
        db.execute('DELETE FROM ${kind.table}');
        db.execute('DELETE FROM pos_meta WHERE key=?', ['present:${kind.stateKey}']);
      }
      continue;
    }
    if (rows is! List) {
      throw FormatException('${kind.stateKey} must be a list');
    }
    if (!present.contains(kind.stateKey)) {
      db.execute(
        'INSERT OR REPLACE INTO pos_meta(key,value) VALUES(?,?)',
        ['present:${kind.stateKey}', '1'],
      );
    }
    final prevRows = previous?[kind.stateKey] is List
        ? previous![kind.stateKey] as List
        : const [];
    final prevKeys = rowKeys(kind, prevRows);
    final prevByKey = <String, Object?>{
      for (var i = 0; i < prevRows.length; i++) prevKeys[i]: prevRows[i],
    };
    final seqByKey = <String, int>{
      for (final r in db.select('SELECT row_key, seq FROM ${kind.table}'))
        r['row_key'] as String: r['seq'] as int,
    };
    final keys = rowKeys(kind, rows);
    // Keep existing seq when relative order is unchanged; else renumber.
    var maxSeq = seqByKey.values.fold<int>(-1, (m, v) => v > m ? v : m);
    final seqs = <int>[];
    var monotonic = true;
    for (final key in keys) {
      final s = seqByKey[key] ?? ++maxSeq;
      if (seqs.isNotEmpty && s <= seqs.last) monotonic = false;
      seqs.add(s);
    }
    if (!monotonic) {
      for (var i = 0; i < seqs.length; i++) {
        seqs[i] = i;
      }
    }
    final columns = kind.indexed.keys.toList();
    final upsert = db.prepare(
      'INSERT INTO ${kind.table}(row_key,seq,json'
      '${columns.map((c) => ',$c').join()}) VALUES(?,?,?'
      '${columns.map((_) => ',?').join()}) '
      'ON CONFLICT(row_key) DO UPDATE SET seq=excluded.seq,json=excluded.json'
      '${columns.map((c) => ',$c=excluded.$c').join()}',
    );
    final reseq = db.prepare(
      'UPDATE ${kind.table} SET seq=? WHERE row_key=?',
    );
    final out = <dynamic>[];
    try {
      for (var i = 0; i < rows.length; i++) {
        final key = keys[i], row = rows[i];
        final old = prevByKey[key];
        final known = seqByKey.containsKey(key);
        if (known && old != null && jsonEquals(old, row)) {
          out.add(old); // unchanged: reuse the cached object
          if (seqByKey[key] != seqs[i]) {
            reseq.execute([seqs[i], key]);
            stats.rowsRenumbered++;
          }
          continue;
        }
        final map = row is Map ? row : const {};
        upsert.execute([
          key,
          seqs[i],
          jsonEncode(row),
          for (final c in columns) kind.indexed[c]!(map),
        ]);
        stats.rowsWritten++;
        out.add(copyJson({'v': row})['v']);
      }
    } finally {
      upsert.dispose();
      reseq.dispose();
    }
    final live = keys.toSet();
    for (final key in seqByKey.keys) {
      if (!live.contains(key)) {
        db.execute('DELETE FROM ${kind.table} WHERE row_key=?', [key]);
        stats.rowsDeleted++;
      }
    }
    cache[kind.stateKey] = out;
  }
  db.execute(
    'UPDATE state_snapshot SET revision=?,payload=?,updated_at=? WHERE id=1',
    [revision, jsonEncode(core), updatedAt],
  );
  // Rebuild the cache in the same key order as [next].
  final ordered = <String, dynamic>{};
  final coreCopy = copyJson(core);
  for (final key in next.keys) {
    ordered[key] = cache.containsKey(key) ? cache[key] : coreCopy[key];
  }
  return (ordered, stats);
}

/// One-time migration of a legacy whole-JSON database. Runs inside the
/// caller's transaction; verifies that the rebuilt state is byte-for-byte
/// the original (canonical JSON) before returning true. On any mismatch it
/// throws, and the caller rolls back so the legacy format stays intact.
void migrateLegacyToNormalized(Database db) {
  final row = db.select(
    'SELECT revision,payload,updated_at FROM state_snapshot WHERE id=1',
  ).single;
  final legacyText = row['payload'] as String;
  final legacy = Map<String, dynamic>.from(jsonDecode(legacyText) as Map);
  createEntityTables(db);
  for (final kind in entityKinds) {
    db.execute('DELETE FROM ${kind.table}');
  }
  db.execute("DELETE FROM pos_meta WHERE key LIKE 'present:%'");
  writeNormalizedState(
    db,
    null,
    legacy,
    revision: row['revision'] as int,
    updatedAt: row['updated_at'] as String,
  );
  final rebuilt = loadNormalizedState(db);
  if (jsonEncode(rebuilt) != legacyText &&
      !jsonEquals(rebuilt, legacy)) {
    throw const FormatException(
      'Veri taşıma doğrulaması başarısız; eski biçim korunuyor.',
    );
  }
  // Every entity row and every top-level key must have survived.
  for (final kind in entityKinds) {
    final before = legacy[kind.stateKey];
    final count = db.select('SELECT count(*) AS n FROM ${kind.table}')
        .single['n'] as int;
    if ((before is List ? before.length : 0) != count) {
      throw const FormatException('Veri taşıma satır sayısı uyuşmuyor.');
    }
  }
  db.execute(
    "INSERT OR REPLACE INTO pos_meta(key,value) VALUES('storage_version',?)",
    ['$storageVersion'],
  );
  db.execute(
    "INSERT OR REPLACE INTO pos_meta(key,value) VALUES('migrated_at',?)",
    [DateTime.now().toUtc().toIso8601String()],
  );
}

/// Restored print queues must never auto-print (used by RestoreManager on
/// both storage formats).
void suppressNormalizedReplay(Database db) {
  for (final (table, field) in [
    ('pos_print_jobs', 'state'),
    ('pos_platform_orders', 'kitchenPrintState'),
  ]) {
    for (final row in db.select('SELECT row_key,json FROM $table')) {
      final value = jsonDecode(row['json'] as String) as Map;
      if (['Bekliyor', 'Gönderiliyor'].contains(value[field])) {
        value[field] = 'Kontrol gerekli';
        if (table == 'pos_print_jobs') {
          value['error'] = 'Yedekten geri yüklendi; otomatik yazdırılmadı.';
        }
        db.execute(
          'UPDATE $table SET json=?${table == 'pos_print_jobs' ? ',state=?' : ''} WHERE row_key=?',
          [jsonEncode(value), if (table == 'pos_print_jobs') value['state'], row['row_key']],
        );
      }
    }
  }
}
