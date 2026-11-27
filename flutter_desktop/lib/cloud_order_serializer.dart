/// Typed sale facts from the Windows authority. Customer contact fields and
/// raw platform/receipt payloads never enter this serializer's wire format.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as hash;

import 'cloud_catalog_serializer.dart' show exactKurus;
import 'cloud_finance_serializer.dart';
import 'operations.dart' show guestBalance;
import 'order_reporting.dart' show istanbulDay;
import 'pos_logic.dart' show paymentGuestCents;
import 'sync_outbox.dart';
import 'sync_worker.dart';

List<Map<String, dynamic>> _rows(Object? value) {
  if (value == null) return [];
  if (value is! List || value.any((r) => r is! Map))
    throw const FormatException('Invalid order collection');
  return value.map((r) => Map<String, dynamic>.from(r as Map)).toList();
}

int _int(Object? value) {
  if (value is! int || value.abs() > 9007199254740991)
    throw const FormatException('Order integer required');
  return value;
}

String _text(Object? value) {
  if (value is! String) throw const FormatException('Order text required');
  return value;
}

String _id(Object? value) {
  final id = _text(value);
  if (!RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  ).hasMatch(id))
    throw const FormatException('Persistent order identity missing');
  return id;
}

String _stamp(Object? value) {
  final text = _text(value);
  if (DateTime.tryParse(text) == null ||
      !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(text))
    throw const FormatException('Absolute order timestamp required');
  return text;
}

int? _money(Object? value) => value == null ? null : exactKurus(value);
Map<String, Object?> _customizations(Map<String, dynamic> line) => {
  'removed': line['removed'] ?? <String>[],
  'note': line['note'] ?? '',
  'base_price_kurus': _money(line['basePrice']),
  'adjustment_kurus': line['adjustmentCents'] ?? 0,
  'custom_item': line['customItem'] ?? false,
  'campaign_source_id': line['campaignId'],
  'components': [
    for (final c in _rows(line['components']))
      {
        'product_local_id': c['productId'],
        'label': _text(c['name']),
        'qty': c['qty'],
        'slot': c['slot'],
        'price_kurus': _money(c['price']),
        'base_price_kurus': _money(c['basePrice']),
        'adjustment_kurus': c['adjustmentCents'],
        'removed': c['removed'] ?? <String>[],
        'note': c['note'] ?? '',
      },
  ],
};

