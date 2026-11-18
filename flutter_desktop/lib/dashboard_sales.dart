import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'brand.dart';
import 'order_reporting.dart';
import 'pos_logic.dart';
import 'trendyol_go_readonly.dart';

/// Sales by order creation time, NOT by payment/settlement time.
/// Local Masa/Gel-Al records use their order total, including unpaid amounts.
/// Platform numbers only count delivered live orders; fixtures are excluded.
class DashboardSales extends StatefulWidget {
  const DashboardSales({
    super.key,
    required this.state,
    required this.businessDay,
  });

  final Json state;
  final String businessDay;

  @override
  State<DashboardSales> createState() => _DashboardSalesState();
}

enum _SalesPeriod { daily, weekly, monthly }

class _Channel {
  const _Channel(this.name, this.color, this.icon);

  final String name;
  final Color color;
  final IconData icon;
}

const _channels = <_Channel>[
  _Channel('Masa', Color(0xff184C3A), Icons.table_restaurant_outlined),
  _Channel('Gel-Al', Color(0xff4D7C6D), Icons.shopping_bag_outlined),
  _Channel('Trendyol Go', Color(0xffF27A1A), Icons.delivery_dining_outlined),
  _Channel('Yemeksepeti', Color(0xffE91E63), Icons.restaurant_menu_outlined),
  _Channel('Migros Yemek', Color(0xffEF642B), Icons.storefront_outlined),
];

class _ChannelSale {
  const _ChannelSale(this.channel, this.amount, this.localTime);

  final int channel;
  final int amount;
  final DateTime localTime;
}

class _SalesBucket {
  _SalesBucket(this.label)
      : amounts = List<int>.filled(_channels.length, 0),
        counts = List<int>.filled(_channels.length, 0);

  final String label;
  final List<int> amounts;
  final List<int> counts;

  void add(_ChannelSale sale) {
    amounts[sale.channel] += sale.amount;
    counts[sale.channel]++;
  }

  int total(bool countsMode, Set<int> visible) {
    final list = countsMode ? counts : amounts;
    return visible.fold<int>(0, (sum, index) => sum + list[index]);
  }
}

class _DashboardSalesState extends State<DashboardSales> {
  _SalesPeriod period = _SalesPeriod.daily;
  bool countsMode = false;
  /// 0 is the current period, -1 the previous, and so on.
  int periodOffset = 0;
  final Set<int> visible = {0, 1, 2, 3, 4};

  DateTime get anchor {
    final selected = DateTime.tryParse(widget.businessDay) ?? DateTime.now().toUtc();
    return switch (period) {
      _SalesPeriod.daily => DateTime.utc(
          selected.year, selected.month, selected.day + periodOffset),
      _SalesPeriod.weekly => DateTime.utc(
          selected.year, selected.month,
          selected.day - selected.weekday + 1 + periodOffset * 7),
      _SalesPeriod.monthly => DateTime.utc(
          selected.year, selected.month + periodOffset, 1),
    };
  }

  void _movePeriod(int step) {
    if (periodOffset + step > 0) return;
    setState(() => periodOffset += step);
  }

