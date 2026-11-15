import 'dart:io';
import 'package:flutter/material.dart';
import 'brand.dart';
import 'operations.dart';
import 'operations_ui.dart';
import 'pos_logic.dart';
import 'order_reporting.dart';

class SalesReports extends StatefulWidget {
  const SalesReports({super.key, required this.state, required this.edit});
  final Json state;
  final EditState edit;
  @override
  State<SalesReports> createState() => _SalesReportsState();
}

class _SalesReportsState extends State<SalesReports> {
  String from = istanbulDay(DateTime.now()),
      to = istanbulDay(DateTime.now()),
      source = 'Tümü',
      tab = 'Özet';
  bool includes(String stamp) {
    final d = DateTime.tryParse(stamp);
    if (d == null) return false;
    final day = istanbulDay(d);
    return (from.isEmpty || day.compareTo(from) >= 0) &&
        (to.isEmpty || day.compareTo(to) <= 0);
  }

  Future<void> export(String name, String text) async {
    final v = await askFields(context, 'CSV Kaydet', [
      ('Dosya yolu', '${Directory.current.path}/$name.csv'),
    ]);
    if (v == null) return;
    try {
      final file = File(v[0]);
      if (file.existsSync()) throw const FormatException('Dosya zaten var');
      file.writeAsStringSync(text.startsWith('\uFEFF') ? text : '\uFEFF$text');
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('CSV kaydedildi')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Widget metric(String label, String amount, IconData icon) => SizedBox(
    width: 220,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: NohutBrand.gold),
            const SizedBox(height: 12),
            Text(label),
            Text(
              amount,
              style: const TextStyle(
                fontSize: 27,
                fontWeight: FontWeight.w700,
                color: NohutBrand.green,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final entries = ledger(widget.state)
        .where(
          (e) => includes(e.stamp) && (source == 'Tümü' || e.source == source),
        )
        .toList();
    final sold = sales(widget.state)
        .where(
          (e) => includes(e.stamp) && (source == 'Tümü' || e.source == source),
        )
        .toList();
    final counts = hourlyOrderCounts(
      asMaps(widget.state['orders']),
      from: from,
      to: to,
      source: source,
      staff: '',
    );
    final net = entries.fold<int>(0, (n, e) => n + e.amount),
        refund = entries
            .where((e) => e.amount < 0)
            .fold<int>(0, (n, e) => n - e.amount);
    final products = <String, (int, int)>{};
    for (final r in sold) {
      final old = products[r.product] ?? (0, 0);
      products[r.product] = (old.$1 + r.quantity, old.$2 + r.amount);
    }
    final sorted = products.entries.toList()
      ..sort((a, b) => b.value.$2.compareTo(a.value.$2));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        panelTitle('Raporlar'),
        const Text(
          'Satış, tahsilat ve yoğunluğu anlaşılır bir özetle takip et.',
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 8,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final days in [1, 7, 30])
                  OutlinedButton(
                    onPressed: () => setState(() {
                      final now = DateTime.now().toUtc().add(
                        const Duration(hours: 3),
                      );
                      to = now.toIso8601String().substring(0, 10);
                      from = now
                          .subtract(Duration(days: days - 1))
                          .toIso8601String()
                          .substring(0, 10);
                    }),
                    child: Text(days == 1 ? 'Bugün' : 'Son $days Gün'),
                  ),
                OutlinedButton(
                  onPressed: () async {
                    final dates = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (dates != null)
                      setState(() {
                        from = dates.start.toIso8601String().substring(0, 10);
                        to = dates.end.toIso8601String().substring(0, 10);
                      });
                  },
                  child: const Text('Takvimden Seç'),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    from = to = '';
                  }),
                  child: const Text('Tüm Tarihler'),
                ),
                SizedBox(
                  width: 180,
                  child: DropdownButtonFormField<String>(
                    initialValue: source,
                    decoration: const InputDecoration(labelText: 'Kaynak'),
                    items:
                        ['Tümü', 'Masa', 'Gel-Al', 'Trendyol Go', 'Yemeksepeti']
                            .map(
                              (s) => DropdownMenuItem(value: s, child: Text(s)),
                            )
                            .toList(),
                    onChanged: (v) => setState(() => source = v!),
                  ),
                ),
                Text(from.isEmpty ? 'Tüm geçmiş' : '$from → $to'),
              ],
            ),
          ),
        ),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            metric('Net tahsilat', formatTry(net), Icons.payments_outlined),
            metric('İadeler', formatTry(refund), Icons.undo),
            metric(
              'Satılan ürün',
              '${sold.fold<int>(0, (n, e) => n + e.quantity)}',
              Icons.restaurant_outlined,
            ),
            metric(
              'Sipariş sayısı',
              '${counts.fold<int>(0, (a, b) => a + b)}',
              Icons.receipt_long_outlined,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            for (final name in ['Özet', 'Tahsilat', 'Ürünler'])
              ChoiceChip(
                label: Text(name),
                selected: tab == name,
                onSelected: (_) => setState(() => tab = name),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (tab == 'Özet')
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  panelTitle('Saatlik yoğunluk'),
                  const Text('Yeni sipariş sayısı · İstanbul saati'),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 150,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (var h = 0; h < 24; h++)
                          Expanded(
                            child: Tooltip(
                              message: '$h:00 · ${counts[h]} sipariş',
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    if (counts[h] > 0)
                                      Text(
                                        '${counts[h]}',
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                    Container(
                                      height:
                                          counts.reduce(
                                                (a, b) => a > b ? a : b,
                                              ) ==
                                              0
                                          ? 2
                                          : 100 *
                                                counts[h] /
                                                counts.reduce(
                                                  (a, b) => a > b ? a : b,
                                                ),
                                      decoration: BoxDecoration(
                                        color: NohutBrand.green,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                    ),
                                    if (h % 3 == 0)
                                      Text(
                                        '$h',
                                        style: const TextStyle(fontSize: 11),
                                      )
                                    else
                                      const SizedBox(height: 16),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () =>
                        export('nohut-yogunluk', hourlyCountsCsv(counts)),
                    icon: const Icon(Icons.download),
                    label: const Text('Yoğunluk CSV'),
                  ),
                ],
              ),
            ),
          ),
        if (tab == 'Tahsilat')
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    onPressed: () =>
                        export('nohut-tahsilat', ledgerCsv(entries)),
                    icon: const Icon(Icons.download),
                    label: const Text('Tahsilat CSV'),
                  ),
                  if (entries.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(25),
                      child: Text('Bu dönemde tahsilat yok.'),
                    ),
                  for (final e in entries.reversed)
                    ListTile(
                      leading: Icon(
                        e.amount < 0 ? Icons.undo : Icons.check_circle_outline,
                      ),
                      title: Text(
                        '#${displayOrderNumber(mutableOrder(widget.state, e.orderId) ?? {'id': e.orderId})} · ${e.method}',
                      ),
                      subtitle: Text('${istanbulStamp(e.stamp)} · ${e.staff}'),
                      trailing: Text(formatTry(e.amount)),
                    ),
                ],
              ),
            ),
          ),
        if (tab == 'Ürünler')
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    onPressed: () => export('nohut-urunler', salesCsv(sold)),
                    icon: const Icon(Icons.download),
                    label: const Text('Ürün Satışları CSV'),
                  ),
                  if (sorted.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(25),
                      child: Text('Bu dönemde ürün satışı yok.'),
                    ),
                  for (final e in sorted)
                    ListTile(
                      title: Text(e.key),
                      subtitle: Text('${e.value.$1} adet'),
                      trailing: Text(formatTry(e.value.$2)),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  String hourlyCountsCsv(List<int> counts) =>
      '\uFEFFSaat,Sipariş\r\n${[for (var h = 0; h < 24; h++) '$h,${counts[h]}'].join('\r\n')}\r\n';
}
