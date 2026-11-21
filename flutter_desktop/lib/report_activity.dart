import 'package:flutter/material.dart';

import 'brand.dart';
import 'operations.dart';
import 'operations_ui.dart';
import 'pos_logic.dart';
import 'trendyol_go_readonly.dart';

class ReportActivity {
  ReportActivity(Json state, bool Function(String) includes, String source) {
    var all = <Json>[
      ...asMaps(state['orders']).where((order) => !isPlatform(order)),
      ...tgoOrders(state).where((order) => order['testPackage'] != true),
    ];
    if (source != 'Tümü')
      all = all.where((order) => order['source'] == source).toList();
    for (final order in all) {
      final status = order['status'];
      if (order['cancelled'] == true ||
          status == 'Cancelled' ||
          status == 'UnSupplied') {
        final stamp =
            '${order['cancelledAt'] ?? order['modifiedAt'] ?? order['createdAt']}';
        if (includes(stamp)) cancellations.add((stamp, order));
        continue;
      }
      if (status == 'Delivered' &&
          includes('${order['modifiedAt'] ?? order['createdAt']}')) {
        onlineSales += order['totalCents'] as int? ?? 0;
        onlineCount++;
        for (final line in asMaps(order['lines'])) {
          final name = '${line['name'] ?? ''}'.trim();
          final qty = line['qty'] as int? ?? 0;
          if (name.isEmpty || qty <= 0) continue;
          onlineProducts.update(
            name,
            (total) => total + qty,
            ifAbsent: () => qty,
          );
        }
      }
      final raw = '${order['createdAt']}';
      final start = DateTime.tryParse(raw);
      if (start != null && includes(raw)) {
        final time = start.toUtc().add(const Duration(hours: 3));
        final bin = time.hour * 2 + time.minute ~/ 30;
        halfHours[bin]++;
        weekdays[time.weekday - 1][time.hour]++;
      }
      final ready = DateTime.tryParse('${order['readyAt']}');
      final prepStart =
          DateTime.tryParse('${order['serviceStartedAt']}') ?? start;
      if (ready != null &&
          prepStart != null &&
          !ready.isBefore(prepStart) &&
          includes('${order['readyAt']}')) {
        prepared.add((ready.difference(prepStart), order));
      }
    }
    cancellations.sort((a, b) => b.$1.compareTo(a.$1));
    prepared.sort((a, b) => b.$1.compareTo(a.$1));
  }

  final halfHours = List.filled(48, 0);
  final weekdays = List.generate(7, (_) => List.filled(24, 0));
  final prepared = <(Duration, Json)>[];
  final cancellations = <(String, Json)>[];
  int onlineSales = 0, onlineCount = 0;
  final onlineProducts = <String, int>{};

  int get orderCount => halfHours.fold(0, (a, b) => a + b);
  int? get prepAverage => prepared.isEmpty
      ? null
      : (prepared.fold(0, (sum, row) => sum + row.$1.inSeconds) /
                prepared.length /
                60)
            .round();

  static String timeSlot(int slot) =>
      '${(slot ~/ 2).toString().padLeft(2, '0')}:${slot.isEven ? '00' : '30'}';

  String get csv =>
      '\uFEFFSaat,Sipariş\r\n${[for (final (i, n) in halfHours.indexed) '${timeSlot(i)},$n'].join('\r\n')}\r\n';
}

class DemandCharts extends StatelessWidget {
  const DemandCharts({super.key, required this.activity, required this.export});
  final ReportActivity activity;
  final VoidCallback export;

  @override
  Widget build(BuildContext context) {
    final maxBin = activity.halfHours.reduce((a, b) => a > b ? a : b);
    final maxHeat = activity.weekdays
        .expand((row) => row)
        .reduce((a, b) => a > b ? a : b);
    const days = ['Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt', 'Paz'];
    Widget body(double width) {
      final unit = (width - 38) / 48;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          panelTitle('30 dakikalık sipariş yoğunluğu'),
          if (maxBin > 0)
            Text(
              'En yoğun dilim · $maxBin sipariş · ${[for (final (i, count) in activity.halfHours.indexed)
                if (count == maxBin) ReportActivity.timeSlot(i)].join(', ')}',
            )
          else
            const Text('Seçilen dönemde sipariş kaydı yok.'),
          const SizedBox(height: 12),
          SizedBox(
            height: 126,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(
                  width: 38,
                  child: Text('$maxBin', textAlign: TextAlign.center),
                ),
                for (final (i, count) in activity.halfHours.indexed)
                  SizedBox(
                    width: unit,
                    child: Tooltip(
                      message: '${ReportActivity.timeSlot(i)} · $count sipariş',
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Container(
                            width: unit - 2,
                            height: count == 0 ? 2 : 96 * count / maxBin,
                            decoration: BoxDecoration(
                              color: count == 0
                                  ? Colors.black12
                                  : NohutBrand.green,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 38),
            child: Row(
              children: [
                for (var h = 0; h < 24; h += 3)
                  Expanded(
                    child: Text(
                      ReportActivity.timeSlot(h * 2),
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          panelTitle('Haftanın günü ve saate göre yoğunluk'),
          const Text(
            'İstanbul saati · Koyu renk daha fazla siparişi gösterir.',
          ),
          const SizedBox(height: 10),
          for (final (d, row) in activity.weekdays.indexed)
            Row(
              children: [
                SizedBox(width: 38, child: Text(days[d])),
                for (final (hour, count) in row.indexed)
                  SizedBox(
                    width: unit * 2,
                    child: Tooltip(
                      message:
                          '${days[d]} ${ReportActivity.timeSlot(hour * 2)} · $count sipariş',
                      child: Container(
                        height: 23,
                        margin: const EdgeInsets.all(1),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(3),
                          color: count == 0
                              ? Colors.black12
                              : NohutBrand.green.withAlpha(
                                  65 + (190 * count / maxHeat).round(),
                                ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, size) => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: size.maxWidth < 548 ? 548 : size.maxWidth,
                  child: body(size.maxWidth < 548 ? 548 : size.maxWidth),
                ),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: export,
              icon: const Icon(Icons.download),
              label: const Text('Yoğunluk CSV'),
            ),
          ],
        ),
      ),
    );
  }
}