  void _onSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 110) return;
    _movePeriod(velocity > 0 ? -1 : 1);
  }

  DateTime? _turkeyLocal(Object? timestamp) {
    if (timestamp is! String) return null;
    final parsed = DateTime.tryParse(timestamp);
    if (parsed == null) return null;
    final local = parsed.toUtc().add(const Duration(hours: 3));
    // UTC-shaped calendar value: components represent Türkiye wall time.
    return DateTime.utc(
      local.year, local.month, local.day, local.hour, local.minute,
    );
  }

  List<_ChannelSale> _records() {
    final found = <_ChannelSale>[];
    for (final order in asMaps(widget.state['orders'])) {
      if (order['cancelled'] == true ||
          order['testPackage'] == true ||
          order['demoRemoteStatus'] != null) {
        continue;
      }
      final source = '${order['source'] ?? ''}';
      // Trendyol's real orders live in trendyolGoOrders, not in POS demo.
      if (source == 'Trendyol Go') continue;
      final index = _channels.indexWhere((channel) => channel.name == source);
      if (index < 0) continue;
      // Do not show unaccepted or incomplete future partner orders as sales.
      if (index >= 3 && order['status'] != 'Delivered') continue;
      final local = _turkeyLocal(order['createdAt']);
      if (local == null) continue;
      final snapshot = order['platformSnapshot'];
      final amount = index >= 3 && snapshot is Map
          ? cents(snapshot['orderTotal'])
          : orderTotalCents(order);
      if (amount < 0) continue;
      found.add(_ChannelSale(index, amount, local));
    }
    for (final order in tgoOrders(widget.state)) {
      if (!tgoCountsAsSale(order)) continue;
      final local = _turkeyLocal(order['createdAt']);
      if (local == null) continue;
      final amount = order['totalCents'];
      if (amount is! int || amount < 0) continue;
      found.add(_ChannelSale(2, amount, local));
    }
    return found;
  }

  List<_SalesBucket> _buckets(List<_ChannelSale> records) {
    final target = anchor;
    late final List<_SalesBucket> buckets;
    switch (period) {
      case _SalesPeriod.daily:
        buckets = List.generate(
          24,
          (h) => _SalesBucket(h.toString().padLeft(2, '0')),
        );
      case _SalesPeriod.weekly:
        const names = ['Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt', 'Paz'];
        final start = DateTime.utc(
          target.year, target.month, target.day - target.weekday + 1,
        );
        buckets = List.generate(7, (i) {
          final day = start.add(Duration(days: i));
          return _SalesBucket('${names[i]} ${day.day}');
        });
      case _SalesPeriod.monthly:
        // Rolling twelve-month comparison ending at the selected month.
        // Each backward swipe moves the window one calendar month older.
        const months = [
          'Oca', 'Şub', 'Mar', 'Nis', 'May', 'Haz',
          'Tem', 'Ağu', 'Eyl', 'Eki', 'Kas', 'Ara',
        ];
        buckets = List.generate(12, (i) {
          final month = DateTime.utc(
            target.year, target.month - 11 + i, 1);
          return _SalesBucket('${months[month.month - 1]} '
              '${month.year.toString().substring(2)}');
        });
    }
    final weekStart = DateTime.utc(
      target.year, target.month, target.day - target.weekday + 1,
    );
    for (final record in records) {
      final time = record.localTime;
      int? bucket;
      switch (period) {
        case _SalesPeriod.daily:
          if (time.year == target.year &&
              time.month == target.month &&
              time.day == target.day) {
            bucket = time.hour;
          }
        case _SalesPeriod.weekly:
          final date = DateTime.utc(time.year, time.month, time.day);
          final offset = date.difference(weekStart).inDays;
          if (offset >= 0 && offset < 7) bucket = offset;
        case _SalesPeriod.monthly:
          final windowStart = DateTime.utc(
            target.year, target.month - 11, 1);
          final monthIndex = (time.year - windowStart.year) * 12 +
              time.month - windowStart.month;
          if (monthIndex >= 0 && monthIndex < 12) {
            bucket = monthIndex;
          }
      }
      if (bucket != null) buckets[bucket].add(record);
    }
    return buckets;
  }

  String _periodDescription() {
    final day = anchor;
    switch (period) {
      case _SalesPeriod.daily:
        return '${day.day.toString().padLeft(2, '0')}.' 
            '${day.month.toString().padLeft(2, '0')}.${day.year} · 00:00–23:59';
      case _SalesPeriod.weekly:
        final start = DateTime.utc(day.year, day.month, day.day);
        final end = start.add(const Duration(days: 6));
        String short(DateTime date) =>
            '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}';
        return '${short(start)} – ${short(end)} · Pazartesi–Pazar';
      case _SalesPeriod.monthly:
        const months = [
          'Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran',
          'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık',
        ];
        return '${months[day.month - 1]} ${day.year} · Son 12 ay';
    }
  }

  Widget _sourceCard(_Channel channel, int amount, int count, double width) {
    return SizedBox(
      width: width,
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: const Color(0xffE3E9E3)),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: channel.color.withValues(alpha: 0.11),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(channel.icon, color: channel.color, size: 18),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    channel.name,
                    style: const TextStyle(fontWeight: FontWeight.w700,
                        fontSize: 13, color: NohutBrand.ink),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                formatTry(amount),
                style: const TextStyle(fontWeight: FontWeight.w900,
                    fontSize: 23, color: NohutBrand.green),
              ),
            ),
            const SizedBox(height: 4),
            Text('$count sipariş',
                style: const TextStyle(color: NohutBrand.muted, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _bar(_SalesBucket bucket, int peak, double height) {
    final values = countsMode ? bucket.counts : bucket.amounts;
    final selected = [
      for (var i = 0; i < _channels.length; i++)
        if (visible.contains(i) && values[i] > 0) i,
    ];
    final total = bucket.total(countsMode, visible);
    final filledHeight = peak <= 0 ? 0.0 : total / peak * height;
    final breakdown = selected.isEmpty
        ? 'Sipariş yok'
        : selected.map((i) =>
            '${_channels[i].name}: ${countsMode ? '${values[i]} sipariş' : formatTry(values[i])}'
          ).join('\n');
    return Tooltip(
      waitDuration: const Duration(milliseconds: 250),
      message: '${bucket.label}\n$breakdown',
      child: SizedBox(
        height: height,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: filledHeight <= 0
              ? const SizedBox(width: 26, height: 2)
              : ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: SizedBox(
                    width: period == _SalesPeriod.daily ? 24 : 35,
                    height: math.max(3.0, filledHeight),
                    child: Column(
                      children: [
                        for (final i in selected.reversed)
                          Container(
                            color: _channels[i].color,
                            height: math.max(
                              0, filledHeight * values[i] / total,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _chart(List<_SalesBucket> buckets) {
    const chartHeight = 185.0;
    final peak = buckets.fold<int>(
      0,
      (previous, bucket) =>
          math.max(previous, bucket.total(countsMode, visible)),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final minWidth = switch (period) {
          _SalesPeriod.daily => 24 * 45.0,
          _SalesPeriod.weekly => 7 * 96.0,
          _SalesPeriod.monthly => 12 * 76.0,
        };
        final width = math.max(constraints.maxWidth, minWidth);
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            height: 240,
            child: Stack(
              children: [
                Positioned(
                  top: 24,
                  bottom: 30,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        for (var i = 0; i < 4; i++)
                          const Divider(
                            height: 1,
                            color: Color(0xffE8EDE8),
                          ),
                      ],
                    ),
                  ),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final bucket in buckets)
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            SizedBox(
                              height: 20,
                              child: (period == _SalesPeriod.daily ||
                                      bucket.total(countsMode, visible) == 0)
                                  ? null
                                  : FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        countsMode
                                            ? '${bucket.total(true, visible)}'
                                            : formatTry(bucket.total(false, visible)),
                                        style: const TextStyle(
                                          color: NohutBrand.muted, fontSize: 11,
                                        ),
                                      ),
                                    ),
                            ),
                            const SizedBox(height: 4),
                            _bar(bucket, peak, chartHeight),
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 19,
                              child: Text(
                                bucket.label,
                                style: const TextStyle(
                                  color: NohutBrand.muted, fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final records = _records();
    final today = _SalesBucket('Bugün');
    for (final record in records) {
      if (istanbulDay(record.localTime.subtract(const Duration(hours: 3))) ==
          widget.businessDay) {
        today.add(record);
      }
    }
    final dailyTotal = today.amounts.fold<int>(0, (a, b) => a + b);
    final dailyCount = today.counts.fold<int>(0, (a, b) => a + b);
    final buckets = _buckets(records);
    final selectedTotal = buckets.fold<int>(
      0, (sum, b) => sum + b.total(countsMode, visible),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(19),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 14,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('BUGÜNKÜ TOPLAM',
                        style: TextStyle(
                          color: NohutBrand.muted, fontWeight: FontWeight.w700,
                          letterSpacing: 1.0, fontSize: 11,
                        )),
                    const SizedBox(height: 5),
                    Text(formatTry(dailyTotal),
                        style: const TextStyle(
                          fontSize: 31, fontWeight: FontWeight.w900,
                          color: NohutBrand.green,
                        )),
                    Text('$dailyCount sipariş · ${widget.businessDay}',
                        style: const TextStyle(color: NohutBrand.muted)),
                  ],
                ),
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.query_stats_outlined, color: NohutBrand.green),
                    SizedBox(width: 8),
                    Text('Kaydedilen satış tutarları',
                        style: TextStyle(
                            color: NohutBrand.green,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final columns = width >= 1050 ? 5 : width >= 690 ? 3 : width >= 440 ? 2 : 1;
            final cardWidth = (width - (columns - 1) * 12) / columns;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (var i = 0; i < _channels.length; i++)
                  _sourceCard(
                    _channels[i], today.amounts[i], today.counts[i], cardWidth,
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 14,
                  runSpacing: 12,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragEnd: _onSwipe,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Satış Grafiği',
                              style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 4),
                          Text(_periodDescription(),
                              style: const TextStyle(color: NohutBrand.muted,
                                  fontSize: 12)),
                        ],
                      ),
                    ),
                    SegmentedButton<_SalesPeriod>(
                      showSelectedIcon: false,
                      selected: {period},
                      segments: const [
                        ButtonSegment(value: _SalesPeriod.daily,
                            label: Text('Günlük')),
                        ButtonSegment(value: _SalesPeriod.weekly,
                            label: Text('Haftalık')),
                        ButtonSegment(value: _SalesPeriod.monthly,
                            label: Text('Aylık')),
                      ],
                      onSelectionChanged: (value) => setState(() {
                        period = value.first;
                        periodOffset = 0;
                      }),
                    ),
                    SegmentedButton<bool>(
                      showSelectedIcon: false,
                      selected: {countsMode},
                      segments: const [
                        ButtonSegment(value: false, label: Text('Tutar')),
                        ButtonSegment(value: true, label: Text('Sipariş Adedi')),
                      ],
                      onSelectionChanged: (value) =>
                          setState(() => countsMode = value.first),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    IconButton(
                      key: const ValueKey('chart-previous-period'),
                      tooltip: 'Önceki dönem',
                      onPressed: () => _movePeriod(-1),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragEnd: _onSwipe,
                        child: Column(
                          children: [
                            Text(_periodDescription(),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: NohutBrand.ink)),
                            const Text('Geçmişe kaydırın veya okları kullanın',
                                style: TextStyle(fontSize: 11,
                                    color: NohutBrand.muted)),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('chart-next-period'),
                      tooltip: 'Sonraki dönem',
                      onPressed: periodOffset >= 0
                          ? null : () => _movePeriod(1),
                      icon: const Icon(Icons.chevron_right),
                    ),
                    TextButton(
                      onPressed: periodOffset == 0
                          ? null : () => setState(() => periodOffset = 0),
                      child: const Text('Bugüne dön'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(countsMode ? '$selectedTotal sipariş' : formatTry(selectedTotal),
                        style: const TextStyle(
                          color: NohutBrand.green, fontSize: 22,
                          fontWeight: FontWeight.w900,
                        )),
                    const SizedBox(width: 8),
                    const Text('Seçili kanallar',
                        style: TextStyle(color: NohutBrand.muted, fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragEnd: _onSwipe,
                  child: _chart(buckets),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 7,
                  children: [
                    for (var i = 0; i < _channels.length; i++)
                      FilterChip(
                        showCheckmark: false,
                        avatar: CircleAvatar(
                          radius: 5,
                          backgroundColor: _channels[i].color,
                        ),
                        label: Text(
                          _channels[i].name,
                          style: TextStyle(
                            color: visible.contains(i)
                                ? Colors.white : NohutBrand.ink,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        selected: visible.contains(i),
                        selectedColor: NohutBrand.green,
                        backgroundColor: Colors.white,
                        showCheckmark: false,
                        side: BorderSide(
                          color: visible.contains(i)
                              ? NohutBrand.green
                              : const Color(0xffC8D6CD),
                        ),
                        onSelected: (selected) {
                          if (!selected && visible.length == 1) return;
                          setState(() {
                            if (selected) {
                              visible.add(i);
                            } else {
                              visible.remove(i);
                            }
                          });
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'Yerel kanallar: sipariş açılış tarihine göre toplam tutar '
                  '(tahsilat değildir). Trendyol Go: teslim edilen gerçek siparişler. '
                  'Yemeksepeti ve Migros Yemek: yalnızca kayıtlı, teslim edilmiş '
                  'gerçek siparişler; demo verileri dahil değildir.',
                  style: TextStyle(fontSize: 11, color: NohutBrand.muted),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
