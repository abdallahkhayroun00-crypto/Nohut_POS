import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/personal_performance.dart';

void main() {
  const me = 7, other = 8;
  Map<String, dynamic> order(int id, String source, int owner, String at,
      {List<Map<String, dynamic>> extra = const [], bool cancelled = false, bool closed = false,
       int price = 100}) => {
    'id': id, 'source': source, 'createdAt': at, 'cancelled': cancelled, 'closed': closed,
    'payments': [],
    'batches': [
      {'id': 1, 'staffId': owner, 'createdAt': at, 'lines': [{'name': 'x', 'qty': 1, 'price': price}]},
      ...extra,
    ],
  };
  // Friday 2026-11-27 Istanbul.
  const today = '2026-11-27';
  final state = {
    'orders': [
      order(1, 'Masa', me, '2026-11-27T08:00:00Z', price: 200, closed: true),
      order(2, 'Gel-Al', me, '2026-11-27T09:00:00Z', price: 100),
      // Someone else's order to which I added a round; it is not my sale.
      order(3, 'Masa', other, '2026-11-27T10:00:00Z', extra: [
        {'id': 2, 'staffId': me, 'createdAt': '2026-11-27T10:30:00Z',
         'lines': [{'name': 'y', 'qty': 1, 'price': 50}]},
        {'id': 3, 'staffId': me, 'createdAt': '2026-11-27T10:40:00Z',
         'lines': [{'name': 'z', 'qty': 1, 'price': 50, 'voided': true}]},
      ]),
      order(4, 'Masa', me, '2026-11-27T11:00:00Z', cancelled: true),
      order(5, 'Masa', me, '2026-11-24T11:00:00Z', price: 300, closed: true), // Tuesday
      order(6, 'Masa', me, '2026-11-02T11:00:00Z', price: 400, closed: true), // same month
      {'id': 9, 'source': 'Trendyol Go', 'createdAt': '2026-11-27T08:00:00Z',
       'batches': [{'staffId': me, 'lines': []}]},
      // Late evening UTC that is already the next Istanbul day.
      order(10, 'Masa', me, '2026-11-26T22:30:00Z', price: 10, closed: true),
    ],
    'shifts': [
      {'employeeId': me, 'start': '2026-11-27T06:00:00Z', 'end': '2026-11-27T14:00:00Z', 'breakMinutes': 30},
      {'employeeId': me, 'start': '2026-11-26T06:00:00Z', 'end': '2026-11-26T08:00:00Z', 'voided': true},
      {'employeeId': other, 'start': '2026-11-27T06:00:00Z', 'end': '2026-11-27T14:00:00Z'},
    ],
  };

  test('day: own orders, additions on others, no platform, no collections', () {
    final p = personalPerformance(state, me, PerformanceRange.day, today);
    expect(p['orders'], 3); // 1, 2, 10
    expect((p['tables'], p['pickups'], p['cancelled']), (2, 1, 1));
    expect(p['additions'], 1, reason: 'voided-only round does not count');
    expect(p['salesCents'], 31000);
    expect(p['openOrders'], 1);
    expect(p['workedMinutes'], 450);
    expect(p['collectionsAttributed'], isFalse);
    expect(p.containsKey('collectionsCents'), isFalse);
  });

  test('week and month windows', () {
    expect(performanceWindow(PerformanceRange.week, today), ('2026-11-23', '2026-11-29'));
    expect(performanceWindow(PerformanceRange.month, '2026-12-15'), ('2026-12-01', '2026-12-31'));
    expect(personalPerformance(state, me, PerformanceRange.week, today)['salesCents'], 61000);
    expect(personalPerformance(state, me, PerformanceRange.month, today)['salesCents'], 101000);
  });

  test('another person sees only their own numbers', () {
    final p = personalPerformance(state, other, PerformanceRange.day, today);
    expect((p['orders'], p['additions'], p['workedMinutes']), (1, 0, 480));
  });
}
