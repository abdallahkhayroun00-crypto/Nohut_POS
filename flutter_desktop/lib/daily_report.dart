/// Gün Sonu Raporu (spec §24.7, task D1).
///
/// A read-only projection of committed Windows data for one business day
/// (Europe/Istanbul). Exact kuruş integers only. Nothing here closes a
/// register, an order or a day; the report is recomputed on every read, so
/// late transactions simply appear the next time it is opened.
///
/// Definitions (shown in the report):
/// * **Brüt Satış** = non-cancelled Masa + Gel-Al order totals created on the
///   day + delivered online orders (platform order total, commission not
///   deducted).
/// * **İadeler** = refunds/reversals of in-store payments booked on the day.
/// * **Net Satış** = Brüt Satış − İadeler.
/// * **Tahsilatlar** are in-store payments received on the day by method; a
///   collection is not a sale (an open table has sales but no collection yet).
///   Platform payouts are never invented: online money is not a collection.
library;

import 'finance_logic.dart' show financeRows;
import 'finance_pdf.dart' show managementReportFacts;
import 'operations.dart' show ledger;
import 'order_reporting.dart' show istanbulDay;
import 'platform_net.dart';
import 'pos_logic.dart';
import 'workforce.dart' show isCalendarDay, istanbulDayOfInstant, workMinutes;
import 'trendyol_go_readonly.dart' show tgoOrders, tgoCountsAsSale;
import 'package:nohut_core/report_period.dart';

const dailyReportCategory = 'report.daily';
const dailyReportTitle = 'Gün Sonu Raporunuz Hazır';
const dailyReportBody = 'Bugünkü restoran performansınızı inceleyin.';
const defaultClosingTime = '21:30';

final _hhmm = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
final _date = RegExp(r'^\d{4}-\d{2}-\d{2}$');

DateTime _istanbul(DateTime instant) => instant.toUtc().add(const Duration(hours: 3));

/// Closing-time schedule kept in `settings.dailyReport`:
/// `{enabled, time, weekdays: {'1'..'7': 'HH:MM'|'closed'}, dates: {'YYYY-MM-DD': 'HH:MM'|'closed'}}`.
class DailyReportSchedule {
  const DailyReportSchedule({this.enabled = true, this.time = defaultClosingTime,
      this.weekdays = const {}, this.dates = const {}});
  final bool enabled;
  final String time;
  final Map<String, String> weekdays, dates;

  static DailyReportSchedule of(Json state) {
    final settings = state['settings'];
    final raw = settings is Map ? settings['dailyReport'] : null;
    if (raw is! Map) return const DailyReportSchedule();
    Map<String, String> pick(Object? m, bool Function(String) key) => {
      if (m is Map)
        for (final e in m.entries)
          if (key('${e.key}') && (e.value == 'closed' || _hhmm.hasMatch('${e.value}')))
            '${e.key}': '${e.value}',
    };
    final time = '${raw['time'] ?? ''}';
    return DailyReportSchedule(
      enabled: raw['enabled'] != false,
      time: _hhmm.hasMatch(time) ? time : defaultClosingTime,
      weekdays: pick(raw['weekdays'], (k) => RegExp(r'^[1-7]$').hasMatch(k)),
      dates: pick(raw['dates'], _date.hasMatch),
    );
  }

  Json toJson() => {'enabled': enabled, 'time': time, 'weekdays': weekdays, 'dates': dates};

  /// Closing time for [day] (`HH:MM`), or null when the restaurant is closed.
  /// A specific date wins over the weekday, which wins over the default.
  String? closingFor(String day) {
    final v = dates[day] ?? weekdays['${DateTime.parse(day).weekday}'] ?? time;
    return v == 'closed' ? null : v;
  }

  /// UTC instant of the closing time on [day], or null when closed.
  DateTime? closingInstant(String day) {
    final t = closingFor(day);
    if (t == null) return null;
    final d = DateTime.parse(day);
    return DateTime.utc(d.year, d.month, d.day, int.parse(t.substring(0, 2)),
        int.parse(t.substring(3))).subtract(const Duration(hours: 3));
  }
}

void saveDailyReportSchedule(Json state, DailyReportSchedule schedule) {
  final settings = state['settings'] is Map ? state['settings'] as Map : (state['settings'] = <String, dynamic>{}) as Map;
  if (!_hhmm.hasMatch(schedule.time)) throw const FormatException('Saat SS:DD olmalı.');
  settings['dailyReport'] = schedule.toJson();
}

/// The one scheduled event for today, once the closing time has passed.
/// Stable id `daily:<day>`: re-deriving after a restart or on another poll
/// never duplicates it. Amounts and names are never in the event.
Json? dailyReportEvent(Json state, DateTime now) {
  final schedule = DailyReportSchedule.of(state);
  if (!schedule.enabled) return null;
  final day = istanbulDay(now);
  final at = schedule.closingInstant(day);
  if (at == null || now.toUtc().isBefore(at)) return null;
  return {
    'eventId': 'daily:$day',
    'category': dailyReportCategory,
    'createdAt': at.toIso8601String(),
    'title': dailyReportTitle,
    'body': dailyReportBody,
    'ref': {'kind': 'dailyReport', 'key': day},
  };
}

