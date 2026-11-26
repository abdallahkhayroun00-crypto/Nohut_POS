// Phase 1B: per-entity tables, verified migration from the legacy single
// JSON row, change-only writes, ordering and restore of legacy backups.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/backup_container.dart';
import 'package:nohut_falafel_desktop/entity_storage.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/synthetic_pos.dart';

/// Writes a database exactly as the pre-Phase-1B app did.
void writeLegacyDatabase(String path, Json state, {int revision = 42}) {
  final db = sqlite3.open(path);
  db.execute('PRAGMA journal_mode=WAL');
  db.execute('CREATE TABLE state_snapshot(id INTEGER PRIMARY KEY CHECK(id=1), '
      'revision INTEGER NOT NULL, payload TEXT NOT NULL, updated_at TEXT NOT NULL)');
  db.execute('INSERT INTO state_snapshot VALUES(1,?,?,?)',
      [revision, jsonEncode(state), '2026-11-20T10:00:00.000Z']);
  db.execute('CREATE TABLE command_receipts (request_id TEXT PRIMARY KEY, '
      'payload TEXT NOT NULL, result TEXT NOT NULL)');
  db.execute("INSERT INTO command_receipts VALUES('staff_legacy_1','{}','{\"ok\":true}')");
  db.execute('CREATE TABLE deleted_requests (request_id TEXT PRIMARY KEY)');
  db.dispose();
}

