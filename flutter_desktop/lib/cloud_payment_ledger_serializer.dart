/// Existing Windows financial ledgers, with no external payment calls.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as hash;

import 'cloud_catalog_serializer.dart' show exactKurus;
import 'cloud_finance_serializer.dart';
import 'sync_outbox.dart';
import 'sync_worker.dart';

List<Map<String, dynamic>> _rows(Object? v) {
  if (v == null) return [];
  if (v is! List || v.any((r) => r is! Map))
    throw const FormatException('Ledger collection required');
  return v.map((r) => Map<String, dynamic>.from(r as Map)).toList();
}

int _int(Object? v) {
  if (v is! int || v.abs() > 9007199254740991)
    throw const FormatException('Ledger integer required');
  return v;
}

String _text(Object? v) {
  if (v is! String) throw const FormatException('Ledger text required');
  return v;
}

String _stamp(Object? v) {
  final s = _text(v);
  if (DateTime.tryParse(s) == null ||
      !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(s))
    throw const FormatException('Ledger absolute timestamp required');
  return s;
}

String _uuid(Object? v) {
  final s = _text(v);
  if (!RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  ).hasMatch(s))
    throw const FormatException('Ledger persistent identity missing');
  return s;
}

Map<String, Object?> serializePaymentLedger(
  String kind,
  Object? raw,
  CloudIdentityMap ids,
  String stamp,
) {
  final rows = <Map<String, Object?>>[];
  final counts = <String, int>{};
  void add(String table, Map<String, Object?> data) {
    counts.update(table, (n) => n + 1, ifAbsent: () => 1);
    rows.add({'table': table, 'data': data});
  }

  switch (kind) {
    case 'combinedPayments':
      counts.addAll({
        'combined_payment_groups': 0,
        'combined_payment_members': 0,
      });
      for (final group in _rows(raw)) {
        final reference = _text(group['id']),
            id = ids.id('combined_payment', reference);
        final method = switch (group['method']) {
          'Nakit' => 'cash',
          'Kart' => 'card',
          'Karışık' => 'mixed',
          _ => throw const FormatException('Invalid combined payment method'),
        };
        final orders = group['orderIds'];
        if (orders is! List ||
            orders.isEmpty ||
            orders.any((i) => i is! int) ||
            orders.toSet().length != orders.length)
          throw const FormatException('Combined order manifest required');
        add('combined_payment_groups', {
          'group_id': id,
          'source_reference': reference,
          'method': method,
          'amount_kurus': exactKurus(group['amount']),
          'cash_kurus': exactKurus(group['cash']),
          'card_kurus': exactKurus(group['card']),
          'received_kurus': group['received'] == null
              ? null
              : exactKurus(group['received']),
          'recorded_at': _stamp(group['createdAt']),
          'order_count': orders.length,
        });
        for (var i = 0; i < orders.length; i++) {
          add('combined_payment_members', {
            'group_id': id,
            'order_id': ids.id('order', _int(orders[i])),
            'ordinal': i,
          });
        }
      }
    case 'terminalAttempts':
      counts.addAll({'terminal_attempts': 0, 'terminal_attempt_events': 0});
      for (final attempt in _rows(raw)) {
        final reference = _text(attempt['reference']),
            id = ids.id('terminal_attempt', reference),
            local = _int(attempt['orderId']);
        final history = _rows(attempt['syncHistory']);
        if (history.isEmpty)
          throw const FormatException('Terminal audit missing');
        final amount = _int(attempt['amountCents']),
            status = _text(attempt['status']);
        if (!{
          'waiting',
          'unknown',
          'approved',
          'declined',
          'cancelled',
        }.contains(status))
          throw const FormatException('Invalid terminal state');
        final dispatched = attempt['dispatched'] == true;
        final last = history.last;
        if (last['status'] != status ||
            last['dispatched'] != dispatched ||
            last['transactionId'] != attempt['transactionId'])
          throw const FormatException('Terminal state is not audited');
        add('terminal_attempts', {
          'attempt_id': id,
          'source_reference': reference,
          'order_id': ids.id('order', local),
          'local_order_id': local,
          'amount_kurus': amount,
          'status': status,
          'dispatched': dispatched,
          'transaction_id': attempt['transactionId'],
          'first_observed_at': _stamp(history.first['observedAt']),
          'last_observed_at': _stamp(last['observedAt']),
          'event_count': history.length,
        });
        for (var i = 0; i < history.length; i++) {
          final e = history[i];
          if (e['ordinal'] != i ||
              e['amountCents'] != amount ||
              e['orderId'] != local)
            throw const FormatException('Terminal facts changed');
          add('terminal_attempt_events', {
            'attempt_id': id,
            'event_id': _uuid(e['id']),
            'ordinal': i,
            'observed_at': _stamp(e['observedAt']),
            'origin': _text(e['origin']),
            'status': _text(e['status']),
            'dispatched': e['dispatched'],
            'transaction_id': e['transactionId'],
          });
        }
      }
    case 'cashBook':
      counts.addAll({'cash_sessions': 0, 'cash_movements': 0});
      if (raw is! Map) throw const FormatException('Cash book required');
      for (final session in _rows(raw['sessions'])) {
        final local = _int(session['id']);
        add('cash_sessions', {
          'session_id': ids.id('cash_session', local),
          'local_id': local,
          'opened_at': _stamp(session['openedAt']),
          'opened_by': _text(session['openedBy']),
          'opening_kurus': _int(session['openingCents']),
          'closed_at': session['closedAt'] == null
              ? null
              : _stamp(session['closedAt']),
          'closed_by': session['closedBy'],
          'counted_kurus': session['countedCents'],
          'expected_kurus': session['expectedCents'],
          'difference_kurus': session['differenceCents'],
        });
      }
      for (final movement in _rows(raw['movements'])) {
        add('cash_movements', {
          'movement_id': _uuid(movement['syncId']),
          'session_id': ids.id('cash_session', _int(movement['sessionId'])),
          'amount_kurus': _int(movement['cents']),
          'note': _text(movement['note']),
          'recorded_at': _stamp(movement['at']),
          'actor_label': _text(movement['by']),
        });
      }
    default:
      throw const FormatException('Unsupported financial ledger');
  }
  return {'source_updated_at': _stamp(stamp), 'counts': counts, 'rows': rows};
}

