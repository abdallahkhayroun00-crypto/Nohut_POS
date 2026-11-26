import 'package:flutter/material.dart';

import 'brand.dart';
import 'order_reporting.dart';
import 'pos_logic.dart';

const _border = Color(0xffE1E7E3);

/// Minutes since the order was opened.
int openMinutes(Json order, DateTime now) {
  final created = DateTime.tryParse('${order['createdAt']}');
  if (created == null) return 0;
  final minutes = now.toUtc().difference(created.toUtc()).inMinutes;
  return minutes < 0 ? 0 : minutes;
}

String durationLabel(int minutes) => minutes < 60
    ? '$minutes dk'
    : '${minutes ~/ 60} sa ${(minutes % 60).toString().padLeft(2, '0')} dk';

int itemCount(Json order) => activeLines(order).fold<int>(
  0, (sum, l) => sum + (l['qty'] is num ? (l['qty'] as num).toInt() : 0));

/// "2× Falafel Dürüm, 1× Ayran" (first [limit] lines, then "+n").
String itemsSummary(Json order, {int limit = 3}) {
  final lines = activeLines(order);
  final shown = lines.take(limit).map((l) => '${l['qty']}× ${l['name']}');
  final more = lines.length - limit;
  return [...shown, if (more > 0) '+$more ürün'].join(', ');
}

/// Local (Masa/Gel-Al) orders that are still open, oldest first.
List<Json> openLocalOrders(Json state, String source) => asMaps(state['orders'])
    .where((o) => o['source'] == source && o['closed'] != true &&
        o['cancelled'] != true)
    .toList()
  ..sort((a, b) => '${a['createdAt']}'.compareTo('${b['createdAt']}'));

/// Status pill for a local order row.
(String, Color, Color) localStatusStyle(Json order) {
  if (order['cancelled'] == true) {
    return ('İptal', const Color(0xff8d3930), const Color(0xfff6e6e3));
  }
  if (order['closed'] == true) {
    return ('Kapalı', NohutBrand.muted, const Color(0xffeeeeea));
  }
  if (orderDueCents(order) == 0) {
    return ('Ödendi', const Color(0xff2C6E86), const Color(0xffE3F1F5));
  }
  if (orderPaidCents(order) > 0) {
    return ('Kısmi ödendi', const Color(0xff765720), const Color(0xfff7ecd4));
  }
  return ('Açık', const Color(0xff765720), const Color(0xfffff1d6));
}

class StatusPill extends StatelessWidget {
  const StatusPill(this.style, {super.key, this.width});
  final (String, Color, Color) style;
  final double? width;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    alignment: Alignment.center,
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: style.$3, borderRadius: BorderRadius.circular(14)),
    child: Text(style.$1, maxLines: 1, overflow: TextOverflow.ellipsis,
      style: TextStyle(color: style.$2, fontWeight: FontWeight.w700,
        fontSize: 12)),
  );
}

/// Four quick numbers above the floor plan.
class TablesSummaryStrip extends StatelessWidget {
  const TablesSummaryStrip({super.key, required this.state, required this.now});
  final Json state;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final tables = openLocalOrders(state, 'Masa');
    final pickups = openLocalOrders(state, 'Gel-Al');
    final due = [...tables, ...pickups]
        .fold<int>(0, (sum, o) => sum + orderDueCents(o));
    final longest = tables.isEmpty ? null : tables.first;
    final items = [
      (Icons.table_restaurant_outlined, 'Dolu Masa',
        '${tables.length} / 5', '${5 - tables.length} boş masa'),
      (Icons.shopping_bag_outlined, 'Açık Gel-Al', '${pickups.length}',
        pickups.isEmpty ? 'Bekleyen paket yok' : 'Hazırlanan / ödeme bekleyen'),
      (Icons.payments_outlined, 'Tahsil Edilecek', formatTry(due),
        'Açık masa ve Gel-Al kalanı'),
      (Icons.timer_outlined, 'En Uzun Oturan',
        longest == null ? '—' : durationLabel(openMinutes(longest, now)),
        longest == null ? 'Açık masa yok' : 'Masa ${longest['table']}'),
    ];
    return LayoutBuilder(builder: (context, box) {
      final columns = box.maxWidth >= 900 ? 4 : 2;
      final width = (box.maxWidth - 12 * (columns - 1)) / columns;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final (icon, label, value, note) in items)
            SizedBox(
              width: width,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _border),
                ),
                child: Row(children: [
                  Container(
                    width: 38, height: 38,
                    decoration: BoxDecoration(
                      color: NohutBrand.green.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10)),
                    child: Icon(icon, size: 20, color: NohutBrand.green),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: const TextStyle(fontSize: 12,
                          color: NohutBrand.muted, fontWeight: FontWeight.w600)),
                        Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 19,
                            fontWeight: FontWeight.w800)),
                        Text(note, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5,
                            color: NohutBrand.muted)),
                      ],
                    ),
                  ),
                ]),
              ),
            ),
        ],
      );
    });
  }
}

