// Phase 2 / PR-06 client: SyncWorker against an in-memory server that
// enforces the same rules as nohut_private.sync_transactions /
// sync_event_ids (#35): idempotent tx_id + hash, contiguous sequence.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/sync_outbox.dart';
import 'package:nohut_falafel_desktop/sync_worker.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/synthetic_pos.dart';

class FakeServer implements SyncTransport {
  final committed = <String, String>{}; // tx_id -> body_sha256
  final appliedEvents = <String>[]; // event ids, in order
  int lastSeq = 0;
  int calls = 0;
  bool loseNextAck = false, offline = false;

  @override
  Future<IngestResult> ingest(SyncTransaction tx) async {
    calls++;
    if (offline) throw const SyncNetworkException('bağlantı yok');
    final known = committed[tx.txId];
    if (known != null) {
      return known == tx.bodySha256
          ? IngestResult(IngestStatus.duplicate, ackedThroughSeq: lastSeq)
          : const IngestResult(IngestStatus.conflict, message: 'same tx, other body');
    }
    if (tx.firstSeq != lastSeq + 1) {
      return IngestResult(IngestStatus.gap,
          message: 'expected ${lastSeq + 1}, got ${tx.firstSeq}');
    }
    if (tx.lastSeq - tx.firstSeq + 1 != tx.events.length) {
      return const IngestResult(IngestStatus.gap, message: 'hole inside tx');
    }
    committed[tx.txId] = tx.bodySha256;
    appliedEvents.addAll(tx.events.map((e) => e.eventId));
    lastSeq = tx.lastSeq;
    if (loseNextAck) {
      loseNextAck = false;
      throw const SyncNetworkException('yanıt kayboldu'); // committed!
    }
    return IngestResult(IngestStatus.accepted, ackedThroughSeq: lastSeq);
  }
}

void main() {
  late Directory dir;
  late PosStore store;
  late Database db;
  late FakeServer server;
  late SyncWorker worker;
  late DateTime now;

  void change(int i) {
    final s = store.read().data;
    (s['orders'] as List).cast<Map>()[i]['serviceStatus'] = 'Hazır $i';
    store.replace(s, store.read().revision);
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nohut-worker');
    store = PosStore(databaseFile: '${dir.path}/db');
    store.replace(buildSyntheticState(30), store.read().revision);
    db = sqlite3.open('${dir.path}/db');
    enableOutbox(db);
    server = FakeServer();
    now = DateTime.utc(2026, 11, 27, 12);
    worker = SyncWorker(db, server, clock: () => now);
  });
  tearDown(() {
    worker.dispose();
    db.dispose();
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  test('commits are sent in order, one transaction per revision, then '
      'acknowledged', () async {
    for (var i = 0; i < 3; i++) {
      change(i);
    }
    final groups = groupPending(db);
    expect(groups, hasLength(3));
    expect(groups.map((g) => g.sourceRevision).toList(),
        [for (final g in groups) g.sourceRevision]..sort());
    expect(await worker.flush(), 3);
    expect(pendingOutbox(db), isEmpty);
    expect(server.appliedEvents, hasLength(3));
    expect(worker.status().pending, 0);
    expect(worker.status().lastSuccessAt, isNotNull);
  });

  test('a lost acknowledgement is retried and recognised as a duplicate — '
      'never applied twice', () async {
    change(0);
    server.loseNextAck = true;
    expect(await worker.flush(), 0);
    expect(pendingOutbox(db), hasLength(1), reason: 'not acked locally');
    expect(worker.status().lastError, contains('kayboldu'));
    now = now.add(const Duration(minutes: 1));
    expect(await worker.flush(), 1);
    expect(server.appliedEvents, hasLength(1));
    expect(pendingOutbox(db), isEmpty);
  });

  test('offline: exponential backoff, local data untouched, resumes later',
      () async {
    change(0);
    change(1);
    server.offline = true;
    expect(await worker.flush(), 0);
    expect(worker.backoff, const Duration(seconds: 2));
    expect(await worker.flush(), 0, reason: 'too early, no call');
    final callsBefore = server.calls;
    now = now.add(const Duration(seconds: 3));
    expect(await worker.flush(), 0);
    expect(server.calls, callsBefore + 1);
    expect(worker.backoff, const Duration(seconds: 4));
    server.offline = false;
    now = now.add(const Duration(minutes: 1));
    expect(await worker.flush(), 2);
    expect(worker.backoff, Duration.zero);
    expect(store.read().data['orders'], isNotEmpty);
  });

  test('same transaction id with a different body stops the worker (no '
      'skipping, no overwrite)', () async {
    change(0);
    final tx = groupPending(db).single;
    server.committed[tx.txId] = 'f' * 64; // server holds other content
    server.lastSeq = tx.lastSeq;
    expect(await worker.flush(), 0);
    expect(worker.status().stopped, true);
    expect(worker.status().lastError, startsWith('conflict'));
    expect(pendingOutbox(db), hasLength(1));
    // Automatic attempts stay stopped until the owner retries manually.
    change(1);
    expect(await worker.flush(), 0);
  });

  test('a sequence gap is refused by the server and stops the worker',
      () async {
    change(0);
    server.lastSeq = 99; // server expects 100
    expect(await worker.flush(), 0);
    expect(worker.status().stopped, true);
    expect(worker.status().lastError, startsWith('gap'));
  });

  test('transaction ids and hashes are deterministic across retries', () {
    change(0);
    final a = groupPending(db).single, b = groupPending(db).single;
    expect(a.txId, b.txId);
    expect(a.bodySha256, b.bodySha256);
    expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-a[0-9a-f]{3}-[0-9a-f]{12}$')
        .hasMatch(a.txId), true);
    final json = a.toJson();
    expect(json['event_count'], 1);
    expect(json['first_seq'], json['last_seq']);
    expect(asMaps(json['events']).single['payload'], isA<Map>());
  });
}
