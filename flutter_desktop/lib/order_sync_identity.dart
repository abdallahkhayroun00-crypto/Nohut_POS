import 'dart:math';

import 'entity_storage.dart' show jsonEquals;

String newSyncUuid() {
  final random = Random.secure(), bytes = List.generate(16, (_) => 0);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = random.nextInt(256);
  }
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

List<Map> _rows(Object? raw) {
  if (raw == null) return [];
  if (raw is! List || raw.any((r) => r is! Map))
    throw const FormatException('Invalid order identity source');
  return raw.cast<Map>();
}

/// Assign once and persist in the same business transaction. An index may
/// locate a legacy line, but it never becomes its identity. Existing IDs
/// survive quantity/price edits, reordering, cancellation and soft deletion.
void prepareOrderSyncIdentities(
  Map<String, dynamic> previous,
  Map<String, dynamic> next, {
  bool force = false,
}) {
  final oldActive = {for (final o in _rows(previous['orders'])) o['id']: o};
  final oldArchive = {
    for (final a in _rows(previous['deletedOrders'])) a['orderId']: a['order'],
  };
  void prepare(Map order, Map? old) {
    final seen = <String, Set<String>>{};
    void identify(Map row, String kind) {
      row['syncId'] ??= newSyncUuid();
      final id = row['syncId'];
      if (id is! String ||
          !RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ).hasMatch(id) ||
          !(seen[kind] ??= <String>{}).add(id))
        throw const FormatException(
          'Invalid or duplicate persistent sync identity',
        );
    }

    final oldEvents = old?['events'], oldIds = old?['syncEventIds'];
    final eventIds = <String, List<String>>{};
    if (oldEvents is List &&
        oldIds is List &&
        oldEvents.length == oldIds.length) {
      for (var i = 0; i < oldEvents.length; i++) {
        (eventIds['${oldEvents[i]}'] ??= <String>[]).add(oldIds[i] as String);
      }
    }
    if (order['events'] is List) {
      order['syncEventIds'] = [
        for (final event in order['events'] as List)
          (eventIds['$event']?.isNotEmpty ?? false)
              ? eventIds['$event']!.removeAt(0)
              : newSyncUuid(),
      ];
    }
    final edits = _rows(order['lineEdits']);
    for (final batch in _rows(order['batches'])) {
      final lines = _rows(batch['lines']);
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        identify(line, 'line');
        final first = edits
            .where((e) => e['key'] == '${batch['id']}:$i')
            .firstOrNull;
        line['syncOriginalQty'] ??=
            line['originalQty'] ??
            (first?['before'] is Map
                ? (first!['before'] as Map)['qty']
                : null) ??
            line['qty'];
      }
    }
    for (final payment in _rows(order['payments'])) {
      identify(payment, 'payment');
      for (final refund in _rows(payment['refunds'])) {
        identify(refund, 'refund');
      }
      for (final allocation in _rows(payment['guestAllocations'])) {
        identify(allocation, 'payment_allocation');
      }
    }
    for (final guest in _rows(order['guestChecks'])) {
      identify(guest, 'guest');
      for (final allocation in _rows(guest['allocations'])) {
        identify(allocation, 'guest_allocation');
      }
    }
    for (final edit in edits) {
      identify(edit, 'line_edit');
    }
    for (final cancellation in _rows(order['voids'])) {
      identify(cancellation, 'void');
    }
  }

  for (final order in _rows(next['orders'])) {
    final old = oldActive[order['id']];
    if (force || !jsonEquals(old, order)) {
      prepare(order, old);
    }
  }
  for (final archive in _rows(next['deletedOrders'])) {
    final order = archive['order'];
    if (order is! Map)
      throw const FormatException('Invalid archived order identity source');
    final old = oldArchive[archive['orderId']];
    if (force || old is! Map || !jsonEquals(old, order)) {
      prepare(order, old is Map ? old : oldActive[archive['orderId']]);
    }
  }
}
