// Windows first full sync against an in-memory server that follows the
// PR #46 RPC rules (begin pins the manifest, staged uploads with hash and
// count checks, activation recomputes the manifest). The canonical JSON
// parity with real Postgres runs when NOHUT_PG_HOST points at a server.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/initial_sync.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/sync_outbox.dart';
import 'package:nohut_falafel_desktop/sync_worker.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/synthetic_pos.dart';

class FakeAgentServer implements InitialSyncTransport {
  final migrations = <String, Map<String, Object?>>{};
  final batches = <String, Map<String, Map<String, Object?>>>{};
  final calls = <String>[];
  int failUploadAfter = -1;
  bool offline = false;

  void _net(String op) {
    calls.add(op);
    if (offline) throw const InitialSyncNetworkException('bağlantı yok');
  }

  @override
  Future<Map<String, Object?>> begin({required String migrationId, required int snapshotRevision,
      required int snapshotSeq, required String manifestSha256, required bool backupVerified}) async {
    _net('begin');
    if (!backupVerified) throw const InitialSyncException('pre_sync_backup_required', 'yedek');
    final prior = migrations[migrationId];
    if (prior != null) {
      return {'status': prior['manifest_sha256'] == manifestSha256 ? 'duplicate' : 'conflict'};
    }
    migrations[migrationId] = {'status': 'uploading', 'manifest_sha256': manifestSha256,
      'snapshot_seq': snapshotSeq, 'snapshot_revision': snapshotRevision};
    batches[migrationId] = {};
    return {'status': 'accepted'};
  }

  @override
  Future<Map<String, Object?>> uploadBatch({required String migrationId, required String batchId,
      required String category, required int itemCount, required String bodySha256,
      required String eventsJson}) async {
    _net('upload');
    if (failUploadAfter == 0) {
      failUploadAfter = -1;
      throw const InitialSyncNetworkException('kesildi');
    }
    if (failUploadAfter > 0) failUploadAfter--;
    final events = jsonDecode(eventsJson) as List;
    if (events.length != itemCount || events.length > 500) {
      throw const InitialSyncException('22023', 'count');
    }
    // The server re-canonicalizes what it received.
    if (sha256Hex(postgresCanonicalJson(events)) != bodySha256) {
      throw const InitialSyncException('22023', 'hash');
    }
    final m = migrations[migrationId]!;
    if (m['status'] != 'uploading') throw const InitialSyncException('42501', 'closed');
    final prior = batches[migrationId]![batchId];
    if (prior != null) {
      return {'status': prior['body_sha256'] == bodySha256 ? 'duplicate' : 'conflict'};
    }
    batches[migrationId]![batchId] = {'batch_id': batchId, 'category': category,
      'item_count': itemCount, 'body_sha256': bodySha256, 'events': events};
    return {'status': 'accepted'};
  }

  String _manifest(String id) {
    final lines = batches[id]!.values.toList()
      ..sort((a, b) => '${a['batch_id']}'.compareTo('${b['batch_id']}'));
    return sha256Hex(lines.map((b) =>
        '${b['category']}:${b['batch_id']}:${b['item_count']}:${b['body_sha256']}').join('\n'));
  }

  @override
  Future<Map<String, Object?>> activate({required String migrationId, required int expectedBatches,
      required String manifestSha256}) async {
    _net('activate');
    final m = migrations[migrationId]!;
    if (m['status'] == 'active') return {'status': 'duplicate'};
    if (batches[migrationId]!.length != expectedBatches) {
      throw const InitialSyncException('22023', 'incomplete_batches');
    }
    if (_manifest(migrationId) != m['manifest_sha256'] || manifestSha256 != m['manifest_sha256']) {
      throw const InitialSyncException('22023', 'manifest');
    }
    m['status'] = 'active';
    return {'status': 'accepted'};
  }

  @override
  Future<Map<String, Object?>> abort({required String migrationId, String? reason}) async {
    _net('abort');
    migrations[migrationId]!['status'] = 'safely_aborted';
    batches[migrationId]!.clear();
    return {'status': 'safely_aborted'};
  }

