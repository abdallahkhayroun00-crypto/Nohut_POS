/// Allowlisted commercial facts only. No external calls, raw payloads,
/// credentials, customer directory or bank-settlement inference.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as hash;

import 'cloud_finance_serializer.dart';
import 'order_reporting.dart' show istanbulDay;
import 'sync_outbox.dart';
import 'sync_worker.dart';
import 'trendyol_go_readonly.dart' show tgoCountsAsSale;

String _text(Object? v, {bool required = false}) {
  if (v is! String || (required && v.isEmpty))
    throw const FormatException('Platform text required');
  return v;
}

int _int(Object? v) {
  if (v is! int || v < 0 || v > 9007199254740991)
    throw const FormatException('Platform integer required');
  return v;
}

String _stamp(Object? v) {
  final s = _text(v);
  if (DateTime.tryParse(s) == null ||
      !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(s))
    throw const FormatException('Platform absolute timestamp required');
  return s;
}

List<String> _strings(Object? v) {
  if (v == null) return [];
  if (v is! List || v.any((x) => x is! String))
    throw const FormatException('Platform string list required');
  return v.cast<String>();
}

Map<String, Object?> serializeTgoOrder(
  Map<String, dynamic> source,
  CloudIdentityMap ids,
  String stamp,
) {
  if (source['source'] != 'Trendyol Go')
    throw const FormatException('Platform source mismatch');
  final supplier = _text(source['supplierId'], required: true),
      store = _text(source['storeId'], required: true),
      package = _text(source['packageId'], required: true);
  final sourceKey = '$supplier:$store:$package';
  if([supplier,store,package].any((s)=>!RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(s)))throw const FormatException('Unsupported platform identity');
  final orderId = ids.id('tgo_order', [supplier, store, package]),
      record = ids.id('tgo_record', [supplier, store, package]);
  final complete = source['lineFacts'] is List;
  final raw = complete ? source['lineFacts'] : source['lines'];
  if (raw is! List || raw.any((r) => r is! Map))
    throw const FormatException('Platform line facts required');
  final lines = <Map<String, Object?>>[];
  for (var i = 0; i < raw.length; i++) {
    final line = raw[i] as Map;
    lines.add({
      'ordinal': i,
      'label': _text(line['name']),
      'qty': _int(line['qty']),
      'original_qty': complete ? line['originalQty'] : null,
      'quantity_known': complete ? line['quantityKnown'] : false,
      'unit_price_kurus': _int(line['unitPriceCents']),
      'unit_price_known': complete ? line['unitPriceKnown'] : null,
      'item_ids': _strings(line['itemIds']),
      'cancelled_item_ids': _strings(line['cancelledItemIds']),
      'options': _strings(line['options']),
      'removed': _strings(line['removed']),
      'extras': _strings(line['extras']),
    });
  }
  final created = _stamp(source['createdAt']),
      status = _text(source['status'], required: true);
  final header = <String, Object?>{
    'external_order_reference': source['orderId'],
    'order_number': _text(source['orderNumber'], required: true),
    'order_code': source['orderCode'],
    'status': status,
    'created_at': created,
    'modified_at': _stamp(source['modifiedAt']),
    'total_kurus': _int(source['totalCents']),
    'total_known': source['totalKnown'],
    'payment_type': source['paymentType'],
    'cancel_reason': source['cancelReason'],
    'preparation_minutes': source['preparationMinutes'],
    'pickup': source['pickup'] ?? false,
    'test_package': source['testPackage'] ?? false,
    'sales_eligible': tgoCountsAsSale(source),
    'daily_number': source['dailyNumber'],
    'number_day': source['numberDay'],
    'customer_note': source['customerNote'] ?? '',
    'delivery_type': source['deliveryType'],
    'app_name': source['appName'],
    'pickup_eta_state': source['pickupEtaState'],
    'delivery_eta': source['deliveryEta'],
    'courier_nearby': source['courierNearby'],
    'courier_eta_from': source['courierEtaFrom'],
    'courier_eta_to': source['courierEtaTo'],
    'kitchen_print_state': source['kitchenPrintState'],
    'kitchen_queued_at': source['kitchenQueuedAt'],
    'package_item_ids': _strings(source['packageItemIds']),
    'source_complete': complete,
    'line_count': lines.length,
    'privacy': 'customer_contact_redacted',
  };
  final definition = canonicalJson({'header': header, 'lines': lines});
  final version = ids.id('tgo_commercial_version', [record, definition]);
  final rows = <Map<String, Object?>>[];
  void add(String table, Map<String, Object?> data) =>
      rows.add({'table': table, 'data': data});
  add('orders', {
    'order_id': orderId,
    'local_order_id': 'platform:trendyol:$sourceKey',
    'channel': 'trendyol',
    'table_id': null,
    'opened_at': created,
    'business_day': istanbulDay(DateTime.parse(created)),
    'status': status,
    'total_kurus': header['total_kurus'],
    'paid_kurus': 0,
    'due_kurus': 0,
    'cancelled': {'Cancelled', 'UnSupplied'}.contains(status),
    'table_released': false,
    'platform_collection': 'Unknown',
  });
  add('platform_order_records', {
    'record_id': record,
    'order_id': orderId,
    'platform': 'trendyol',
    'external_supplier_id': supplier,
    'external_store_id': store,
    'external_order_id': package,
    'order_total_kurus': header['total_kurus'],
    'status': status,
    'gross_kurus': null,
    'commission_kurus': null,
    'discount_kurus': null,
    'net_kurus': null,
    'current_version_id': version,
  });
  add('platform_order_versions', {
    'record_id': record,
    'platform_version_id': version,
    ...header,
    'content_sha256': hash.sha256.convert(utf8.encode(definition)).toString(),
  });
  final repeats = <String, int>{};
  for (final line in lines) {
    final identity = Map<String, Object?>.from(line)..remove('ordinal');
    final key = canonicalJson(identity),
        occurrence = repeats.update(key, (n) => n + 1, ifAbsent: () => 0);
    add('platform_line_versions', {
      'platform_version_id': version,
      'line_version_id': ids.id('tgo_line_fact', [version, key, occurrence]),
      ...line,
    });
  }
  return {
    'source_updated_at': _stamp(stamp),
    'source_key': sourceKey,
    'order_id': orderId,
    'record_id': record,
    'platform_version_id': version,
    'line_count': lines.length,
    'rows': rows,
  };
}

