import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/daily_report_ui.dart';
import 'package:nohut_falafel_desktop/daily_report.dart';
import 'package:nohut_falafel_desktop/finance_logic.dart';
import 'package:nohut_falafel_desktop/notification_events.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/review_sync_service.dart' show notificationsStateKey;

/// Istanbul wall-clock time on [day] as a UTC ISO stamp.
String ist(String day, int h, [int m = 0]) {
  final d = DateTime.parse(day);
  return DateTime.utc(d.year, d.month, d.day, h, m).subtract(const Duration(hours: 3)).toIso8601String();
}

Json order(int id, String source, String at, List<(String, num, int)> lines,
    {List<Json> payments = const [], bool closed = true, bool cancelled = false}) => {
  'id': id, 'source': source, 'table': source == 'Masa' ? 3 : null, 'createdAt': at,
  'closed': closed, 'cancelled': cancelled,
  'batches': [
    {'id': 1, 'createdAt': at, 'staff': 'Ayşe', 'lines': [
      for (final (name, price, qty) in lines) {'name': name, 'price': price, 'qty': qty},
    ]},
  ],
  'payments': payments,
};

void main() {
  const day = '2026-11-20';
  const prev = '2026-11-19';

  Json state() => {
    'settings': <String, dynamic>{},
    'employees': <dynamic>[],
    'orders': [
      // Masa: 2 × 45,50 + 1 × 30 = 121,00, paid 100 cash + 21 card.
      order(1, 'Masa', ist(day, 12, 10), [('Falafel Dürüm', 45.5, 2), ('Ayran', 30, 1)], payments: [
        {'method': 'Nakit', 'amount': 100, 'createdAt': ist(day, 12, 40)},
        {'method': 'Kart', 'amount': 21, 'createdAt': ist(day, 12, 41)},
      ]),
      // Gel-Al: 3 × 45,50 = 136,50, paid cash, then 45,50 refunded.
      order(2, 'Gel-Al', ist(day, 19, 5), [('Falafel Dürüm', 45.5, 3)], payments: [
        {'method': 'Nakit', 'amount': 136.5, 'createdAt': ist(day, 19, 6),
         'refunds': [{'amount': 45.5, 'createdAt': ist(day, 19, 30)}]},
      ]),
      // Open table: 60,00 still owed (partial 20 card).
      order(3, 'Masa', ist(day, 20, 0), [('Humus Tabağı', 40, 2)], closed: false, payments: [
        {'method': 'Kart', 'amount': 20, 'createdAt': ist(day, 20, 30)},
      ]),
      // Cancelled order: not a sale.
      order(4, 'Masa', ist(day, 13, 0), [('Ayran', 30, 5)], cancelled: true),
      // Delivered Yemeksepeti order (platform total 250,00).
      {...order(5, 'Yemeksepeti', ist(day, 19, 45), [('Falafel Menü', 250, 1)]),
       'status': 'Delivered', 'platformSnapshot': {'orderTotal': 250}},
      // Undelivered Migros order: not counted.
      {...order(6, 'Migros Yemek', ist(day, 21, 0), [('Falafel Menü', 200, 1)]), 'status': 'Accepted'},
      // Previous day: 1 × 100.
      order(7, 'Masa', ist(prev, 13, 0), [('Falafel Tabağı', 100, 1)], payments: [
        {'method': 'Nakit', 'amount': 100, 'createdAt': ist(prev, 13, 30)},
      ]),
    ],
  };

  test('sales, collections, refunds and open accounts reconcile in kuruş', () {
    final s = state();
    s['orders'] = (s['orders'] as List).where((o) => o['id'] != 3).toList(); // no open account
    saveQuickMaterialPurchase(s, date: day, storeBrand: 'BİM', amountsCents: [5050, 2000]);
    final r = buildDailyReport(s, day, now: DateTime.parse(ist(day, 23)));
    final sales = r['sales'] as Map;
    expect(sales['localCents'], 12100 + 13650);
    expect(sales['onlineGrossCents'], 25000);
    expect(sales['grossCents'], 12100 + 13650 + 25000);
    expect(sales['refundsCents'], 4550);
    expect(sales['netCents'], 12100 + 13650 + 25000 - 4550);
    // The hourly chart adds up to gross sales exactly.
    expect((r['hourlyCents'] as List<int>).reduce((a, b) => a + b), sales['grossCents']);
    final orders = r['orders'] as Map;
    expect([orders['total'], orders['masa'], orders['gelAl'], orders['online'], orders['cancelled']],
        [3, 1, 1, 1, 1]);
    expect(orders['averageCents'], ((12100 + 13650 + 25000) / 3).round());
    expect((orders['platforms'] as List).single, containsPair('source', 'Yemeksepeti'));
    final col = r['collections'] as Map;
    expect({for (final m in col['byMethod'] as List) m['method']: m['cents']}, {'Nakit': 23650, 'Kart': 2100});
    expect(col['netAfterRefundsCents'], 23650 + 2100 - 4550);
    expect((r['expenses'] as Map)['totalCents'], 7050);
    expect((r['topProduct'] as Map)['name'], 'Falafel Dürüm');
    expect((r['topProduct'] as Map)['qty'], 5);
    expect(r['peakHour'], 19);
    expect(r['preliminary'], false);
    // Platform deduction unknown → no invented estimate.
    expect(r['estimatedResultCents'], isNull);
    expect(r['staffHours'], isNull);
    // Previous day comparable → difference shown.
    expect(r['comparison'], {'day': prev, 'netCents': 10000, 'diffCents': sales['netCents'] - 10000});
  });

  test('preliminary while trading or with open accounts; no comparison then', () {
    final s = state();
    final before = buildDailyReport(s, day, now: DateTime.parse(ist(day, 20, 59)));
    expect(before['preliminary'], true);
    expect(before['preliminaryReason'], 'İşletme hâlâ açık');
    expect(before['comparison'], isNull);
    final after = buildDailyReport(s, day, now: DateTime.parse(ist(day, 23)));
    expect(after['preliminary'], true);
    expect(after['preliminaryReason'], 'Açık hesaplar var');
    expect(after['openAccounts'], {'count': 1, 'dueCents': 6000});
    // A late payment after the report: next read shows it final.
    (s['orders'] as List).firstWhere((o) => o['id'] == 3)
      ..['payments'] = [
        {'method': 'Kart', 'amount': 20, 'createdAt': ist(day, 20, 30)},
        {'method': 'Nakit', 'amount': 60, 'createdAt': ist(day, 22, 10)},
      ]
      ..['closed'] = true;
    final late = buildDailyReport(s, day, now: DateTime.parse(ist(day, 23)));
    expect(late['preliminary'], false);
    expect((late['openAccounts'] as Map)['count'], 0);
  });

  test('estimate only when every platform deduction is known', () {
    final s = state();
    s['settings'] = {'platformDeductionRates': {'Yemeksepeti': 20}};
    final r = buildDailyReport(s, day, now: DateTime.parse(ist(day, 23)));
    final local = 12100 + 13650 + 8000;
    expect(r['estimatedResultCents'], local - 4550 + 20000);
  });

  test('closing time: default 21:30, weekday, special date, closed day', () {
    final s = state();
    expect(dailyReportEvent(s, DateTime.parse(ist(day, 21, 29))), isNull);
    final e = dailyReportEvent(s, DateTime.parse(ist(day, 21, 30)))!;
    expect(e['eventId'], 'daily:$day');
    expect(e['title'], 'Gün Sonu Raporunuz Hazır');
    expect(e['body'], 'Bugünkü restoran performansınızı inceleyin.');
    expect('$e', isNot(contains('₺')));
    saveDailyReportSchedule(s, const DailyReportSchedule(time: '21:30',
        weekdays: {'5': '23:00'}, dates: {'2026-11-21': 'closed', '2026-11-22': '18:00'}));
    expect(DateTime.parse(day).weekday, 5);
    expect(dailyReportEvent(s, DateTime.parse(ist(day, 22))), isNull);
    expect(dailyReportEvent(s, DateTime.parse(ist(day, 23))), isNotNull);
    expect(dailyReportEvent(s, DateTime.parse(ist('2026-11-21', 23, 59))), isNull);
    expect(dailyReportEvent(s, DateTime.parse(ist('2026-11-22', 18, 1)))!['eventId'], 'daily:2026-11-22');
    expect(buildDailyReport(s, '2026-11-21', now: DateTime.parse(ist('2026-11-22', 9)))['closed'], true);
    saveDailyReportSchedule(s, const DailyReportSchedule(enabled: false));
    expect(dailyReportEvent(s, DateTime.parse(ist(day, 23))), isNull);
  });

  test('one notification per business day across polls and restarts', () {
    final dir = Directory.systemTemp.createTempSync('nohut-daily');
    var store = PosStore(databaseFile: '${dir.path}/db');
    addTearDown(() { store.dispose(); dir.deleteSync(recursive: true); });
    final at = DateTime.parse(ist(day, 21, 31));
    expect(recordOperationalNotifications(store, clock: () => at), ['daily:$day']);
    expect(recordOperationalNotifications(store, clock: () => at.add(const Duration(minutes: 5))), isEmpty);
    store.dispose();
    store = PosStore(databaseFile: '${dir.path}/db');
    expect(recordOperationalNotifications(store, clock: () => at.add(const Duration(hours: 1))), isEmpty);
    final rows = (store.read().data[notificationsStateKey] as List).where((r) => r['category'] == 'report.daily');
    expect(rows.length, 1);
    expect(rows.single['permission'], 'sales.view');
  });

  test('redaction removes amounts and expenses by grant', () {
    final r = buildDailyReport(state(), day, now: DateTime.parse(ist(day, 23)));
    final counts = redactDailyReport(r, money: false, expenses: false);
    expect(counts.containsKey('sales'), false);
    expect(counts.containsKey('collections'), false);
    expect(counts.containsKey('expenses'), false);
    expect((counts['orders'] as Map)['total'], 4);
    expect((counts['openAccounts'] as Map).containsKey('dueCents'), false);
    expect('$counts', isNot(contains('Cents: 1')));
    final sales = redactDailyReport(r, money: true, expenses: false);
    expect(sales.containsKey('sales'), true);
    expect(sales.containsKey('expenses'), false);
    expect(sales.containsKey('estimatedResultCents'), false);
  });

  testWidgets('Windows settings: weekday closed and disable', (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
    final s = <String, dynamic>{'settings': <String, dynamic>{}};
    late StateSetter rebuild;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(builder: (c, set) {
      rebuild = set;
      return SingleChildScrollView(child: DailyReportSettings(state: s, edit: (f) { f(s); rebuild(() {}); return true; }));
    }))));
    expect(find.text('21:30'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('daily-report-weekday-7')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kapalı (rapor bildirimi yok)'));
    await tester.pumpAndSettle();
    expect(DailyReportSchedule.of(s).weekdays, {'7': 'closed'});
    expect(find.text('Pazar · Kapalı'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('daily-report-enabled')));
    await tester.pumpAndSettle();
    expect(DailyReportSchedule.of(s).enabled, false);
    expect(tester.takeException(), isNull);
  });

  test('Gün Sonu Raporu has no employee hours (owner decision); impossible dates refused', () {
    final s = state();
    s['shifts'] = [
      {'id': 'mw_a', 'employeeId': 1, 'start': ist(day, 10), 'end': ist(day, 18), 'breakMinutes': 30},
    ];
    final r = buildDailyReport(s, day, now: DateTime.parse(ist(day, 23)));
    expect(r.containsKey('staffHours'), false);
    expect('$r', isNot(contains('mw_a')));
    expect(() => buildDailyReport(s, '2026-02-31'), throwsFormatException);
  });
}
