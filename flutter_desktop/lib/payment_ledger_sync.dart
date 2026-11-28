/// Additive audit identities only; never dispatches or records a payment.
library;

import 'entity_storage.dart' show jsonEquals;
import 'order_sync_identity.dart' show newSyncUuid;

List<Map> _maps(Object? value) =>
    value is List ? value.whereType<Map>().toList() : [];

List<Map> allTerminalAttempts(Map state) => [
  ..._maps(state['terminalAttempts']),
  for (final archive in _maps(state['deletedOrders']))
    ..._maps(archive['related']?['terminalAttempts']),
];

Object? paymentLedgerCoreValue(Map state, String key) =>
    key == 'terminalAttempts' ? allTerminalAttempts(state) : state[key];

void preparePaymentLedgerSync(
  Map<String, dynamic> previous,
  Map<String, dynamic> next,
  String stamp, {
  bool cashIdentities = false,
  bool force = false,
}) {
  if (cashIdentities && next['cashBook'] is Map) {
    for (final movement in _maps(next['cashBook']['movements'])) {
      movement['syncId'] ??= newSyncUuid();
    }
  }
  final old = {
    for (final a in allTerminalAttempts(previous)) a['reference']: a,
  };
  for (final attempt in allTerminalAttempts(next)) {
    final prior = old[attempt['reference']];
    if (!force && jsonEquals(prior, attempt)) continue;
    final history =
        attempt.putIfAbsent('syncHistory', () => <dynamic>[]) as List;
    Map<String, Object?> facts(Map a) => {
      'status': a['status'],
      'dispatched': a['dispatched'] == true,
      'transactionId': a['transactionId'],
      'amountCents': a['amountCents'],
      'orderId': a['orderId'],
    };
    final current = facts(attempt);
    if (history.isEmpty &&
        prior != null &&
        !jsonEquals(facts(prior), current)) {
      history.add({
        'id': newSyncUuid(),
        'ordinal': 0,
        'observedAt': stamp,
        'origin': 'legacy_current',
        ...facts(prior),
      });
    }
    final last = history.isEmpty ? null : history.last as Map;
    if (last == null ||
        !jsonEquals({
          for (final key in current.keys) key: last[key],
        }, current)) {
      history.add({
        'id': newSyncUuid(),
        'ordinal': history.length,
        'observedAt': stamp,
        'origin': last != null
            ? 'transition'
            : prior == null
            ? 'created'
            : 'legacy_current',
        ...current,
      });
    }
  }
}