class TypedPaymentLedgerTransport implements SyncTransport {
  const TypedPaymentLedgerTransport(this.identities, this.delegate);
  final CloudIdentityMap identities;
  final SyncTransport delegate;
  SyncTransaction encode(SyncTransaction tx) => SyncTransaction(
    authorityEpoch: tx.authorityEpoch,
    sourceRevision: tx.sourceRevision,
    events: [for (final e in tx.events) _event(tx, e)],
  );
  SyncEvent _event(SyncTransaction tx, SyncEvent e) {
    if (!{
      'combinedPayments',
      'terminalAttempts',
      'cashBook',
    }.contains(e.entityType))
      return e;
    if (e.op != 'upsert' || e.entityId != 'core' || e.createdAt == null)
      throw const FormatException('Financial history cannot be erased');
    final body = canonicalJson(
      serializePaymentLedger(
        e.entityType,
        jsonDecode(e.payloadJson),
        identities,
        e.createdAt!,
      ),
    );
    return SyncEvent(
      seq: e.seq,
      eventId:
          '${tx.authorityEpoch}:${tx.sourceRevision}:typed_ledger:${e.entityType}',
      entityType: 'typed_ledger',
      entityId: e.entityType,
      op: 'upsert',
      payloadJson: body,
      payloadSha256: hash.sha256.convert(utf8.encode(body)).toString(),
      ordinal: e.ordinal,
      createdAt: e.createdAt,
    );
  }

  @override
  Future<IngestResult> ingest(SyncTransaction tx) {
    try {
      return delegate.ingest(encode(tx));
    } on FormatException {
      throw const SyncRejectedException('invalid_payment_ledger');
    }
  }
}