Map<String, Object?> serializeOrder(
  Map<String, dynamic> order,
  CloudIdentityMap ids,
  String sourceUpdatedAt, {
  Map<String, dynamic>? archive,
}) {
  final local = _int(order['id']),
      id = ids.id('order', local),
      rows = <Map<String, Object?>>[];
  final totals = order['_windowsTotals'];
  if (totals is! Map) throw const FormatException('Windows totals missing');
  final channel = switch (order['source']) {
    'Masa' => 'masa',
    'Gel-Al' => 'gel_al',
    'Trendyol Go' => 'trendyol',
    'Yemeksepeti' => 'yemeksepeti',
    'Migros Yemek' => 'migros',
    _ => throw const FormatException('Unsupported order source'),
  };
  if (!{'masa', 'gel_al'}.contains(channel))
    throw const FormatException('Platform order projection not complete');
  final opened = _stamp(order['createdAt']);
  final lineKeys = <String, String>{};
  final counts = <String, int>{
    'orders': 1,
    'order_batches': _rows(order['batches']).length,
    'order_items': _rows(
      order['batches'],
    ).fold(0, (n, b) => n + _rows(b['lines']).length),
    'payments': _rows(order['payments']).length,
    'payment_refunds': _rows(
      order['payments'],
    ).fold(0, (n, p) => n + _rows(p['refunds']).length),
    'guest_checks': _rows(order['guestChecks']).length,
    'guest_allocations': _rows(
      order['guestChecks'],
    ).fold(0, (n, g) => n + _rows(g['allocations']).length),
    'payment_guest_allocations': _rows(
      order['payments'],
    ).fold(0, (n, p) => n + _rows(p['guestAllocations']).length),
    'order_events': _rows(order['_audit']).length,
    'order_line_edits': _rows(order['lineEdits']).length,
    'order_voids': _rows(order['voids']).length,
    'deleted_order_audit': archive == null ? 0 : 1,
  };
  void add(String table, Map<String, Object?> data, {String? removedAt}) =>
      rows.add({
        'table': table,
        'data': data,
        if (removedAt != null) ...{'deleted': true, 'removed_at': removedAt},
      });
  String? tableId;
  if (channel == 'masa') {
    final table = _int(order['table']);
    tableId = ids.id('pos_table', table);
    add('pos_tables', {'table_id': tableId, 'label': 'Masa $table'});
  }
  add('orders', {
    'order_id': id,
    'local_order_id': '$local',
    'channel': channel,
    'table_id': tableId,
    'opened_at': opened,
    'closed_at': order['closedAt'],
    'business_day': istanbulDay(DateTime.parse(opened)),
    'number_day': order['numberDay'],
    'daily_number': order['dailyNumber'],
    'status': order['cancelled'] == true
        ? 'cancelled'
        : order['closed'] == true
        ? 'closed'
        : 'open',
    'total_kurus': _int(totals['total_kurus']),
    'paid_kurus': _int(totals['paid_kurus']),
    'due_kurus': _int(totals['due_kurus']),
    'cancelled': order['cancelled'] ?? false,
    'table_released': order['tableReleased'] ?? false,
    'service_status': order['serviceStatus'],
    'pickup_channel': order['pickupChannel'],
    'pickup_time': order['customer'] is Map ? order['customer']['time'] : null,
    'customer_local_id': order['customer'] is Map
        ? order['customer']['id']
        : null,
    'cancel_reason': order['cancelReason'],
    'cancelled_at': order['cancelledAt'],
    'service_started_at': order['serviceStartedAt'],
    'ready_at': order['readyAt'],
    'delivered_at': order['deliveredAt'],
    'platform_collection': order['platformCollection'],
  }, removedAt: archive == null ? null : _stamp(archive['deletedAt']));
  for (final batch in _rows(order['batches'])) {
    final batchLocal = _int(batch['id']),
        batchId = ids.id('order_batch', [local, batchLocal]);
    add('order_batches', {
      'order_id': id,
      'batch_id': batchId,
      'local_batch_id': batchLocal,
      'employee_local_id': batch['staffId'],
      'staff_label_at_sale': batch['staff'],
      'created_at': _stamp(batch['createdAt']),
      'source_time_label': batch['time'],
    });
    final lines = _rows(batch['lines']);
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index],
          itemId = _id(line['syncId']),
          legacyKey = '$batchLocal:$index';
      lineKeys[legacyKey] = itemId;
      // Legacy sales have no provable catalog-version link. Preserve a
      // transaction-specific immutable definition; never guess by name.
      final product = ids.id('sale_product', itemId);
      final definition = <String, Object?>{
        'label_tr': _text(line['name']),
        'label_en': null,
        'label_ar': null,
        'price_kurus': exactKurus(line['price']),
        'category_key': null,
        'description_tr': null,
        'description_en': null,
        'description_ar': null,
        'display_name_tr': null,
        'display_name_en': null,
        'display_name_ar': null,
        'image_path': null,
        'active': true,
        'available': true,
        'internal_only': true,
      };
      final version = ids.id('sale_product_version', [
        product,
        canonicalJson(definition),
      ]);
      add('products', {
        'product_id': product,
        'local_id': null,
        'source_kind': 'historical_sale',
        'source_item_id': itemId,
        'current_version_id': version,
      });
      add('product_versions', {
        'product_id': product,
        'product_version_id': version,
        ...definition,
        'content_sha256': hash.sha256
            .convert(utf8.encode(canonicalJson(definition)))
            .toString(),
      });
      add('order_items', {
        'order_id': id,
        'batch_id': batchId,
        'item_id': itemId,
        'product_id': product,
        'product_version_id': version,
        'sale_label': _text(line['name']),
        'original_qty': _int(
          line['syncOriginalQty'] ?? line['originalQty'] ?? line['qty'],
        ),
        'qty': _int(line['qty']),
        'unit_price_kurus': exactKurus(line['price']),
        'voided': line['voided'] ?? false,
        'correction': line['correction'] ?? false,
        'local_line_key': legacyKey,
        'source_product_local_id': line['productId'],
        'source_product_key': line['productKey'],
        'customizations': _customizations(line),
      });
    }
  }
  for (final payment in _rows(order['payments'])) {
    final paymentId = _id(payment['syncId']),
        refunds = _rows(payment['refunds']);
    final gross = exactKurus(payment['amount']),
        refunded = refunds.fold<int>(0, (n, r) => n + exactKurus(r['amount']));
    final method = switch (payment['method']) {
      'Nakit' => 'nakit',
      'Kart' => 'kart',
      'Platform' => 'platform',
      _ => throw const FormatException('Unsupported payment method'),
    };
    add('payments', {
      'order_id': id,
      'payment_id': paymentId,
      'method': method,
      'amount_kurus': gross,
      'received_kurus': _money(payment['received']),
      'change_kurus': _money(payment['change']),
      'employee_local_id': payment['staffId'],
      'actor_label': payment['by'],
      'recorded_at': _stamp(payment['createdAt']),
      'reversed': payment['reversed'] ?? false,
      'net_kurus': payment['reversed'] == true ? 0 : gross - refunded,
      'local_guest_id': payment['guestCheckId'],
      'combined_payment_id': payment['combinedPaymentId']?.toString(),
      'terminal_reference': payment['terminalReference'],
      'transaction_id': payment['transactionId'],
      'product_payment_id': payment['productPaymentId'],
    });
    for (final refund in refunds) {
      add('payment_refunds', {
        'order_id': id,
        'payment_id': paymentId,
        'refund_id': _id(refund['syncId']),
        'amount_kurus': exactKurus(refund['amount']),
        'recorded_at': _stamp(refund['createdAt']),
        'actor_label': refund['by'],
        'reason': refund['reason'],
      });
    }
    for (final allocation in _rows(payment['guestAllocations'])) {
      add('payment_guest_allocations', {
        'order_id': id,
        'payment_id': paymentId,
        'allocation_id': _id(allocation['syncId']),
        'local_guest_id': _int(allocation['guestCheckId']),
        'amount_kurus': exactKurus(allocation['amount']),
      });
    }
  }
  for (final guest in _rows(order['guestChecks'])) {
    final guestId = _id(guest['syncId']), guestLocal = _int(guest['id']);
    final allocations = _rows(guest['allocations']);
    final allocated = allocations.fold<int>(0, (n, a) => n + _int(a['cents']));
    final paid = _rows(
      order['payments'],
    ).fold<int>(0, (n, p) => n + paymentGuestCents(p, guestLocal));
    add('guest_checks', {
      'order_id': id,
      'guest_id': guestId,
      'local_id': guestLocal,
      'label': guest['name'] ?? '',
      'allocated_kurus': allocated,
      'paid_kurus': paid,
      'balance_kurus': guestBalance(order, guestLocal),
    });
    for (final allocation in allocations) {
      final key = _text(allocation['key']), item = lineKeys[key];
      if (item == null)
        throw const FormatException('Unknown allocated order line');
      add('guest_allocations', {
        'order_id': id,
        'guest_id': guestId,
        'allocation_id': _id(allocation['syncId']),
        'item_id': item,
        'local_line_key': key,
        'amount_kurus': _int(allocation['cents']),
      });
    }
  }
  for (final event in _rows(order['_audit'])) {
    add('order_events', {
      'order_id': id,
      'event_id': _id(event['id']),
      'message': _text(event['message']),
    });
  }
  for (final edit in _rows(order['lineEdits'])) {
    final before = edit['before'], key = _text(edit['key']);
    if (before is! Map)
      throw const FormatException('Missing historical line edit');
    final item = before['syncId'] ?? lineKeys[key];
    if (item == null)
      throw const FormatException('Unknown edited line identity');
    add('order_line_edits', {
      'order_id': id,
      'edit_id': _id(edit['syncId']),
      'item_id': _id(item),
      'changed_at': _stamp(edit['at']),
      'actor_label': edit['by'] ?? '',
      'local_line_key': key,
      'before_label': _text(before['name']),
      'before_qty': _int(before['qty']),
      'before_unit_price_kurus': exactKurus(before['price']),
      'before_customizations': _customizations(
        Map<String, dynamic>.from(before),
      ),
    });
  }
  for (final cancelled in _rows(order['voids'])) {
    add('order_voids', {
      'order_id': id,
      'void_id': _id(cancelled['syncId']),
      'label': _text(cancelled['name']),
      'quantity': _int(cancelled['qty']),
      'unit_price_kurus': exactKurus(cancelled['price']),
      'recorded_at': _stamp(cancelled['createdAt']),
      'reason': _text(cancelled['reason']),
    });
  }
  if (archive != null)
    add('deleted_order_audit', {
      'order_id': id,
      'deleted_at_source': _stamp(archive['deletedAt']),
      'actor_label': archive['deletedBy'],
      'actor_local_id': archive['deletedByStaffId'],
      'reason': _text(archive['reason']),
      'request_id': _text(archive['requestId']),
    });
  return {
    'source_updated_at': sourceUpdatedAt,
    'order_id': id,
    'local_order_id': '$local',
    'counts': counts,
    'rows': rows,
  };
}

