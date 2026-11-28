import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/demand_view.dart';

void main() {
  Map<String, dynamic> order(int id, String at, {bool cancelled = false, String source = 'Masa'}) => {
    'id': id, 'source': source, 'createdAt': at, 'cancelled': cancelled, 'payments': [],
    'batches': [{'staffId': 1, 'createdAt': at, 'lines': [{'name': 'x', 'qty': 1, 'price': 100}]}],
  };
  // Friday 2026-11-27 Istanbul; week is Mon 23 – Sun 29.
  const today = '2026-11-27';
  final state = {
    'orders': [
      order(1, '2026-11-27T09:10:00Z'), // Fri 12:10
      order(2, '2026-11-27T09:40:00Z'), // Fri 12:40
      order(3, '2026-11-24T16:00:00Z'), // Tue 19:00
      order(4, '2026-11-27T09:20:00Z', cancelled: true),
      order(5, '2026-11-10T09:00:00Z'), // two weeks ago, Tue 12:00
      order(6, '2026-11-26T21:30:00Z'), // Thu 00:30 Istanbul → Fri 00:30
    ],
  };

  test('week: weekday × Istanbul hour, cancelled left out, peak and busiest day', () {
    final v = demandView(state, 'week', today);
    expect((v['from'], v['to']), ('2026-11-23', '2026-11-29'));
    expect(v['orders'], 4);
    final heat = (v['heatmap'] as List).cast<List>();
    expect(heat[4][12], 2, reason: 'Friday 12:00–13:00');
    expect(heat[1][19], 1);
    expect(heat[4][0], 1, reason: 'late UTC evening is the next Istanbul day');
    expect(v['peak'], {'weekday': 4, 'hour': 12, 'orders': 2});
    expect(v['busiestWeekday'], 4);
    expect((v['perDay'] as List)[4], 3);
  });

  test('last 4 weeks and month windows; unknown range is week', () {
    expect(demandView(state, 'last4', today)['from'], '2026-10-31');
    expect(demandView(state, 'last4', today)['orders'], 5);
    expect(demandView(state, 'month', today)['orders'], 5);
    expect(demandView(state, 'nope', today)['range'], 'week');
    expect(demandView({'orders': []}, 'week', today)['peak'], isNull);
  });
}