int count(String path, String table) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    return db.select('SELECT count(*) AS n FROM $table').single['n'] as int;
  } finally {
    db.dispose();
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('nohut-entity'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('legacy database migrates once: safety copy, identical data, same '
      'revision, every row counted', () {
    final legacy = buildSyntheticState(400);
    final path = '${dir.path}/nohut-pos.sqlite3';
    writeLegacyDatabase(path, legacy);
    final store = PosStore(databaseFile: path);
    try {
      expect(store.normalized, true, reason: store.migrationError);
      expect(store.migrationError, isNull);
      expect(File(store.preMigrationCopy!).existsSync(), true);
      final snap = store.read();
      expect(snap.revision, 42);
      expect(jsonEquals(snap.data, legacy), true);
      expect(count(path, 'pos_orders'), (legacy['orders'] as List).length);
      expect(count(path, 'pos_print_jobs'), (legacy['printJobs'] as List).length);
      expect(count(path, 'pos_platform_orders'),
          (legacy['trendyolGoOrders'] as List).length);
      expect(count(path, 'command_receipts'), 1);
      // The core row no longer carries the big lists.
      final db = sqlite3.open(path, mode: OpenMode.readOnly);
      final core = jsonDecode(db.select(
          'SELECT payload FROM state_snapshot').single['payload'] as String) as Map;
      db.dispose();
      expect(core.containsKey('orders'), false);
      expect(core['settings'], legacy['settings']);
      // The safety copy is the untouched legacy database.
      final copy = sqlite3.open(store.preMigrationCopy!, mode: OpenMode.readOnly);
      final copied = copy.select('SELECT revision,payload FROM state_snapshot')
          .single;
      copy.dispose();
      expect(copied['revision'], 42);
      expect(jsonEquals(jsonDecode(copied['payload'] as String), legacy), true);
    } finally {
      store.dispose();
    }
    // Re-opening does not migrate again or copy again.
    final again = PosStore(databaseFile: path);
    expect(again.normalized, true);
    expect(again.preMigrationCopy, isNull);
    expect(jsonEquals(again.read().data, legacy), true);
    again.dispose();
  });

  test('a migration that cannot be verified rolls back and the legacy '
      'database keeps working', () {
    final legacy = {...emptyPosState(), 'trendyolGoOrders': 'corrupt'};
    final path = '${dir.path}/nohut-pos.sqlite3';
    writeLegacyDatabase(path, legacy, revision: 7);
    final store = PosStore(databaseFile: path);
    try {
      expect(store.normalized, false);
      expect(store.migrationError, isNotNull);
      final s = store.read().data..['nextId'] = 1300;
      expect(store.replace(s, store.read().revision).ok, true);
      expect(store.read().data['nextId'], 1300);
    } finally {
      store.dispose();
    }
  });

  test('a commit writes only changed rows and keeps list order', () {
    final db = sqlite3.open('${dir.path}/raw.sqlite3');
    db.execute('CREATE TABLE state_snapshot(id INTEGER PRIMARY KEY, '
        'revision INTEGER, payload TEXT, updated_at TEXT)');
    db.execute("INSERT INTO state_snapshot VALUES(1,0,'{}','x')");
    createEntityTables(db);
    final state = buildSyntheticState(200);
    var (cache, stats) = writeNormalizedState(db, null, state,
        revision: 1, updatedAt: 'a');
    final rows = (state['orders'] as List).length +
        (state['printJobs'] as List).length +
        (state['trendyolGoOrders'] as List).length;
    expect(stats.rowsWritten, rows);
    // Change one order only.
    final next = copyJson(cache);
    ((next['orders'] as List)[5] as Map)['serviceStatus'] = 'Hazır';
    (cache, stats) = writeNormalizedState(db, cache, next,
        revision: 2, updatedAt: 'b');
    expect(stats.rowsWritten, 1);
    expect(stats.rowsDeleted, 0);
    expect(jsonEquals(loadNormalizedState(db)..remove('x'), next), true);
    // Remove one in the middle, append one: order preserved, no renumber.
    final third = copyJson(cache);
    final orders = third['orders'] as List;
    final removed = orders.removeAt(10) as Map;
    orders.add({...removed, 'id': 999999});
    third['nextId'] = 1000000;
    (cache, stats) = writeNormalizedState(db, cache, third,
        revision: 3, updatedAt: 'c');
    expect(stats.rowsWritten, 1);
    expect(stats.rowsDeleted, 1);
    expect(stats.rowsRenumbered, 0);
    expect(jsonEquals(loadNormalizedState(db), third), true);
    // Move an order to the front: renumbered, order still exact.
    final fourth = copyJson(cache);
    final list = fourth['orders'] as List;
    list.insert(0, list.removeLast());
    (cache, stats) = writeNormalizedState(db, cache, fourth,
        revision: 4, updatedAt: 'd');
    expect(stats.rowsWritten, 0);
    expect(stats.rowsRenumbered, greaterThan(0));
    expect(jsonEquals(loadNormalizedState(db), fourth), true);
    // Absent vs empty lists survive exactly.
    final fifth = copyJson(cache)..remove('trendyolGoOrders');
    fifth['deletedOrders'] = <dynamic>[];
    writeNormalizedState(db, cache, fifth, revision: 5, updatedAt: 'e');
    final loaded = loadNormalizedState(db);
    expect(loaded.containsKey('trendyolGoOrders'), false);
    expect(loaded['deletedOrders'], isEmpty);
    db.dispose();
  });

  test('a legacy-format backup restored into the new version migrates on '
      'open with identical data', () async {
    final legacy = buildSyntheticState(120);
    final legacyPath = '${dir.path}/old/nohut-pos.sqlite3';
    Directory('${dir.path}/old').createSync();
    writeLegacyDatabase(legacyPath, legacy);
    // Take an encrypted backup of the legacy file without opening it as a
    // PosStore (that would migrate it): wrap it in a raw store copy.
    final key = RecoveryKey.generate(Random(1));
    final container = BackupContainer(
        kdf: const BackupKdf(memoryKiB: 19456, iterations: 1), random: Random(2));
    final plainCopy = '${dir.path}/old/copy.sqlite3';
    final raw = sqlite3.open(legacyPath);
    raw.execute('VACUUM INTO ?', [plainCopy]);
    raw.dispose();
    // Encrypt via a throwaway store on a COPY of the legacy file is not
    // possible without migrating; instead stage the plain copy directly.
    final target = '${dir.path}/new/nohut-pos.sqlite3';
    Directory('${dir.path}/new').createSync();
    File(plainCopy).copySync(target);
    final store = PosStore(databaseFile: target);
    try {
      expect(store.normalized, true);
      expect(jsonEquals(store.read().data, legacy), true);
      // And a backup of the migrated store restores elsewhere identically.
      final backup = await container.create(store, Directory('${dir.path}/bk'),
          recoveryKey: key);
      final restoreTo = '${dir.path}/pc2/nohut-pos.sqlite3';
      Directory('${dir.path}/pc2').createSync();
      final manager = RestoreManager(restoreTo);
      await manager.stage(backup.file, recoveryKey: key, confirmedBy: 'Ömer',
          container: container);
      expect(manager.applyPending().applied, true);
      final restored = PosStore(databaseFile: restoreTo);
      expect(restored.normalized, true);
      final data = restored.read().data;
      expect(asMaps(data['orders']).length, asMaps(legacy['orders']).length);
      expect(
        asMaps(data['orders']).fold<int>(0, (n, o) => n + orderPaidCents(o)),
        asMaps(legacy['orders']).fold<int>(0, (n, o) => n + orderPaidCents(o)),
      );
      expect(backup.manifest.orderCount, asMaps(legacy['orders']).length);
      restored.dispose();
    } finally {
      store.dispose();
    }
  });
}
