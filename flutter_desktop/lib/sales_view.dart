/// Satış Analizi for the Yönetici apps (checklist "sales analytics"; PWA
/// `SalesView`): per Istanbul day, the till's own Masa/Gel-Al collections
/// (cash, card, refunds) and order counts, the best-selling products and
/// online platform totals, over the same windows as Yoğunluk. Built from the
/// same rows as Windows Raporlar ([ledger], [sales], [ReportActivity]), so
/// the numbers match. Amounts: callers gate it behind `sales.view`.
library;

import 'demand_view.dart' show demandRanges, demandWindow;
import 'operations.dart';
import 'order_reporting.dart' show istanbulDay;
import 'pos_logic.dart';
import 'report_activity.dart';
import 'workforce.dart' show addDays;

String? _dayOf(String raw) {
  final t = DateTime.tryParse(raw);
  return t == null ? null : istanbulDay(t);
}

Json salesView(Json state, String range, String today, {int top = 10}) {
  final r = demandRanges.contains(range) ? range : 'week';
  final (from, to) = demandWindow(r, today);
  bool inside(String? d) => d != null && d.compareTo(from) >= 0 && d.compareTo(to) <= 0;
  final last = to.compareTo(today) > 0 ? today : to;
  final days = <String, Json>{};
  for (var d = from; d.compareTo(last) <= 0; d = addDays(d, 1)) {
    days[d] = {'day': d, 'cashCents': 0, 'cardCents': 0, 'otherCents': 0, 'refundCents': 0,
      'netCents': 0, 'orderCount': 0, 'masaCount': 0, 'gelalCount': 0};
  }
  for (final e in ledger(state)) {
    if (!const ['Masa', 'Gel-Al'].contains(e.source)) continue;
    final d = _dayOf(e.stamp);
    if (!inside(d) || days[d] == null) continue;
    final row = days[d]!;
    if (e.amount < 0) {
      row['refundCents'] = (row['refundCents'] as int) - e.amount;
    } else {
      final key = e.method == 'Nakit' ? 'cashCents' : e.method == 'Kart' ? 'cardCents' : 'otherCents';
      row[key] = (row[key] as int) + e.amount;
    }
    row['netCents'] = (row['netCents'] as int) + e.amount;
  }
  for (final o in asMaps(state['orders'])) {
    if (!const ['Masa', 'Gel-Al'].contains(o['source']) || o['cancelled'] == true ||
        o['demoRemoteStatus'] != null) {
      continue;
    }
    final d = _dayOf('${o['createdAt']}');
    if (!inside(d) || days[d] == null) continue;
    final row = days[d]!;
    row['orderCount'] = (row['orderCount'] as int) + 1;
    final k = o['source'] == 'Masa' ? 'masaCount' : 'gelalCount';
    row[k] = (row[k] as int) + 1;
  }
  final products = <String, (int, int)>{};
  for (final s in sales(state)) {
    if (!const ['Masa', 'Gel-Al'].contains(s.source) || !inside(_dayOf(s.stamp))) continue;
    final old = products[s.product] ?? (0, 0);
    products[s.product] = (old.$1 + s.quantity, old.$2 + s.amount);
  }
  final ranked = products.entries.toList()
    ..sort((a, b) {
      final byAmount = b.value.$2.compareTo(a.value.$2);
      return byAmount != 0 ? byAmount : a.key.compareTo(b.key);
    });
  final activity = ReportActivity(state, (raw) => inside(_dayOf(raw)), 'Tümü');
  final daily = days.values.toList();
  int sum(String k) => daily.fold<int>(0, (n, row) => n + (row[k] as int));
  final orders = sum('orderCount');
  final net = sum('netCents');
  return {
    'range': r,
    'from': from,
    'to': to,
    'daily': daily,
    'totals': {
      'netCents': net, 'cashCents': sum('cashCents'), 'cardCents': sum('cardCents'),
      'otherCents': sum('otherCents'), 'refundCents': sum('refundCents'),
      'orderCount': orders, 'masaCount': sum('masaCount'), 'gelalCount': sum('gelalCount'),
      'averageCents': orders == 0 ? null : (net * 2 + orders) ~/ (orders * 2),
    },
    'topProducts': [
      for (final e in ranked.take(top)) {'name': e.key, 'qty': e.value.$1, 'grossCents': e.value.$2},
    ],
    'online': {'orders': activity.onlineCount, 'grossCents': activity.onlineSales},
    'note': 'Tahsilatlar kasadaki Masa ve Gel-Al ödemeleridir; online platform satışları ayrı gösterilir.',
  };
}
