import 'operations.dart';
import 'order_reporting.dart';
import 'pos_logic.dart';
import 'trendyol_go_readonly.dart';

/// Sales for one Istanbul business day, counted the same way as the
/// dashboard chart: local Masa/Gel-Al orders by order total at creation time
/// (including unpaid amounts) and only delivered, non-test platform orders.
class DaySales {
  const DaySales({
    required this.revenueCents,
    required this.orders,
    required this.channelCents,
    required this.channelOrders,
  });
  final int revenueCents, orders;
  final Map<String, int> channelCents, channelOrders;
  int get averageCents => orders == 0 ? 0 : (revenueCents / orders).round();
}

const overviewChannels = [
  'Masa', 'Gel-Al', 'Trendyol Go', 'Yemeksepeti', 'Migros Yemek',
];

DateTime _istanbulWall(DateTime instant) =>
    instant.toUtc().add(const Duration(hours: 3));

/// Minutes since Istanbul midnight for [instant].
int istanbulMinuteOfDay(DateTime instant) {
  final wall = _istanbulWall(instant);
  return wall.hour * 60 + wall.minute;
}

/// [untilMinute] limits the day to orders created before that Istanbul
/// wall-clock minute, so "today so far" can be compared with the same hours
/// of an earlier day.
DaySales daySales(Json state, String day, {int? untilMinute}) {
  final cents = {for (final c in overviewChannels) c: 0};
  final counts = {for (final c in overviewChannels) c: 0};
  bool include(Object? stamp) {
    final instant = DateTime.tryParse('$stamp');
    if (instant == null || istanbulDay(instant) != day) return false;
    return untilMinute == null || istanbulMinuteOfDay(instant) < untilMinute;
  }
  void add(String channel, int amount) {
    cents[channel] = cents[channel]! + amount;
    counts[channel] = counts[channel]! + 1;
  }
  for (final o in asMaps(state['orders'])) {
    if (o['cancelled'] == true || o['testPackage'] == true ||
        o['demoRemoteStatus'] != null) {
      continue;
    }
    final source = '${o['source'] ?? ''}';
    if (source == 'Trendyol Go' || !cents.containsKey(source)) continue;
    final platform = source != 'Masa' && source != 'Gel-Al';
    if (platform && o['status'] != 'Delivered') continue;
    if (!include(o['createdAt'])) continue;
    final amount = orderTotalCents(o);
    if (amount >= 0) add(source, amount);
  }
  for (final o in tgoOrders(state)) {
    if (!tgoCountsAsSale(o) || !include(o['createdAt'])) continue;
    final amount = o['totalCents'];
    if (amount is int && amount >= 0) add('Trendyol Go', amount);
  }
  return DaySales(
    revenueCents: cents.values.fold(0, (a, b) => a + b),
    orders: counts.values.fold(0, (a, b) => a + b),
    channelCents: cents,
    channelOrders: counts,
  );
}

/// Percentage change, or null when there is nothing to compare against.
double? percentChange(int current, int previous) =>
    previous <= 0 ? null : (current - previous) / previous * 100;

String shiftDay(String day, int days) {
  final parsed = DateTime.parse(day);
  final shifted = DateTime.utc(parsed.year, parsed.month, parsed.day + days);
  return shifted.toIso8601String().substring(0, 10);
}

/// Cash and card collected on [day] for local orders, net of refunds.
({int cashCents, int cardCents, int refundCents}) dayCollections(
  Json state,
  String day,
) {
  var cash = 0, card = 0, refunds = 0;
  for (final e in ledger(state)) {
    if (e.source != 'Masa' && e.source != 'Gel-Al') continue;
    final instant = DateTime.tryParse(e.stamp);
    if (instant == null || istanbulDay(instant) != day) continue;
    if (e.amount < 0) refunds += -e.amount;
    if (e.method == 'Nakit') cash += e.amount;
    if (e.method == 'Kart') card += e.amount;
  }
  return (cashCents: cash, cardCents: card, refundCents: refunds);
}

class ProductSales {
  const ProductSales(this.name, this.quantity, this.cents);
  final String name;
  final int quantity, cents;
}