int _sum<T>(Iterable<T> rows, int Function(T) f) => rows.fold<int>(0, (n, r) => n + f(r));

/// Builds the report for [day]. [now] decides whether it is still preliminary.
Json buildDailyReport(Json state, String day, {DateTime? now, bool withComparison = true}) {
  if (!_date.hasMatch(day) || !isCalendarDay(day)) throw const FormatException('Tarih geçersiz.');
  final clock = (now ?? DateTime.now()).toUtc();
  final period = ReportPeriod(day, day);
  final schedule = DailyReportSchedule.of(state);
  final facts = managementReportFacts(state, period);
  final valid = (facts['valid'] as List<Json>);
  final cancelled = (facts['orders'] as List<Json>).length - valid.length;
  final products = facts['products'] as Map<String, Json>;

  // Sales: in-store orders.
  final hourly = List<int>.filled(24, 0);
  void atHour(Object? stamp, int amount) {
    final d = DateTime.tryParse('$stamp');
    if (d != null) hourly[_istanbul(d).hour] += amount;
  }
  var localSales = 0;
  for (final o in valid) {
    final t = orderTotalCents(o);
    localSales += t;
    atHour(o['createdAt'], t);
  }
  final masa = valid.where((o) => o['source'] == 'Masa').length;
  final gelAl = valid.where((o) => o['source'] == 'Gel-Al').length;

  // Online: the same delivered-only rule as the finance reports.
  final estimates = deliveryNetEstimates(state, period.includesStamp);
  for (final o in asMaps(state['orders'])) {
    final s = '${o['source'] ?? ''}';
    if (s == 'Trendyol Go' || !deliverySources.contains(s) || o['cancelled'] == true ||
        o['testPackage'] == true || o['demoRemoteStatus'] != null ||
        o['status'] != 'Delivered' || !period.includesStamp(o['createdAt'])) {
      continue;
    }
    final snap = o['platformSnapshot'];
    final amount = snap is Map && snap['orderTotal'] != null ? cents(snap['orderTotal']) : orderTotalCents(o);
    if (amount >= 0) atHour(o['createdAt'], amount);
  }
  for (final o in tgoOrders(state)) {
    if (!tgoCountsAsSale(o) || !period.includesStamp(o['createdAt'])) continue;
    final amount = o['totalCents'];
    if (amount is int && amount >= 0) atHour(o['createdAt'], amount);
  }
  final onlineOrders = _sum(estimates, (e) => e.orderCount);
  final onlineGross = _sum(estimates, (e) => e.grossCents);
  final platforms = [
    for (final e in estimates)
      if (e.orderCount > 0)
        {'source': e.source, 'orders': e.orderCount, 'grossCents': e.grossCents,
         'estimatedNetCents': e.estimatedNetCents},
  ];
  final unpricedPlatform = estimates.any((e) => e.orderCount > 0 && e.deductionPercent == null);

  // Collections (in-store payments) and refunds.
  final payments = ledger(state).where((p) => period.includesStamp(p.stamp) &&
      ['Masa', 'Gel-Al'].contains(p.source)).toList();
  final byMethod = <String, int>{};
  for (final p in payments.where((p) => p.kind == 'Tahsilat')) {
    byMethod[p.method] = (byMethod[p.method] ?? 0) + p.amount;
  }
  final refunds = -_sum(payments.where((p) => p.kind == 'İade'), (p) => p.amount);
  final collected = _sum(byMethod.values, (v) => v);

  // Open accounts: today's in-store orders that still owe money.
  final open = valid.where((o) => o['closed'] != true && orderDueCents(o) > 0).toList();

  // Expenses recorded for the day (materials + other); payroll/fixed are not daily.
  final materials = financeRows(state, 'materials')
      .where((r) => r['date'] == day && r['voided'] != true).toList();
  final other = financeRows(state, 'other')
      .where((r) => r['date'] == day && r['voided'] != true).toList();
  final materialCents = _sum(materials, (r) => (r['totalCents'] as int?) ?? 0);
  final otherCents = _sum(other, (r) => (r['amountCents'] as int?) ?? 0);

  final gross = localSales + onlineGross;
  final net = gross - refunds;
  final orderCount = valid.length + onlineOrders;
  final top = products.entries.toList()
    ..sort((a, b) => (b.value['qty'] as int).compareTo(a.value['qty'] as int));
  var peak = -1;
  for (var h = 0; h < 24; h++) {
    if (hourly[h] > 0 && (peak < 0 || hourly[h] > hourly[peak])) peak = h;
  }

  final today = istanbulDay(clock);
  final closing = schedule.closingInstant(day);
  final trading = day == today && (closing == null ? false : clock.isBefore(closing));
  final preliminary = day.compareTo(today) > 0 || trading || open.isNotEmpty;

  // Estimated result only when every online amount has a known deduction.
  final onlineNet = unpricedPlatform ? null : _sum(estimates, (e) => e.estimatedNetCents ?? 0);
  final estimate = onlineNet == null ? null :
      localSales - refunds + onlineNet - materialCents - otherCents;

  Json? comparison;
  if (withComparison && !preliminary) {
    final prev = ReportPeriod.day(DateTime.parse(day).subtract(const Duration(days: 1)));
    final p = buildDailyReport(state, prev, now: clock, withComparison: false);
    final pNet = (p['sales'] as Map)['netCents'] as int;
    if ((p['orders'] as Map)['total'] as int > 0 && p['closed'] != true) {
      comparison = {'day': prev, 'netCents': pNet, 'diffCents': net - pNet};
    }
  }

  return {
    'businessDate': day,
    'generatedAt': clock.toIso8601String(),
    'closingTime': schedule.closingFor(day),
    'closed': schedule.closingFor(day) == null,
    'preliminary': preliminary,
    'preliminaryReason': !preliminary ? null : trading ? 'İşletme hâlâ açık'
        : open.isNotEmpty ? 'Açık hesaplar var' : 'Gün henüz başlamadı',
    'sales': {
      'grossCents': gross, 'localCents': localSales, 'onlineGrossCents': onlineGross,
      'refundsCents': refunds, 'netCents': net,
      'definition': 'Net Satış = Brüt Satış − İadeler. Online tutarlar platform '
          'sipariş toplamıdır; komisyon düşülmemiştir.',
    },
    'comparison': comparison,
    'hourlyCents': hourly,
    'orders': {
      'total': orderCount, 'masa': masa, 'gelAl': gelAl, 'online': onlineOrders,
      'cancelled': cancelled,
      'averageCents': orderCount == 0 ? null : (gross * 2 + orderCount) ~/ (orderCount * 2),
      'platforms': platforms,
    },
    'collections': {
      'byMethod': [for (final e in byMethod.entries) {'method': e.key, 'cents': e.value}],
      'totalCents': collected,
      'netAfterRefundsCents': collected - refunds,
      'note': 'Online siparişlerin parası platform ödemesiyle gelir; burada tahsilat sayılmaz.',
    },
    'openAccounts': {'count': open.length, 'dueCents': _sum(open, orderDueCents)},
    'expenses': {
      'materialsCents': materialCents, 'otherCents': otherCents,
      'totalCents': materialCents + otherCents, 'count': materials.length + other.length,
    },
    'estimatedResultCents': estimate,
    'estimateNote': estimate == null
        ? 'Bazı platformların kesinti oranı tanımlı değil; tahmini sonuç gösterilmiyor.'
        : 'Tahmini: sabit giderler, maaşlar, vergi ve stok dahil değildir.',
    'topProduct': top.isEmpty ? null :
        {'name': top.first.key, 'qty': top.first.value['qty'], 'cents': top.first.value['amount']},
    'peakHour': peak < 0 ? null : peak,
    // §24.7: manual Mesai records that started this business day (never
    // estimated from planned Vardiya). Totals only, no per-person pay.
    'staffHours': _staffHours(state, day),
  };
}

