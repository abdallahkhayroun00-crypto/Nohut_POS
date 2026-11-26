import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/overview_metrics.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';

// 2026-11-20 is the business day; Istanbul is UTC+3.
String at(String day, int hour, [int minute = 0]) =>
    DateTime.utc(
      int.parse(day.substring(0, 4)),
      int.parse(day.substring(5, 7)),
      int.parse(day.substring(8, 10)),
      hour - 3,
      minute,
    ).toIso8601String();

Json order(
  int id,
  String source,
  String createdAt,
  List<(String, int, int)> lines, {
  bool closed = true,
  bool cancelled = false,
  List<Json> payments = const [],
}) => {
  'id': id,
  'source': source,
  'createdAt': createdAt,
  'closed': closed,
  'cancelled': cancelled,
  'batches': [
    {
      'id': 1,
      'staff': 'Elif',
      'createdAt': createdAt,
      'lines': [
        for (final (name, price, qty) in lines)
          {'productId': 0, 'name': name, 'price': price, 'qty': qty},
      ],
    },
  ],
  'payments': payments,
};

Json pay(String method, int tl, String stamp) =>
    {'method': method, 'amount': tl, 'createdAt': stamp};

void main() {
  const day = '2026-11-20';
  Json state() {
    final s = emptyPosState();
    s['orders'] = [
      order(1, 'Masa', at(day, 10), [('Falafel Dürüm', 160, 2)],
          payments: [pay('Nakit', 320, at(day, 10, 30))]),
      order(2, 'Gel-Al', at(day, 13), [('Humus', 110, 1), ('Ayran', 35, 2)],
          payments: [pay('Kart', 180, at(day, 13, 10))]),
      order(3, 'Masa', at(day, 13, 20), [('Falafel Dürüm', 160, 1)],
          closed: false),
      order(4, 'Masa', at(day, 12), [('Çay', 20, 3)], cancelled: true),
      order(5, 'Masa', at('2026-11-19', 11), [('Falafel Tabağı', 240, 1)]),
      order(6, 'Masa', at('2026-11-19', 18), [('Humus', 110, 4)]),
    ];
    s['trendyolGoOrders'] = [
      {'status': 'Delivered', 'createdAt': at(day, 12), 'totalCents': 50000},
      {'status': 'Created', 'createdAt': at(day, 14), 'totalCents': 9000},
      {'status': 'Delivered', 'testPackage': true,
       'createdAt': at(day, 12), 'totalCents': 99900},
    ];
    s['cashBook'] = {
      'sessions': [
        {'id': 1, 'openedAt': at(day, 9), 'openingCents': 20000,
         'closedAt': null},
      ],
      'movements': [],
      'next': 2,
    };
    return s;
  }

  test('day sales count local totals and delivered platform orders only', () {
    final today = daySales(state(), day);
    expect(today.revenueCents, 32000 + 18000 + 16000 + 50000);
    expect(today.orders, 4);
    expect(today.channelCents['Masa'], 48000);
    expect(today.channelCents['Gel-Al'], 18000);
    expect(today.channelCents['Trendyol Go'], 50000);
    expect(today.averageCents, 29000);
  });

  test('comparison can stop at the same time of day', () {
    final yesterday = daySales(state(), '2026-11-19', untilMinute: 13 * 60);
    expect(yesterday.orders, 1);
    expect(yesterday.revenueCents, 24000);
    expect(percentChange(36000, 24000), closeTo(50, 0.001));
    expect(percentChange(100, 0), isNull);
    expect(shiftDay('2026-03-01', -1), '2026-02-28');
    expect(turkishLongDate('2026-11-26'), '26 Kasım 2026, Perşembe');
  });

  test('collections split cash and card for local orders', () {
    final c = dayCollections(state(), day);
    expect(c.cashCents, 32000);
    expect(c.cardCents, 18000);
    expect(c.refundCents, 0);
  });

  test('top products rank by quantity across local orders', () {
    final top = topProducts(state(), day);
    expect(top.first.name, 'Falafel Dürüm');
    expect(top.first.quantity, 3);
    expect(top.first.cents, 48000);
    expect(top.map((p) => p.name), isNot(contains('Çay')));
  });

  test('live operations show open tables and unpaid amounts', () {
    final live = liveOperations(state(), day);
    expect(live.openTables, 1);
    expect(live.openTableCents, 16000);
    expect(live.unpaidCents, 16000);
    expect(live.openPickups, 0);
    expect(live.onlineNew, 1);
    expect(live.cancelledToday, 1);
  });

  test('peak hour uses arriving orders', () {
    final peak = peakHour(state(), day);
    expect(peak?.hour, 13);
    expect(peak?.orders, 2);
    expect(peakHour(emptyPosState(), day), isNull);
  });
}
