/// Builds the first-sync snapshot from one POS revision with the SAME code
/// path as incremental sync: every syncable entity is treated as an upsert
/// from an empty state, projected by the outbox allowlist and encoded by the
/// typed cloud serializers (finance → catalog → order → receipt → platform
/// → ledger, the production transport order). The cloud therefore receives
/// exactly what it would have received had sync been on from day one.
///
/// Read projections without an outbox event (`workforceSummaries`,
/// `qrMenuState`) are added from their own Windows serializers. There is no
/// Windows producer for `dailyReports` or `notifications` yet, so they are
/// not part of the snapshot (they keep their current local behaviour).
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'cloud_catalog_serializer.dart';
import 'cloud_finance_serializer.dart';
import 'cloud_order_serializer.dart';
import 'cloud_payment_ledger_serializer.dart';
import 'cloud_platform_serializer.dart';
import 'cloud_qr_menu_bridge.dart';
import 'cloud_receipt_serializer.dart';
import 'cloud_workforce_summary.dart';
import 'initial_sync.dart';
import 'sync_outbox.dart';
import 'sync_worker.dart';

class SnapshotBuild {
  const SnapshotBuild(this.categories, this.skipped, this.rejected);
  final List<SnapshotCategory> categories;

  /// Outbox entity types that have no typed cloud projection yet, with
  /// counts (e.g. local-only settings). Shown to the owner, never sent.
  final Map<String, int> skipped;

  /// Records the typed serializers refused (type → entity id → reason),
  /// e.g. a legacy platform order without supplier/store/package ids. The
  /// same records would also fail incremental sync; the owner must see
  /// them before starting, nothing is dropped silently.
  final Map<String, Map<String, String>> rejected;

  int get eventCount => categories.fold(0, (n, c) => n + c.events.length);
}

class _Discard implements SyncTransport {
  const _Discard();
  @override
  Future<IngestResult> ingest(SyncTransaction tx) => throw StateError('encode only');
}

/// The production encoder chain, used here only to encode (never sends).
SyncTransaction encodeTyped(SyncTransaction tx, CloudIdentityMap ids) {
  const sink = _Discard();
  var out = TypedFinanceTransport(ids, sink).encode(tx);
  out = TypedCatalogTransport(ids, sink).encode(out);
  out = TypedOrderTransport(ids, sink).encode(out);
  out = TypedReceiptTransport(ids, sink).encode(out);
  out = TypedPlatformTransport(ids, sink).encode(out);
  return TypedPaymentLedgerTransport(ids, sink).encode(out);
}

/// [state] must be the data of [revision] (see `PosStore.read`). Call
/// `PosStore.prepareCloudOrderIdentities` first so every order, receipt and
/// payment has its persistent cloud identity.
SnapshotBuild buildSnapshotCategories(Database db, {
  required Map<String, dynamic> state,
  required int revision,
  required String sourceUpdatedAt,
  required String authorityEpoch,
  DateTime? now,
  String? qrLink,
}) {
  createSyncTables(db);
  final changes = collectOutboxChanges(<String, dynamic>{}, state);
  final events = <SyncEvent>[];
  for (final change in changes) {
    final projected = outboxPayload(db, change, sourceUpdatedAt);
    if (projected == null) continue;
    final (op, payload) = projected;
    final body = canonicalJson(payload);
    events.add(SyncEvent(
      seq: events.length + 1,
      ordinal: events.length,
      eventId: '$authorityEpoch:$revision:${change.entityType}:${change.entityId}',
      entityType: change.entityType,
      entityId: change.entityId,
      op: op,
      payloadJson: body,
      payloadSha256: sha256Hex(body),
      createdAt: sourceUpdatedAt,
    ));
  }
  final ids = CloudIdentityMap(db);
  final byType = <String, List<Map<String, Object?>>>{};
  final skipped = <String, int>{};
  final rejected = <String, Map<String, String>>{};
  // One event at a time, so one bad record is reported, not fatal.
  for (final raw in events) {
    final SyncEvent e;
    try {
      e = encodeTyped(SyncTransaction(authorityEpoch: authorityEpoch,
          sourceRevision: revision, events: [raw]), ids).events.single;
    } on FormatException catch (err) {
      (rejected[raw.entityType] ??= {})[raw.entityId] = err.message;
      continue;
    } on SyncRejectedException catch (err) {
      (rejected[raw.entityType] ??= {})[raw.entityId] = err.code;
      continue;
    }
    if (!snapshotEntityTypes.contains(e.entityType) || e.op != 'upsert') {
      skipped.update(e.entityType, (n) => n + 1, ifAbsent: () => 1);
      continue;
    }
    byType.putIfAbsent(e.entityType, () => [])
        .add(snapshotEvent(e.entityType, e.entityId, jsonDecode(e.payloadJson)));
  }
  final at = (now ?? DateTime.now()).toUtc();
  byType['workforceSummaries'] = [
    snapshotEvent('workforceSummaries', 'core', serializeWorkforceSummaries(state, now: at)),
  ];
  byType['qrMenuState'] = [
    snapshotEvent('qrMenuState', 'core', serializeQrMenuCloudState(state, link: qrLink, now: at)),
  ];
  final order = snapshotEntityTypes.toList();
  return SnapshotBuild([
    for (final type in order)
      if (byType[type] case final list? when list.isNotEmpty) SnapshotCategory(type, list),
  ], skipped, rejected);
}
