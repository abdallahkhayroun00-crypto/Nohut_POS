import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/tables_panel.dart';

Json order(int id, String source, String createdAt, {
  bool closed = false,
  bool cancelled = false,
  List<Json> payments = const [],
}) => {
  'id': id,
  'source': source,
  'table': source == 'Masa' ? id : null,
  'createdAt': createdAt,
  'closed': closed,
  'cancelled': cancelled,
  'batches': [
    {
      'id': 1,
      'staff': 'Elif',
      'lines': [
        {'name': 'Falafel Dürüm', 'price': 160, 'qty': 2},
        {'name': 'Ayran', 'price': 35, 'qty': 1},
        {'name': 'Humus', 'price': 110, 'qty': 1},
        {'name': 'Çay', 'price': 20, 'qty': 3},
      ],
    },
  ],
  'payments': payments,
};

void main() {
  test('durations and item summaries read naturally', () {
    expect(durationLabel(35), '35 dk');
    expect(durationLabel(125), '2 sa 05 dk');
    final o = order(1, 'Masa', '2026-11-20T10:00:00Z');
    expect(itemCount(o), 7);
    expect(itemsSummary(o), '2× Falafel Dürüm, 1× Ayran, 1× Humus, +1 ürün');
    expect(openMinutes(o, DateTime.utc(2026, 11, 20, 10, 42)), 42);
    expect(openMinutes(o, DateTime.utc(2026, 11, 20, 9)), 0);
  });

  test('open local orders exclude closed and cancelled, oldest first', () {
    final s = emptyPosState();
    s['orders'] = [
      order(2, 'Masa', '2026-11-20T11:00:00Z'),
      order(1, 'Masa', '2026-11-20T10:00:00Z'),
      order(3, 'Masa', '2026-11-20T09:00:00Z', closed: true),
      order(4, 'Masa', '2026-11-20T09:00:00Z', cancelled: true),
      order(5, 'Gel-Al', '2026-11-20T09:30:00Z'),
    ];
    expect(openLocalOrders(s, 'Masa').map((o) => o['id']), [1, 2]);
    expect(openLocalOrders(s, 'Gel-Al').map((o) => o['id']), [5]);
  });

  test('status labels follow payment state', () {
    const at = '2026-11-20T10:00:00Z';
    expect(localStatusStyle(order(1, 'Masa', at)).$1, 'Açık');
    expect(localStatusStyle(order(1, 'Masa', at, payments: [
      {'method': 'Nakit', 'amount': 100},
    ])).$1, 'Kısmi ödendi');
    expect(localStatusStyle(order(1, 'Masa', at, payments: [
      {'method': 'Kart', 'amount': 525},
    ])).$1, 'Ödendi');
    expect(localStatusStyle(order(1, 'Masa', at, closed: true)).$1, 'Kapalı');
    expect(localStatusStyle(order(1, 'Masa', at, cancelled: true)).$1, 'İptal');
  });
}
