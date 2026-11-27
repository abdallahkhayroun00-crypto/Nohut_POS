import 'dart:convert';

import 'package:crypto/crypto.dart' as hash;

import 'cloud_finance_serializer.dart';
import 'receipt_sync_history.dart' show printSourceKey;
import 'sync_outbox.dart';
import 'sync_worker.dart';

String _uuid(Object? value) {
  if (value is! String ||
      !RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(value))
    throw const FormatException('Print identity missing');
  return value;
}

String _stamp(Object? value) {
  if (value is! String ||
      DateTime.tryParse(value) == null ||
      !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(value))
    throw const FormatException('Print timestamp missing');
  return value;
}

String _status(Object? value) => switch (value) {
  'Bekliyor' => 'queued',
  'Gönderiliyor' => 'dispatching',
  'Kuyruğa gönderildi' => 'spooled',
  'Kontrol gerekli' => 'ambiguous',
  'İptal' => 'cancelled',
  'Atlandı' => 'skipped',
  _ => throw const FormatException('Unknown print state'),
};
int _attempts(Object? value) {
  if (value is! int || value < 0 || value > 9007199254740991)
    throw const FormatException('Invalid print attempts');
  return value;
}

Map<String, Object?> serializeReceipt(
  Map<String, dynamic> job,
  CloudIdentityMap ids,
  String stamp,
) {
  if (job['orderId'] is! int || job['batchId'] is! int)
    throw const FormatException('Invalid print source');
  final jobId = _uuid(job['syncId']),
      order = ids.id('order', job['orderId'] as int),
      snapshotId = ids.id('receipt', jobId);
  final frozen = job['syncReceipt'];
  if (frozen is! Map ||
      frozen['schemaVersion'] != 1 ||
      frozen['body'] is! String ||
      (frozen['body'] as String).length > 65536 ||
      frozen['privacy'] != 'customer_contact_redacted' ||
      !{'frozen_kitchen', 'payment_text'}.contains(frozen['sourceFormat']))
    throw const FormatException('Unsupported receipt snapshot');
  final kind = job['kind'] == 'paymentReceipt' ? 'payment' : 'kitchen';
  if ((kind == 'payment') != (frozen['sourceFormat'] == 'payment_text'))
    throw const FormatException('Receipt format mismatch');
  final definition = <String, Object?>{
    'schema_version': 1,
    'receipt_kind': kind,
    'source_format': frozen['sourceFormat'],
    'body': frozen['body'],
    'privacy': 'customer_contact_redacted',
  };
  final rows = <Map<String, Object?>>[];
  void add(String table, Map<String, Object?> data) =>
      rows.add({'table': table, 'data': data});
  add('receipt_snapshots', {
    'order_id': order,
    'snapshot_id': snapshotId,
    ...definition,
    'content_sha256': hash.sha256
        .convert(utf8.encode(canonicalJson(definition)))
        .toString(),
  });
  final history = job['syncPrintHistory'];
  if (history is! List || history.isEmpty)
    throw const FormatException('Missing print audit');
  final status = _status(job['state']),
      attempts = _attempts(job['attempts'] ?? 0);
  for (var i = 0; i < history.length; i++) {
    final event = history[i];
    if (event is! Map ||
        event['ordinal'] != i ||
        !{'created', 'legacy_current', 'transition'}.contains(event['origin']))
      throw const FormatException('Invalid print audit');
    final state = _status(event['state']), count = _attempts(event['attempts']);
    if (i == history.length - 1 &&
        (state != status ||
            count != attempts ||
            event['spooledAt'] != job['spooledAt']))
      throw const FormatException('Incomplete print audit');
    add('print_job_events', {
      'order_id': order,
      'job_id': jobId,
      'event_id': _uuid(event['id']),
      'ordinal': i,
      'observed_at': _stamp(event['observedAt']),
      'origin': event['origin'],
      'status': state,
      'attempts': count,
      'spooled_at': event['spooledAt'] == null
          ? null
          : _stamp(event['spooledAt']),
    });
  }
  add('print_jobs', {
    'order_id': order,
    'job_id': jobId,
    'snapshot_id': snapshotId,
    'source_key': printSourceKey(job),
    'batch_local_id': job['batchId'],
    'local_kind': job['kind'],
    'receipt_request_id': job['receiptRequestId'],
    'receipt_kind': kind,
    'status': status,
    'attempts': attempts,
    'created_at': _stamp(job['createdAt']),
    'spooled_at': job['spooledAt'] == null ? null : _stamp(job['spooledAt']),
  });
  return {
    'source_updated_at': _stamp(stamp),
    'local_order_id': '${job['orderId']}',
    'order_id': order,
    'job_id': jobId,
    'source_key': printSourceKey(job),
    'event_count': history.length,
    'rows': rows,
  };
}

class TypedReceiptTransport implements SyncTransport {
  const TypedReceiptTransport(this.identities, this.delegate);
  final CloudIdentityMap identities;
  final SyncTransport delegate;
  SyncTransaction encode(SyncTransaction tx) => SyncTransaction(
    authorityEpoch: tx.authorityEpoch,
    sourceRevision: tx.sourceRevision,
    events: [for (final event in tx.events) _event(tx, event)],
  );
  SyncEvent _event(SyncTransaction tx, SyncEvent event) {
    if (event.entityType != 'printJobs') return event;
    if (event.op != 'upsert' || event.createdAt == null)
      throw const FormatException('Print audit cannot be erased');
    final raw = jsonDecode(event.payloadJson);
    if (raw is! Map) throw const FormatException('Invalid print projection');
    final job = Map<String, dynamic>.from(raw);
    if (event.entityId != printSourceKey(job))
      throw const FormatException('Print source mismatch');
    final body = canonicalJson(
      serializeReceipt(job, identities, event.createdAt!),
    );
    return SyncEvent(
      seq: event.seq,
      eventId:
          '${tx.authorityEpoch}:${tx.sourceRevision}:typed_print:${event.entityId}',
      entityType: 'typed_print',
      entityId: event.entityId,
      op: 'upsert',
      payloadJson: body,
      payloadSha256: hash.sha256.convert(utf8.encode(body)).toString(),
      ordinal: event.ordinal,
      createdAt: event.createdAt,
    );
  }

  @override
  Future<IngestResult> ingest(SyncTransaction tx) {
    try {
      return delegate.ingest(encode(tx));
    } on FormatException {
      throw const SyncRejectedException('invalid_print_projection');
    }
  }
}
