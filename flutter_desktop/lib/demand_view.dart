/// Yoğunluk for the Yönetici apps (checklist "sales analytics and Yoğunluk
/// heatmaps"): the same weekday × hour counts Windows Raporlar › Yoğunluk
/// shows ([ReportActivity]), for this week, the last 4 weeks or this month.
/// Counts only: no amounts, no people, so it needs `dashboard.view` only.
library;

import 'order_reporting.dart' show istanbulDay;
import 'personal_performance.dart' show performanceWindow, PerformanceRange;
import 'pos_logic.dart';
import 'report_activity.dart';
import 'workforce.dart' show addDays;

const demandRanges = ['week', 'last4', 'month'];

(String, String) demandWindow(String range, String today) => switch (range) {
  'last4' => (addDays(today, -27), today),
  'month' => performanceWindow(PerformanceRange.month, today),
  _ => performanceWindow(PerformanceRange.week, today),
};

Json demandView(Json state, String range, String today) {
  final r = demandRanges.contains(range) ? range : 'week';
  final (from, to) = demandWindow(r, today);
  bool includes(String raw) {
    final t = DateTime.tryParse(raw);
    if (t == null) return false;
    final d = istanbulDay(t);
    return d.compareTo(from) >= 0 && d.compareTo(to) <= 0;
  }
  final a = ReportActivity(state, includes, 'Tümü');
  var peakDay = -1, peakHour = -1, peak = 0;
  for (var d = 0; d < 7; d++) {
    for (var h = 0; h < 24; h++) {
      if (a.weekdays[d][h] > peak) {
        peak = a.weekdays[d][h];
        peakDay = d;
        peakHour = h;
      }
    }
  }
  final perDay = [for (final row in a.weekdays) row.fold<int>(0, (n, v) => n + v)];
  var busiest = -1;
  for (var d = 0; d < 7; d++) {
    if (perDay[d] > 0 && (busiest < 0 || perDay[d] > perDay[busiest])) busiest = d;
  }
  return {
    'range': r,
    'from': from,
    'to': to,
    'orders': a.orderCount,
    'heatmap': [for (final row in a.weekdays) [...row]],
    'perDay': perDay,
    'halfHours': [...a.halfHours],
    'peak': peak == 0 ? null : {'weekday': peakDay, 'hour': peakHour, 'orders': peak},
    'busiestWeekday': busiest < 0 ? null : busiest,
    'note': 'İptal edilenler hariç; masa, gel-al ve online siparişler dahil.',
  };
}