/// Side list of open tables and waiting Gel-Al orders.
class OpenOrdersPanel extends StatelessWidget {
  const OpenOrdersPanel({
    super.key,
    required this.state,
    required this.now,
    required this.onOpenTable,
    required this.onOpenOrder,
    required this.onPrintBill,
  });
  final Json state;
  final DateTime now;
  final ValueChanged<int> onOpenTable;
  final ValueChanged<Json> onOpenOrder, onPrintBill;

  @override
  Widget build(BuildContext context) {
    final tables = openLocalOrders(state, 'Masa');
    final pickups = openLocalOrders(state, 'Gel-Al');
    Widget section(String title, int count) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Row(children: [
        Text(title, style: const TextStyle(fontSize: 15,
          fontWeight: FontWeight.w800)),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: count == 0 ? const Color(0xffEEF2EF) : NohutBrand.green,
            borderRadius: BorderRadius.circular(12)),
          child: Text('$count', style: TextStyle(fontSize: 12,
            fontWeight: FontWeight.w800,
            color: count == 0 ? NohutBrand.muted : Colors.white)),
        ),
      ]),
    );
    Widget empty(String text) => Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border)),
      child: Text(text, style: const TextStyle(color: NohutBrand.muted,
        fontSize: 12.5)),
    );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xffF4F6F2),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          section('Açık Masalar', tables.length),
          if (tables.isEmpty) empty('Tüm masalar boş'),
          for (final o in tables) ...[
            _OpenOrderCard(
              order: o,
              title: 'Masa ${o['table']}',
              now: now,
              onOpen: () => onOpenTable(o['table'] as int),
              onPrint: () => onPrintBill(o),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 8),
          section('Bekleyen Gel-Al', pickups.length),
          if (pickups.isEmpty) empty('Bekleyen Gel-Al siparişi yok'),
          for (final o in pickups) ...[
            _OpenOrderCard(
              order: o,
              title: () {
                final name = o['customer'] is Map
                    ? '${(o['customer'] as Map)['name'] ?? ''}'.trim() : '';
                return 'Gel-Al #${displayOrderNumber(o)}'
                    '${name.isEmpty ? '' : ' · $name'}';
              }(),
              now: now,
              onOpen: () => onOpenOrder(o),
              onPrint: () => onPrintBill(o),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _OpenOrderCard extends StatelessWidget {
  const _OpenOrderCard({
    required this.order,
    required this.title,
    required this.now,
    required this.onOpen,
    required this.onPrint,
  });
  final Json order;
  final String title;
  final DateTime now;
  final VoidCallback onOpen, onPrint;

  @override
  Widget build(BuildContext context) {
    final minutes = openMinutes(order, now);
    final long = minutes >= 90;
    final due = orderDueCents(order);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onOpen,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _border)),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(child: Text(title, maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800,
                          fontSize: 14.5))),
                      const SizedBox(width: 8),
                      Icon(Icons.timer_outlined, size: 13,
                        color: long ? const Color(0xffB3261E) : NohutBrand.muted),
                      const SizedBox(width: 2),
                      Text(durationLabel(minutes), style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700,
                        color: long ? const Color(0xffB3261E) : NohutBrand.muted)),
                    ]),
                    const SizedBox(height: 2),
                    Text(itemsSummary(order), maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5)),
                    Text('${itemCount(order)} ürün · ${orderOwnerName(order)}',
                      style: const TextStyle(fontSize: 11.5,
                        color: NohutBrand.muted)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(formatTry(due), style: const TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 15)),
                  const SizedBox(height: 4),
                  StatusPill(localStatusStyle(order)),
                ],
              ),
              IconButton(
                tooltip: 'Ön Fiş Yazdır',
                onPressed: onPrint,
                icon: const Icon(Icons.print_outlined, size: 19),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
