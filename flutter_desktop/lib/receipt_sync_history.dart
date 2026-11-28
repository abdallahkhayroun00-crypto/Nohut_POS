/// Additive print audit metadata. Never submits a print or changes its state.
library;

import 'entity_storage.dart' show jsonEquals;
import 'operations.dart' show receiptText;
import 'order_sync_identity.dart' show newSyncUuid;
import 'pos_logic.dart' show copyJson;

List<Map> cloudPrintJobs(Map state) => [
  ...((state['printJobs'] as List?) ?? const []).cast<Map>(),
  for (final archive
      in ((state['deletedOrders'] as List?) ?? const []).cast<Map>())
    ...((archive['related']?['printJobs'] as List?) ?? const []).cast<Map>(),
];

String printSourceKey(Map job) =>
    '${job['orderId']}:${job['batchId']}:${job['kind'] ?? ''}';

/// Receipt contact redactions are deliberate privacy exceptions. The local
/// original and actual printer content remain unchanged.
String privateReceiptText(String text, Map? customer) {
  text = text.replaceAllMapped(RegExp(r'Müşteri:[^\r\n]*'), (m) {
    final time = RegExp(r' · Saat ([^\r\n]+)$').firstMatch(m[0]!);
    return time == null ? 'Müşteri: [yerel]' : 'Saat ${time[1]}';
  });
  for (final key in ['name', 'phone']) {
    final value = '${customer?[key] ?? ''}'.trim();
    if (value.isNotEmpty)
      text = text.replaceAll(value, '[yerel iletişim bilgisi]');
  }
  return text.replaceAll(
    RegExp(r'(?<![0-9])(?:\+?90[ .()-]*)?0?5(?:[ .()-]*[0-9]){9}(?![0-9])'),
    '[yerel iletişim bilgisi]',
  );
}

void prepareReceiptSyncHistory(
  Map<String, dynamic> previous,
  Map<String, dynamic> next,
  String stamp, {
  bool force = false,
}) {
  final before = {
    for (final job in cloudPrintJobs(previous)) printSourceKey(job): job,
  };
  final ids = <String>{};
  for (final job in cloudPrintJobs(next)) {
    final old = before[printSourceKey(job)];
    if (!force && jsonEquals(old, job)) continue;
    job['syncId'] ??= newSyncUuid();
    if (job['syncId'] is! String || !ids.add(job['syncId'] as String))
      throw const FormatException('Duplicate print identity');
    if (job['syncReceipt'] == null) {
      // Kitchen content must come from its frozen snapshot. Historical jobs
      // without one cannot be reconstructed from a later mutable order.
      final snapshot = job['snapshot'];
      String? text;
      Map? customer;
      String? format;
      if (job['kind'] == 'paymentReceipt' && job['text'] is String) {
        Map? sourceOrder;
        for (final order in (next['orders'] as List).cast<Map>()) {
          if (order['id'] == job['orderId']) sourceOrder = order;
        }
        for (final a
            in ((next['deletedOrders'] as List?) ?? const []).cast<Map>()) {
          if (a['orderId'] == job['orderId']) sourceOrder = a['order'] as Map?;
        }
        if (sourceOrder != null &&
            {'Masa', 'Gel-Al'}.contains(sourceOrder['source'])) {
          text = job['text'] as String;
          format = 'payment_text';
          customer = sourceOrder['customer'] as Map?;
        }
      } else if (snapshot is Map &&
          snapshot['order'] is Map &&
          {'Masa', 'Gel-Al'}.contains(snapshot['order']['source']) &&
          snapshot['batch'] is Map) {
        final safe = copyJson(Map<String, dynamic>.from(snapshot));
        customer = safe['order']['customer'] as Map?;
        safe['order']['customer'] = {'time': customer?['time'] ?? ''};
        try {
          text = receiptText(next, {
            ...Map<String, dynamic>.from(job),
            'snapshot': safe,
          });
          format = 'frozen_kitchen';
        } on FormatException {
          /* Serializer will refuse this unsupported record. */
        }
      }
      if (text != null) {
        job['syncReceipt'] = {
          'schemaVersion': 1,
          'sourceFormat': format,
          'body': privateReceiptText(text, customer),
          'privacy': 'customer_contact_redacted',
        };
      }
    }
    final history =
        (job.putIfAbsent('syncPrintHistory', () => <dynamic>[]) as List);
    final state = {
      'state': job['state'],
      'attempts': job['attempts'] ?? 0,
      'spooledAt': job['spooledAt'],
    };
    if (history.isEmpty && old != null) {
      final prior = {
        'state': old['state'],
        'attempts': old['attempts'] ?? 0,
        'spooledAt': old['spooledAt'],
      };
      if (!jsonEquals(prior, state))
        history.add({
          'id': newSyncUuid(),
          'ordinal': 0,
          'observedAt': stamp,
          'origin': 'legacy_current',
          ...prior,
        });
    }
    final last = history.isEmpty ? null : history.last as Map;
    if (last == null ||
        !jsonEquals({for (final k in state.keys) k: last[k]}, state)) {
      history.add({
        'id': newSyncUuid(),
        'ordinal': history.length,
        'observedAt': stamp,
        'origin': last != null
            ? 'transition'
            : old == null
            ? 'created'
            : 'legacy_current',
        ...state,
      });
    }
  }
}