/// Best-selling local products on [day], by quantity then amount.
List<ProductSales> topProducts(Json state, String day, {int limit = 5}) {
  final qty = <String, int>{}, amount = <String, int>{};
  for (final s in sales(state)) {
    if (s.source != 'Masa' && s.source != 'Gel-Al') continue;
    final instant = DateTime.tryParse(s.stamp);
    if (instant == null || istanbulDay(instant) != day) continue;
    qty[s.product] = (qty[s.product] ?? 0) + s.quantity;
    amount[s.product] = (amount[s.product] ?? 0) + s.amount;
  }
  final rows = [
    for (final name in qty.keys) ProductSales(name, qty[name]!, amount[name]!),
  ]..sort((a, b) => b.quantity != a.quantity
      ? b.quantity.compareTo(a.quantity)
      : b.cents.compareTo(a.cents));
  return rows.take(limit).toList();
}

/// What needs attention right now.
class LiveOperations {
  const LiveOperations({
    required this.openTables,
    required this.openTableCents,
    required this.openPickups,
    required this.unpaidCents,
    required this.onlineNew,
    required this.onlinePreparing,
    required this.onlineReady,
    required this.cashOpen,
    required this.cashInDrawerCents,
    required this.cancelledToday,
  });
  final int openTables, openTableCents, openPickups, unpaidCents;
  final int onlineNew, onlinePreparing, onlineReady;
  final bool cashOpen;
  final int? cashInDrawerCents;
  final int cancelledToday;
}

LiveOperations liveOperations(Json state, String day) {
  var tables = 0, tableCents = 0, pickups = 0, unpaid = 0, cancelled = 0;
  for (final o in asMaps(state['orders'])) {
    final source = o['source'];
    if (source != 'Masa' && source != 'Gel-Al') continue;
    if (o['cancelled'] == true) {
      final instant = DateTime.tryParse('${o['createdAt']}');
      if (instant != null && istanbulDay(instant) == day) cancelled++;
      continue;
    }
    if (o['closed'] == true) continue;
    final due = orderDueCents(o);
    unpaid += due;
    if (source == 'Masa') {
      tables++;
      tableCents += orderTotalCents(o);
    } else {
      pickups++;
    }
  }
  var fresh = 0, picking = 0, ready = 0;
  for (final o in tgoOrders(state)) {
    if (o['testPackage'] == true) continue;
    switch (o['status']) {
      case 'Created': fresh++;
      case 'Picking': picking++;
      case 'Invoiced': ready++;
    }
  }
  final cash = activeCash(state);
  return LiveOperations(
    openTables: tables,
    openTableCents: tableCents,
    openPickups: pickups,
    unpaidCents: unpaid,
    onlineNew: fresh,
    onlinePreparing: picking,
    onlineReady: ready,
    cashOpen: cash != null,
    cashInDrawerCents: cash == null ? null : expectedCash(state, cash),
    cancelledToday: cancelled,
  );
}

/// Busiest Istanbul hour on [day] by arriving orders, or null when empty.
({int hour, int orders})? peakHour(Json state, String day) {
  final counts = hourlyOrderCounts(
    [...asMaps(state['orders']).where((o) => o['source'] != 'Trendyol Go'),
     ...tgoOrders(state).where((o) => o['testPackage'] != true &&
        !const ['Cancelled', 'UnSupplied'].contains(o['status']))],
    from: day, to: day,
  );
  var best = -1;
  for (var h = 0; h < 24; h++) {
    if (counts[h] > 0 && (best < 0 || counts[h] > counts[best])) best = h;
  }
  return best < 0 ? null : (hour: best, orders: counts[best]);
}

const _months = ['Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran',
  'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık'];
const _weekdays = ['Pazartesi', 'Salı', 'Çarşamba', 'Perşembe', 'Cuma',
  'Cumartesi', 'Pazar'];

/// "2026-11-26" → "26 Kasım 2026, Perşembe".
String turkishLongDate(String day) {
  final d = DateTime.tryParse(day);
  if (d == null) return day;
  return '${d.day} ${_months[d.month - 1]} ${d.year}, ${_weekdays[d.weekday - 1]}';
}
