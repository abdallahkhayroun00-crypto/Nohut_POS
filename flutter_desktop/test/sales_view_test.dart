import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/sales_view.dart';

void main() {
  Map<String, dynamic> order(int id, String source, String at, List<(String, int, int)> lines,
      {List<Map<String, dynamic>> payments = const [], bool cancelled = false}) => {
    'id': id, 'source': source, 'createdAt': at, 'cancelled': cancelled, 'payments': payments,
    'batches': [{'staffId': 1, 'createdAt': at, 'lines': [
      for (final (n, q, p) in lines) {'name': n, 'qty': q, 'price': p}]}],
  };
  const today = '2026-11-27'; // Friday
  final state = {
    'orders': [
      order(1, 'Masa', '2026-11-27T09:00:00Z', [('Dürüm', 2, 140), ('Ayran', 2, 35)],
          payments: [{'method': 'Nakit', 'amount': 350, 'createdAt': '2026-11-27T10:00:00Z'}]),
      order(2, 'Gel-Al', '2026-11-27T11:00:00Z', [('Dürüm', 1, 140)],
          payments: [{'method': 'Kart', 'amount': 140, 'createdAt': '2026-11-27T11:05:00Z',
            'refunds': [{'amount': 40, 'createdAt': '2026-11-27T11:30:00Z'}]}]),
      order(3, 'Masa', '2026-11-25T12:00:00Z', [('Humus', 1, 165)],
          payments: [{'method': 'Kart', 'amount': 165, 'createdAt': '2026-11-25T12:30:00Z'}]),
      order(4, 'Masa', '2026-11-27T12:00:00Z', [('Dürüm', 5, 140)], cancelled: true),
      order(5, 'Masa', '2026-11-10T12:00:00Z', [('Dürüm', 1, 140)],
          payments: [{'method': 'Nakit', 'amount': 140, 'createdAt': '2026-11-10T12:30:00Z'}]),
    ],
  };

  test('week: per-day collections, refunds, counts; top products from sold lines', () {
    final v = salesView(state, 'week', today);
    final daily = (v['daily'] as List).cast<Map>();
    expect(daily.map((d) => d['day']).first, '2026-11-23');
    expect(daily.last['day'], today, reason: 'future days of the week are not listed');
    final fri = daily.last;
    expect((fri['cashCents'], fri['cardCents'], fri['refundCents'], fri['netCents']), (35000, 14000, 4000, 45000));
    expect((fri['orderCount'], fri['masaCount'], fri['gelalCount']), (2, 1, 1));
    final totals = v['totals'] as Map;
    expect(totals['netCents'], 45000 + 16500);
    expect(totals['orderCount'], 3);
    expect(totals['averageCents'], 20500);
    final top = (v['topProducts'] as List).cast<Map>();
    expect(top.first, {'name': 'Dürüm', 'qty': 3, 'grossCents': 42000}, reason: 'cancelled order left out');
    expect(top.map((p) => p['name']), ['Dürüm', 'Humus', 'Ayran']);
  });

  test('last 4 weeks includes older days', () {
    expect((salesView(state, 'last4', today)['totals'] as Map)['orderCount'], 4);
    expect((salesView(state, 'last4', today)['daily'] as List).length, 28);
  });
}