class TypedOrderTransport implements SyncTransport {
  const TypedOrderTransport(this.identities, this.delegate);
  final CloudIdentityMap identities;
  final SyncTransport delegate;
  SyncTransaction encode(SyncTransaction tx) => SyncTransaction(
    authorityEpoch: tx.authorityEpoch,
    sourceRevision: tx.sourceRevision,
    events: [for (final event in tx.events) _event(tx, event)],
  );
  SyncEvent _event(SyncTransaction tx, SyncEvent event) {
    if (!{'orders', 'deletedOrders'}.contains(event.entityType)) return event;
    if (event.createdAt == null)
      throw const FormatException('Order event time missing');
    final raw = jsonDecode(event.payloadJson);
    final marker = event.entityType == 'orders' && event.op == 'delete';
    final kind = marker ? 'order_archive_marker' : 'typed_order';
    final Map<String, Object?> payload;
    if (marker) {
      payload = {'local_order_id': event.entityId, 'archive_required': true};
    } else {
      if (raw is! Map) throw const FormatException('Invalid order event');
      final archive = event.entityType == 'deletedOrders'
          ? Map<String, dynamic>.from(raw)
          : null;
      final order = archive == null
          ? Map<String, dynamic>.from(raw)
          : Map<String, dynamic>.from(archive['order'] as Map);
      payload = serializeOrder(
        order,
        identities,
        event.createdAt!,
        archive: archive,
      );
    }
    final body = canonicalJson(payload);
    return SyncEvent(
      seq: event.seq,
      eventId:
          '${tx.authorityEpoch}:${tx.sourceRevision}:$kind:${event.entityId}',
      entityType: kind,
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
      throw const SyncRejectedException('invalid_order_projection');
    }
  }
}
