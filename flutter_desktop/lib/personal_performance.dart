/// Performansım (spec §24.3, W5): one employee's own work over a day, week
/// or month, derived from committed POS state. Attribution rules are the
/// same as Windows "Personel Performansı" (`service_metrics.dart`):
///
/// * An order belongs to the person on its first batch (`staffId`).
/// * An addition is a later batch with live lines entered by the person,
///   on any order.
/// * Sales are the totals of the person's own, non-cancelled orders.
/// * Collections are NOT attributed: payments are recorded by the till
///   (`by: Kasa (PC)`), so the reply says so instead of inventing a number.
/// * Hours come only from the person's own Mesai records (never planned
///   Vardiya), using the same `workMinutes` as the weekly view.
///
/// Platform orders, demo/remote placeholders and other people's data are
/// never included.
library;

import 'pos_logic.dart';
import 'workforce.dart';

enum PerformanceRange { day, week, month }

PerformanceRange performanceRangeOf(String? raw) => switch (raw) {
  'week' => PerformanceRange.week,
  'month' => PerformanceRange.month,
  _ => PerformanceRange.day,
};

/// Inclusive [from, to] Istanbul business days for [range] containing [today].
(String, String) performanceWindow(PerformanceRange range, String today) =>
    switch (range) {
      PerformanceRange.day => (today, today),
      PerformanceRange.week => (weekStartOf(today), addDays(weekStartOf(today), 6)),
      PerformanceRange.month => (
        '${today.substring(0, 8)}01',
        addDays('${_nextMonth(today)}-01', -1),
      ),
    };

String _nextMonth(String day) {
  final y = int.parse(day.substring(0, 4)), m = int.parse(day.substring(5, 7));
  final ny = m == 12 ? y + 1 : y, nm = m == 12 ? 1 : m + 1;
  return '$ny-${nm.toString().padLeft(2, '0')}';
}

bool _inWindow(Object? stamp, String from, String to) {
  final t = DateTime.tryParse('${stamp ?? ''}');
  if (t == null) return false;
  final d = istanbulDayOfInstant(t);
  return d.compareTo(from) >= 0 && d.compareTo(to) <= 0;
}

bool _liveLines(Map batch) => asMaps(batch['lines'])
    .any((l) => l['voided'] != true && l['correction'] != true);

Json personalPerformance(Json state, int employeeId, PerformanceRange range,
    String today) {
  final (from, to) = performanceWindow(range, today);
  var orders = 0, tables = 0, pickups = 0, additions = 0, cancelled = 0;
  var salesCents = 0, open = 0;
  final days = <String>{};
  for (final order in asMaps(state['orders'])) {
    if (!['Masa', 'Gel-Al'].contains(order['source']) ||
        order['demoRemoteStatus'] != null) {
      continue;
    }
    final batches = asMaps(order['batches']);
    if (batches.isEmpty) continue;
    final mine = batches.first['staffId'] == employeeId;
    if (mine && _inWindow(order['createdAt'], from, to)) {
      if (order['cancelled'] == true) {
        cancelled++;
      } else {
        orders++;
        if (order['source'] == 'Masa') {
          tables++;
        } else {
          pickups++;
        }
        salesCents += orderTotalCents(order);
        if (order['closed'] != true) open++;
        days.add(istanbulDayOfInstant(DateTime.parse('${order['createdAt']}')));
      }
    }
    if (order['cancelled'] == true) continue;
    for (final b in batches.skip(1)) {
      if (b['staffId'] == employeeId && _liveLines(b) &&
          _inWindow(b['createdAt'], from, to)) {
        additions++;
      }
    }
  }
  var minutes = 0;
  for (final shift in asMaps(state['shifts'])) {
    if (shift['employeeId'] != employeeId) continue;
    if (!_inWindow(shift['start'], from, to)) continue;
    minutes += workMinutes(shift);
  }
  return {
    'range': range.name,
    'from': from,
    'to': to,
    'orders': orders,
    'tables': tables,
    'pickups': pickups,
    'additions': additions,
    'cancelled': cancelled,
    'openOrders': open,
    'salesCents': salesCents,
    'averageCents': orders == 0 ? null : (salesCents * 2 + orders) ~/ (orders * 2),
    'activeDays': days.length,
    'workedMinutes': minutes,
    'collectionsAttributed': false,
    'note': 'Tahsilatlar kasadan kaydedildiği için kişiye atanmaz.',
  };
}
