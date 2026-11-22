import 'pos_logic.dart';
import 'trendyol_go_readonly.dart';

/// Estimates only. A platform's fee invoice and its eventual bank settlement
/// must be reconciled separately (different dates, refunds, promotions, tax).
const deliverySources = <String>[
  'Trendyol Go', 'Migros Yemek', 'Yemeksepeti',
];

class DeliveryNetEstimate {
  const DeliveryNetEstimate({
    required this.source,
    required this.orderCount,
    required this.grossCents,
    required this.deductionPercent,
  });
  final String source;
  final int orderCount, grossCents;
  /// Effective *total invoice deduction*, inclusive of any fee VAT.
  /// Null means unverified; zero is a deliberate zero-fee setting.
  final double? deductionPercent;

  int? get deductionCents => deductionPercent == null ? null :
      (grossCents * deductionPercent! / 100).round();
  int? get estimatedNetCents => deductionCents == null
      ? null : grossCents - deductionCents!;
}

double? deliveryDeductionPercent(Json state, String source) {
  final settings = state['settings'];
  final rates = settings is Map ? settings['platformDeductionRates'] : null;
  final rate = rates is Map ? rates[source] : null;
  if (rate is! num) return null;
  final pct = rate.toDouble();
  return pct.isFinite && pct >= 0 && pct <= 100 ? pct : null;
}

/// Delivered, non-demo records only. POS order totals are not guaranteed to
/// equal the actual invoice base, so these are projections, not bank receipts.
List<DeliveryNetEstimate> deliveryNetEstimates(
  Json state,
  bool Function(String) inPeriod, {
  String source = 'Tümü',
}) {
  final totals = <String, int>{for (final s in deliverySources) s: 0};
  final counts = <String, int>{for (final s in deliverySources) s: 0};
  for (final o in asMaps(state['orders'])) {
    final s = (o['source'] ?? '').toString();
    if (s == 'Trendyol Go' || !totals.containsKey(s) ||
        o['cancelled'] == true || o['testPackage'] == true ||
        o['demoRemoteStatus'] != null || o['status'] != 'Delivered' ||
        !inPeriod((o['createdAt'] ?? '').toString())) continue;
    final snapshot = o['platformSnapshot'];
    final amount = snapshot is Map && snapshot['orderTotal'] != null
        ? cents(snapshot['orderTotal']) : orderTotalCents(o);
    if (amount < 0) continue;
    totals[s] = totals[s]! + amount;
    counts[s] = counts[s]! + 1;
  }
  for (final o in tgoOrders(state)) {
    if (!tgoCountsAsSale(o) ||
        !inPeriod((o['createdAt'] ?? '').toString())) continue;
    final amount = o['totalCents'];
    if (amount is! int || amount < 0) continue;
    totals['Trendyol Go'] = totals['Trendyol Go']! + amount;
    counts['Trendyol Go'] = counts['Trendyol Go']! + 1;
  }
  return [
    for (final s in deliverySources)
      if (source == 'Tümü' || source == s)
        DeliveryNetEstimate(
          source: s,
          orderCount: counts[s]!,
          grossCents: totals[s]!,
          deductionPercent: deliveryDeductionPercent(state, s),
        ),
  ];
}