  @override
  Future<Map<String, Object?>> status({String? migrationId}) async {
    _net('status');
    final m = migrations[migrationId];
    if (m == null) return {'exists': false};
    return {'exists': true, 'migration_id': migrationId, ...m,
      'batches': [for (final b in batches[migrationId]!.values)
        {for (final k in ['batch_id', 'category', 'item_count', 'body_sha256']) k: b[k]}]};
  }
}

List<SnapshotCategory> categoriesFrom(Map<String, dynamic> state) => [
  SnapshotCategory('employees', [
    snapshotEvent('employees', 'core', [
      for (final e in (state['employees'] as List).cast<Map>())
        {'id': e['id'], 'name': e['name'], 'active': e['active'] == true},
    ]),
  ]),
  SnapshotCategory('orders', [
    for (final o in (state['orders'] as List).cast<Map>())
      snapshotEvent('typed_order', '${o['id']}', {'local_order_id': '${o['id']}',
        'status': '${o['status'] ?? ''}', 'note': 'Şube "1"\n'}),
  ]),
];

void main() {
  group('canonical JSON', () {
    test('matches the text Postgres produced for the same value', () {
      // Expected string captured from canonical_command_json on Postgres 16.
      final v = jsonDecode('{"b":1,"a":[true,null,"x\\"y\\\\z\\n\\t\\u0001/é😀"],'
          '"é":{"Z":-5,"_":0},"A":"\\u007f"}');
      expect(postgresCanonicalJson(v),
          '{"A":"\u007f","a":[true,null,"x\\"y\\\\z\\n\\t\\u0001/é😀"],"b":1,"é":{"Z":-5,"_":0}}');
    });

    test('refuses what the server refuses', () {
      for (final bad in <Object?>[
        1.5, 2.0, 9007199254740992, {'k': 'a\u0000b'}, {'😀': 1}, 'x\uD800',
      ]) {
        expect(() => postgresCanonicalJson(bad), throwsA(isA<CanonicalJsonException>()),
            reason: '$bad');
      }
      expect(postgresCanonicalJson(-9007199254740991), '-9007199254740991');
    });
  });

  group('batch plan', () {
    test('500 events per batch, stable ids, manifest over batch-id order', () {
      final events = [for (var i = 0; i < 1203; i++) snapshotEvent('typed_order', '$i', {'n': i})];
      final a = planBatches('m-1', [SnapshotCategory('orders', events)]);
      final b = planBatches('m-1', [SnapshotCategory('orders', events)]);
      expect(a.map((x) => x.itemCount), [500, 500, 203]);
      expect(a.map((x) => x.batchId), b.map((x) => x.batchId));
      expect(a.map((x) => x.batchId).toSet(), hasLength(3));
      expect(manifestSha256(a), manifestSha256(a.reversed));
      expect(manifestSha256(const []), sha256Hex(''));
      for (final x in a) {
        expect(sha256Hex(postgresCanonicalJson(jsonDecode(x.eventsJson))), x.bodySha256);
        expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
            .hasMatch(x.batchId), isTrue);
      }
    });

    test('splits by the jsonb text size, refuses one oversized event', () {
      final big = 'ş' * 1000; // 2000 bytes each
      final events = [for (var i = 0; i < 30; i++) snapshotEvent('notifications', '$i', big)];
      final plan = planBatches('m', [SnapshotCategory('n', events)], maxBytes: 10000);
      expect(plan.length, greaterThan(1));
      for (final p in plan) {
        expect(utf8.encode(p.eventsJson).length, lessThanOrEqualTo(10000));
      }
      expect(plan.fold<int>(0, (s, p) => s + p.itemCount), 30);
      expect(() => planBatches('m', [SnapshotCategory('n', events)], maxBytes: 1500),
          throwsA(isA<CanonicalJsonException>()));
      expect(() => snapshotEvent('orders', '1', {}), throwsA(isA<CanonicalJsonException>()));
    });
  });

  group('runner', () {
    late Directory dir;
    late PosStore store;
    late Database db;
    late FakeAgentServer server;
    late InitialSyncRunner runner;
    const backup = VerifiedBackup(backupId: 'b-1', revision: 1 << 30);

    InitialSyncPlan plan() {
      final snap = store.read();
      return planInitialSync(db, snapshotRevision: snap.revision,
          categories: categoriesFrom(snap.data));
    }

    setUp(() {
      dir = Directory.systemTemp.createTempSync('nohut-initial-sync');
      store = PosStore(databaseFile: '${dir.path}/db');
      store.replace(buildSyntheticState(40), store.read().revision);
      db = sqlite3.open('${dir.path}/db');
      server = FakeAgentServer();
      runner = InitialSyncRunner(db, server, clock: () => DateTime.utc(2026, 11, 28, 9));
    });
    tearDown(() {
      db.dispose();
      store.dispose();
      dir.deleteSync(recursive: true);
    });

    test('backup gate, upload, activate; increments wait for the snapshot', () async {
      final p = plan();
      expect(outboxEnabled(db), isTrue);
      expect(p.batchCount, 2);

      final noBackup = await runner.run();
      expect(noBackup.outcome, InitialSyncOutcome.stopped);
      expect(server.calls, ['status'], reason: 'begin never sent without a verified backup');

      // A change after the snapshot is an increment, held until activation.
      final s = store.read().data;
      ((s['orders'] as List).first as Map)['serviceStatus'] = 'Hazır';
      store.replace(s, store.read().revision);
      final worker = SyncWorker(db, _NoIngest());
      expect(await worker.flush(), 0);

      final r = await runner.run(backup: backup);
      expect(r.outcome, InitialSyncOutcome.active);
      expect(server.migrations[p.migrationId]!['status'], 'active');
      expect(currentInitialSyncPlan(db)!.status, 'active');
      expect(initialSyncHoldsIncremental(db), isFalse);
      final pending = pendingOutbox(db);
      expect(pending, isNotEmpty);
      expect(pending.every((e) => (e['seq'] as int) > p.snapshotSeq), isTrue);
      expect(await runner.run(), isA<InitialSyncProgress>()
          .having((x) => x.outcome, 'outcome', InitialSyncOutcome.active));
    });

    test('a cut connection resumes and uploads only the missing batches', () async {
      final events = [for (var i = 0; i < 1100; i++) snapshotEvent('typed_order', '$i', {'n': i})];
      final snap = store.read();
      final p = planInitialSync(db, snapshotRevision: snap.revision,
          categories: [SnapshotCategory('orders', events)]);
      server.failUploadAfter = 1;
      final first = await runner.run(backup: backup);
      expect(first.outcome, InitialSyncOutcome.retryLater);
      expect(server.batches[p.migrationId], hasLength(1));
      expect(currentInitialSyncPlan(db)!.lastError, contains('network'));

      server.calls.clear();
      final second = await runner.run();
      expect(second.outcome, InitialSyncOutcome.active);
      expect(server.calls.where((c) => c == 'upload'), hasLength(2));
      expect(server.calls, isNot(contains('begin')));
    });

    test('stale snapshot, double plan and server abort are refused', () async {
      final snap = store.read();
      store.replace(snap.data, snap.revision);
      expect(() => planInitialSync(db, snapshotRevision: snap.revision,
          categories: categoriesFrom(snap.data)),
          throwsA(isA<InitialSyncException>().having((e) => e.code, 'code', 'stale_snapshot')));
      final p = plan();
      expect(() => plan(), throwsA(isA<InitialSyncException>()
          .having((e) => e.code, 'code', 'already_planned')));

      server.offline = true;
      expect((await runner.run(backup: backup)).outcome, InitialSyncOutcome.retryLater);
      server.offline = false;
      await server.begin(migrationId: p.migrationId, snapshotRevision: 0, snapshotSeq: 0,
          manifestSha256: p.manifestSha256, backupVerified: true);
      server.migrations[p.migrationId]!['status'] = 'safely_aborted';
      final r = await runner.run();
      expect(r.outcome, InitialSyncOutcome.stopped);
      expect(currentInitialSyncPlan(db)!.status, 'aborted');
      expect(initialSyncHoldsIncremental(db), isTrue, reason: 'no active snapshot yet');
    });

    test('a different batch already in the cloud stops the run', () async {
      final p = plan();
      await server.begin(migrationId: p.migrationId, snapshotRevision: 0, snapshotSeq: 0,
          manifestSha256: p.manifestSha256, backupVerified: true);
      final first = plannedBatches(db, p.migrationId).first;
      server.batches[p.migrationId]![first.batchId] = {'batch_id': first.batchId,
        'category': first.category, 'item_count': first.itemCount, 'body_sha256': '0' * 64};
      final r = await runner.run();
      expect(r.outcome, InitialSyncOutcome.stopped);
      expect(currentInitialSyncPlan(db)!.lastError, 'batch_conflict');
      expect(server.calls, isNot(contains('activate')));
    });

    test('owner abort clears the cloud staging and allows a new plan', () async {
      final p = plan();
      server.failUploadAfter = 0;
      await runner.run(backup: backup);
      await runner.abort();
      expect(server.migrations[p.migrationId]!['status'], 'safely_aborted');
      expect(currentInitialSyncPlan(db)!.status, 'aborted');
      expect(plan().migrationId, isNot(p.migrationId));
    });
  });

  test('parity with Postgres canonical_command_json and jsonb size',
      skip: Platform.environment['NOHUT_PG_HOST'] == null
          ? 'set NOHUT_PG_HOST to run against Postgres' : false, () async {
    final host = Platform.environment['NOHUT_PG_HOST']!;
    Future<String> sql(String q) async {
      final r = await Process.run('psql', ['-h', host, '-U', 'postgres', '-tAq', '-v',
        'ON_ERROR_STOP=1', '-c', q]);
      if (r.exitCode != 0) fail('${r.stderr}');
      return (r.stdout as String).replaceAll(RegExp(r'\n$'), '');
    }
    final setup = await Process.run('psql', ['-h', host, '-U', 'postgres', '-q', '-v',
      'ON_ERROR_STOP=1', '-f', 'test/fixtures/canonical_command_json.sql']);
    expect(setup.exitCode, 0, reason: '${setup.stderr}');
    final values = <Object?>[
      {'z': 1, 'Z': 2, 'é': 3, 'e': 4, '_': 5, ' ': 6, 'ab': 7, 'a': 8, 'ı': 9, 'İ': 10},
      ['tab\t', 'ctl\u0002\u001f', 'quote"\\', '/slash', 'ş ğ ü ö ç', '😀 emoji', '\u007f\u0080', ''],
      {'n': [0, -1, 9007199254740991, -9007199254740991], 'b': [true, false, null], 'e': {}, 'l': []},
      [for (final c in categoriesFrom(buildSyntheticState(5))) for (final e in c.events) e],
    ];
    for (final v in values) {
      final mine = canonicalWithSize(v);
      final lit = jsonEncode(v).replaceAll("'", "''");
      expect(await sql("select nohut_private.canonical_command_json('$lit'::jsonb)"), mine.text);
      expect(int.parse(await sql("select octet_length('$lit'::jsonb::text)")), mine.jsonbTextBytes);
    }
    final batches = planBatches('11111111-1111-4111-8111-111111111111',
        categoriesFrom(buildSyntheticState(5)));
    final rows = batches.map((b) => "('${b.category}','${b.batchId}'::uuid,${b.itemCount},'${b.bodySha256}')").join(',');
    expect(await sql("select encode(sha256(convert_to(string_agg(c||':'||id::text||':'||n::text||':'||h, "
        "E'\\n' order by id::text),'UTF8')),'hex') from (values $rows) v(c,id,n,h)"),
        manifestSha256(batches));
  });
}

class _NoIngest implements SyncTransport {
  @override
  Future<IngestResult> ingest(SyncTransaction tx) => throw StateError('must not send');
}
