import 'pos_logic.dart';
import 'trendyol_go_readonly.dart';

/// A projection, not a confirmed platform payout or restaurant profit.
const deliverySources = <String>[
  'Trendyol Go', 'Migros Yemek', 'Yemeksepeti',
];

class DeliveryFeeRate {
  const DeliveryFeeRate({
    required this.commissionPercent,
    required this.courierPercent,
    required this.otherPercent,
    required this.feeVatPercent,
  });
  final double commissionPercent, courierPercent, otherPercent, feeVatPercent;

  double get basePercent =>
      commissionPercent + courierPercent + otherPercent;

  static DeliveryFeeRate? fromSettings(Json state, String source) {
    final settings = state['settings'];
    final all = settings is Map ? settings['platformFees'] : null;
    final raw = all is Map ? all[source] : null;
    if (raw is! Map) return null; // Unknown ≠ 0% commission.
    final values = [
      raw['commissionPercent'], raw['courierPercent'],
      raw['otherPercent'], raw['feeVatPercent'],
    ];
    if (values.any((v) => v is! num)) return null;
    final numbers = values.cast<num>().map((v) => v.toDouble()).toList();
    if (numbers.any((v) => !v.isFinite || v < 0 || v > 100) ||
        numbers[0] + numbers[1] + numbers[2] > 100 ||
        (numbers[0] + numbers[1] + numbers[2]) *
          (1 + numbers[3] / 100) > 100) return null;
    return DeliveryFeeRate(
      commissionPercent: numbers[0],
      courierPercent: numbers[1],
      otherPercent: numbers[2],
      feeVatPercent: numbers[3],
    );
  }
}

class DeliveryNetEstimate {
  const DeliveryNetEstimate({
    required this.source,
    required this.orders,
    required this.grossCents,
    required this.rate,
  });
  final String source;
  final int orders, grossCents;
  final DeliveryFeeRate? rate;

  int? get commissionCents => rate == null ? null :
    (grossCents * rate!.commissionPercent / 100).round();
  int? get courierCents => rate == null ? null :
    (grossCents * rate!.courierPercent / 100).round();
  int? get otherCents => rate == null ? null :
    (grossCents * rate!.otherPercent / 100).round();
  int? get feeVatCents => rate == null ? null :
    (((commissionCents! + courierCents! + otherCents!) *
      rate!.feeVatPercent) / 100).round();
  int? get estimatedCents => rate == null ? null :
    grossCents - commissionCents! - courierCents! -
      otherCents! - feeVatCents!;
}

/// Count only recorded, delivered, non-demo orders.
/// The amount is the recorded customer/order total (the estimated fee base);
/// real invoices may use a different base after promotions/refunds.
List<DeliveryNetEstimate> deliveryNetEstimates(
  Json state,
  bool Function(String) inPeriod, {
  String source = 'Tümü',
}) {
  final gross = <String, int>{for (final s in deliverySources) s: 0};
  final count = <String, int>{for (final s in deliverySources) s: 0};
  for (final o in asMaps(state['orders'])) {
    final s = (o['source'] ?? '').toString();
    if (s == 'Trendyol Go' || !gross.containsKey(s) ||
        o['cancelled'] == true || o['testPackage'] == true ||
        o['demoRemoteStatus'] != null || o['status'] != 'Delivered' ||
        !inPeriod((o['createdAt'] ?? '').toString())) continue;
    final snap = o['platformSnapshot'];
    final amount = snap is Map && snap['orderTotal'] != null
        ? cents(snap['orderTotal']) : orderTotalCents(o);
    if (amount < 0) continue;
    gross[s] = gross[s]! + amount;
    count[s] = count[s]! + 1;
  }
  for (final o in tgoOrders(state)) {
    if (!tgoCountsAsSale(o) ||
        !inPeriod((o['createdAt'] ?? '').toString())) continue;
    final amount = o['totalCents'];
    if (amount is! int || amount < 0) continue;
    gross['Trendyol Go'] = gross['Trendyol Go']! + amount;
    count['Trendyol Go'] = count['Trendyol Go']! + 1;
  }
  return [
    for (final s in deliverySources)
      if (source == 'Tümü' || source == s)
        DeliveryNetEstimate(
          source: s,
          orders: count[s]!,
          grossCents: gross[s]!,
          rate: DeliveryFeeRate.fromSettings(state, s),
        ),
  ];
}
