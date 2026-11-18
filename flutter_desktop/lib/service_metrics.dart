import 'package:flutter/material.dart';
import 'brand.dart';
import 'operations.dart';
import 'order_reporting.dart';
import 'pos_logic.dart';

String elapsedService(Json o) {
  final start = DateTime.tryParse('${o['createdAt']}'),
      ready = DateTime.tryParse('${o['readyAt']}'),
      end = DateTime.tryParse('${o['deliveredAt']}');
  String span(DateTime? a, DateTime? b) => a == null || b == null
      ? '—'
      : '${b.difference(a).inMinutes.clamp(0, 99999)} dk';
  return 'Hazırlık: ${span(DateTime.tryParse('${o['serviceStartedAt']}') ?? start, ready ?? (o['serviceStatus'] == 'Hazırlanıyor' ? DateTime.now() : null))} · Teslim: ${span(ready, end ?? (o['serviceStatus'] == 'Hazır' ? DateTime.now() : null))} · Toplam: ${span(start, end ?? DateTime.now())}';
}

class StaffMetrics extends StatelessWidget {
  const StaffMetrics({super.key, required this.state, required this.day});
  final Json state;
  final String day;
  @override
  Widget build(BuildContext context) {
    final groups = <String, List<Json>>{};
    for (final o in asMaps(state['orders']).where(
      (o) =>
          !isPlatform(o) &&
          o['cancelled'] != true &&
          onIstanbulDay(o['createdAt'], day),
    )) {
      final name = orderOwnerName(o);
      groups.putIfAbsent(name, () => []).add(o);
    }
    final additions = <String, int>{};
    for (final order in asMaps(state['orders'])) {
      if (isPlatform(order) ||
          order['cancelled'] == true ||
          !onIstanbulDay(order['createdAt'], day)) {
        continue;
      }
      for (final batch in asMaps(order['batches']).skip(1)) {
        if (!onIstanbulDay(batch['createdAt'], day) ||
            !asMaps(batch['lines']).any(
              (line) => line['correction'] != true && line['voided'] != true,
            )) {
          continue;
        }
        final name = orderOwnerName(order);
        additions.update(name, (count) => count + 1, ifAbsent: () => 1);
        groups.putIfAbsent(name, () => []);
      }
    }
    const columns = ['Sipariş', 'Masa', 'Gel-Al', 'Ek Sipariş', 'Satış'];
    final theme = Theme.of(context);
    final entries = groups.entries.map((entry) {
      final orders = entry.value;
      final tableCount = orders.where((o) => o['source'] == 'Masa').length;
      final pickupCount = orders.where((o) => o['source'] == 'Gel-Al').length;
      final sales = orders.fold<int>(0, (sum, o) => sum + orderTotalCents(o));
      return (
        entry.key,
        [
          '${orders.length}',
          '$tableCount',
          '$pickupCount',
          '${additions[entry.key] ?? 0}',
          formatTry(sales),
        ],
      );
    }).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.groups_outlined, color: NohutBrand.green),
                const SizedBox(width: 9),
                Expanded(
                  child: Text('Personel', style: theme.textTheme.titleLarge),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (entries.isEmpty)
              const Text('Bugün henüz personel siparişi yok.'),
            if (entries.isNotEmpty)
              LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < 500) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final (name, values) in entries) ...[
                          const Divider(height: 16),
                          Text(name, style: theme.textTheme.titleMedium),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 12,
                            runSpacing: 6,
                            children: [
                              for (var i = 0; i < columns.length; i++)
                                Text('${columns[i]} ${values[i]}'),
                            ],
                          ),
                        ],
                      ],
                    );
                  }
                  Widget cell(
                    String text, {
                    bool numeric = false,
                    bool header = false,
                    bool strong = false,
                  }) => Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                    child: Text(
                      text,
                      textAlign: numeric ? TextAlign.end : TextAlign.start,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: header ? NohutBrand.green : null,
                        fontWeight: header || strong ? FontWeight.w700 : null,
                      ),
                    ),
                  );
                  return Table(
                    columnWidths: const {
                      0: FlexColumnWidth(2),
                      5: FlexColumnWidth(1.5),
                    },
                    defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                    border: TableBorder(
                      horizontalInside: BorderSide(color: theme.dividerColor),
                    ),
                    children: [
                      TableRow(
                        decoration: const BoxDecoration(
                          color: Color(0xffe5ebdf),
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(8),
                          ),
                        ),
                        children: [
                          cell('Çalışan', header: true),
                          for (final label in columns)
                            cell(label, numeric: true, header: true),
                        ],
                      ),
                      for (final (name, values) in entries)
                        TableRow(
                          children: [
                            cell(name, strong: true),
                            for (var i = 0; i < values.length; i++)
                              cell(
                                values[i],
                                numeric: true,
                                strong: i == values.length - 1,
                              ),
                          ],
                        ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}


/// This is *order ownership*, not a list of people who touched the register.
/// All batches, including Ek Sipariş entered from the cashier PC, belong to the
/// employee who originally opened the order. Never infer who operated the PC.
class StaffOrderSummary {
  const StaffOrderSummary({
    required this.name,
    required this.orders,
    required this.tables,
    required this.pickups,
    required this.additions,
    required this.totalCents,
    required this.unassigned,
  });

  final String name;
  final int orders, tables, pickups, additions, totalCents;
  final bool unassigned;
}

List<StaffOrderSummary> staffOrderSummaries(Json state, String day) {
  final byPerson = <String, StaffOrderSummary>{};
  final employees = asMaps(state['employees']);
  for (final order in asMaps(state['orders'])) {
    if (!['Masa', 'Gel-Al'].contains(order['source']) ||
        order['cancelled'] == true ||
        order['demoRemoteStatus'] != null ||
        !onIstanbulDay(order['createdAt'], day)) {
      continue;
    }
    final batches = asMaps(order['batches']);
    final first = batches.firstOrNull;
    final staffId = first?['staffId'];
    final staffRecord = staffId is int
        ? employees.where((e) => e['id'] == staffId).firstOrNull
        : null;
    final storedName = orderOwnerName(order);
    final assigned = storedName != 'Atanmamış';
    final name = assigned
        ? '${staffRecord?['name'] ?? storedName}'.trim()
        : 'Atanmamış';
    final key = assigned
        ? staffId is int
            ? 'employee:$staffId'
            : 'name:${name.toLowerCase()}'
        : 'legacy-unassigned';
    final old = byPerson[key];
    final additions = batches.skip(1).where((batch) =>
        asMaps(batch['lines']).any((line) =>
            line['voided'] != true && line['correction'] != true)).length;
    byPerson[key] = StaffOrderSummary(
      name: name,
      unassigned: !assigned,
      orders: (old?.orders ?? 0) + 1,
      tables: (old?.tables ?? 0) + (order['source'] == 'Masa' ? 1 : 0),
      pickups: (old?.pickups ?? 0) + (order['source'] == 'Gel-Al' ? 1 : 0),
      additions: (old?.additions ?? 0) + additions,
      totalCents: (old?.totalCents ?? 0) + orderTotalCents(order),
    );
  }
  final rows = byPerson.values.toList();
  rows.sort((a, b) {
    if (a.unassigned != b.unassigned) return a.unassigned ? 1 : -1;
    final byAmount = b.totalCents.compareTo(a.totalCents);
    return byAmount != 0 ? byAmount : a.name.compareTo(b.name);
  });
  return rows;
}

/// Compact visual at the bottom of Genel Bakış. Existing unassigned PC sales
/// remain visible without pretending they belong to a particular employee.
class StaffPerformanceChart extends StatelessWidget {
  const StaffPerformanceChart({
    super.key,
    required this.state,
    required this.day,
  });
  final Json state;
  final String day;

  @override
  Widget build(BuildContext context) {
    final summaries = staffOrderSummaries(state, day);
    final allCents = summaries.fold<int>(
        0, (total, staff) => total + staff.totalCents);
    final allOrders = summaries.fold<int>(
        0, (total, staff) => total + staff.orders);
    final maxCents = summaries.fold<int>(
        0, (max, staff) =>
            staff.totalCents > max ? staff.totalCents : max);
    const colors = [
      NohutBrand.green,
      Color(0xffC7A15D),
      Color(0xff4F79A5),
      Color(0xff8F72B6),
      Color(0xff4D7C6D),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(19),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.groups_outlined,
                    color: NohutBrand.green, size: 23),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Personel Performansı',
                          style: Theme.of(context).textTheme.titleLarge),
                      Text(
                        '$day · Siparişi açan personele göre',
                        style: const TextStyle(
                            color: NohutBrand.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 25,
              runSpacing: 8,
              children: [
                _stat('Sipariş', '$allOrders'),
                _stat('Toplam Sipariş Tutarı', formatTry(allCents)),
                _stat('Ek Sipariş',
                    '${summaries.fold<int>(0,
                        (total, staff) => total + staff.additions)}'),
              ],
            ),
            if (summaries.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Text('Bugün personel siparişi kaydedilmedi.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: NohutBrand.muted)),
              ),
            for (var index = 0; index < summaries.length; index++) ...[
              const SizedBox(height: 17),
              _personRow(
                summaries[index],
                index == summaries.length - 1 &&
                        summaries[index].unassigned
                    ? const Color(0xff97A39B)
                    : colors[index % colors.length],
                maxCents,
                allCents,
              ),
            ],
            const SizedBox(height: 17),
            const Divider(),
            const SizedBox(height: 6),
            const Text(
              'Bir siparişin tüm ürünleri ve ek siparişleri, '
              'hesabı ilk açan personele yazılır. Ödeme alan kişi farklı '
              'olsa bile satış ikiye bölünmez. Eski Kasa (PC) kayıtları '
              'personel seçilmediği için Atanmamış olarak gösterilir. '
              'Bu rakamlar tahsilat değil, sipariş tutarlarıdır.',
              style: TextStyle(
                fontSize: 11,
                color: NohutBrand.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String title, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title,
          style: const TextStyle(color: NohutBrand.muted, fontSize: 11)),
      const SizedBox(height: 4),
      Text(value,
          style: const TextStyle(
            color: NohutBrand.green,
            fontWeight: FontWeight.w800,
            fontSize: 19,
          )),
    ],
  );

  Widget _personRow(
    StaffOrderSummary staff,
    Color color,
    int maxCents,
    int allCents,
  ) {
    final share = allCents == 0 ? 0.0 : staff.totalCents / allCents;
    final progress = maxCents == 0 ? 0.0 : staff.totalCents / maxCents;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 15,
              backgroundColor: color.withValues(alpha: .12),
              child: Icon(
                  staff.unassigned
                      ? Icons.help_outline
                      : Icons.person_outline,
                  size: 16,
                  color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(staff.name,
                  style: const TextStyle(
                    color: NohutBrand.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  )),
            ),
            Text(formatTry(staff.totalCents),
                style: const TextStyle(
                    color: NohutBrand.green,
                    fontSize: 15,
                    fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: 9),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            minHeight: 11,
            value: progress.clamp(0.0, 1.0).toDouble(),
            backgroundColor: const Color(0xffEFF2ED),
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
        const SizedBox(height: 7),
        Wrap(
          spacing: 14,
          runSpacing: 5,
          children: [
            Text('${staff.orders} sipariş',
                style: const TextStyle(
                    fontSize: 12, color: NohutBrand.muted)),
            Text('${staff.tables} masa',
                style: const TextStyle(
                    fontSize: 12, color: NohutBrand.muted)),
            Text('${staff.pickups} gel-al',
                style: const TextStyle(
                    fontSize: 12, color: NohutBrand.muted)),
            Text('${staff.additions} ek sipariş',
                style: const TextStyle(
                    fontSize: 12, color: NohutBrand.muted)),
            Text('${(share * 100).toStringAsFixed(1)}%',
                style: const TextStyle(
                    fontSize: 12, color: NohutBrand.green,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      ],
    );
  }
}