Json? _staffHours(Json state, String day) {
  var minutes = 0;
  final people = <Object?>{};
  for (final w in asMaps(state['shifts'])) {
    if (w['voided'] == true || w['end'] == null || w['start'] == null) continue;
    final start = DateTime.tryParse('${w['start']}');
    if (start == null || istanbulDayOfInstant(start) != day) continue;
    minutes += workMinutes(w);
    people.add(w['employeeId']);
  }
  return people.isEmpty ? null : {'totalMinutes': minutes, 'people': people.length};
}

/// Removes amounts the viewer may not see (kept: counts, hours, product name).
Json redactDailyReport(Json report, {required bool money, required bool expenses}) {
  final r = copyJson(report);
  if (!money) {
    r.remove('sales');
    r.remove('comparison');
    r.remove('hourlyCents');
    r.remove('collections');
    r.remove('estimatedResultCents');
    (r['orders'] as Map).remove('averageCents');
    for (final p in (r['orders'] as Map)['platforms'] as List) {
      (p as Map)..remove('grossCents')..remove('estimatedNetCents');
    }
    (r['openAccounts'] as Map).remove('dueCents');
    final top = r['topProduct'];
    if (top is Map) top.remove('cents');
    r['amountsHidden'] = true;
  }
  if (!expenses || !money) {
    r.remove('expenses');
    r.remove('estimatedResultCents');
  }
  return r;
}