class TypedPlatformTransport implements SyncTransport {
  const TypedPlatformTransport(this.identities, this.delegate);
  final CloudIdentityMap identities;
  final SyncTransport delegate;
  SyncTransaction encode(SyncTransaction tx) => SyncTransaction(
    authorityEpoch: tx.authorityEpoch,
    sourceRevision: tx.sourceRevision,
    events: [for (final event in tx.events) _event(tx, event)],
  );
  SyncEvent _event(SyncTransaction tx, SyncEvent event) {
    if (event.entityType != 'trendyolGoOrders') return event;
    if (event.op != 'upsert' || event.createdAt == null)
      throw const FormatException('Platform history cannot be erased');
    final source = jsonDecode(event.payloadJson);
    if (source is! Map)
      throw const FormatException('Invalid platform projection');
    final payload = serializeTgoOrder(
      Map<String, dynamic>.from(source),
      identities,
      event.createdAt!,
    );
    if (payload['source_key'] != event.entityId)
      throw const FormatException('Platform source identity mismatch');
    final body = canonicalJson(payload);
    return SyncEvent(
      seq: event.seq,
      eventId:
          '${tx.authorityEpoch}:${tx.sourceRevision}:typed_platform:${event.entityId}',
      entityType: 'typed_platform',
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
      throw const SyncRejectedException('invalid_platform_projection');
    }
  }
}
