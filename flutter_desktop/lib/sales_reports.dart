import 'dart:io';
import 'package:flutter/material.dart';
import 'brand.dart';
import 'operations.dart';
import 'operations_ui.dart';
import 'pos_logic.dart';
import 'order_reporting.dart';
import 'report_activity.dart';

class SalesReports extends StatefulWidget {
  const SalesReports({super.key, required this.state, required this.edit});
  final Json state;
  final EditState edit;
  @override
  State<SalesReports> createState() => _SalesReportsState();
}

class _SalesReportsState extends State<SalesReports> {
  static const tabs = [
    'Genel Bakış',
    'Yoğunluk',
    'Satışlar',
    'Ürünler',
    'Hazırlık Süresi',
    'İptaller',
    'Mutabakat',
  ];
  String from = istanbulDay(DateTime.now()),
      to = istanbulDay(DateTime.now()),
      source = 'Tümü',
      tab = 'Genel Bakış';
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
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              decoration: BoxDecoration(
                color: const Color(0xffEAF2EC),
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(9),
              child: Icon(icon, color: NohutBrand.green, size: 20),
            ),
            const SizedBox(height: 12),
            Text(label, style: const TextStyle(
                color: NohutBrand.muted, fontSize: 12)),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(amount, style: const TextStyle(
                fontSize: 25, fontWeight: FontWeight.w800,
                color: NohutBrand.green)),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _summaryInsight(IconData icon, String label, String value) =>
      Container(
        constraints: const BoxConstraints(minWidth: 185),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xffF4F7F3),
          borderRadius: BorderRadius.circular(13),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: NohutBrand.green, size: 21),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(
                  color: NohutBrand.muted, fontSize: 11)),
                Text(value, style: const TextStyle(
                  color: NohutBrand.green, fontWeight: FontWeight.w800,
                  fontSize: 16)),
              ],
            ),
          ],
        ),
      );

  Widget _productBar(String name, int quantity, int revenue, int maximum) {
    final ratio = maximum <= 0
        ? 0.0
        : (revenue / maximum).clamp(0.0, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: Text(name,
                  style: const TextStyle(fontWeight: FontWeight.w600))),
              const SizedBox(width: 8),
              Text('$quantity adet',
                  style: const TextStyle(color: NohutBrand.muted)),
              const SizedBox(width: 12),
              Text(formatTry(revenue),
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: ratio,
            minHeight: 7,
            borderRadius: BorderRadius.circular(8),
            backgroundColor: const Color(0xffEDF1EC),
            color: NohutBrand.green,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = ledger(widget.state)
        .where(
          (e) =>
              includes(e.stamp) &&
              const ['Masa', 'Gel-Al'].contains(e.source) &&
              (source == 'Tümü' || e.source == source),
        )
        .toList();
    final sold = sales(widget.state)
        .where(
          (e) =>
              includes(e.stamp) &&
              const ['Masa', 'Gel-Al'].contains(e.source) &&
              (source == 'Tümü' || e.source == source),
        )
        .toList();
    final activity = ReportActivity(widget.state, includes, source);
    final net = entries.fold<int>(0, (n, e) => n + e.amount),
        refund = entries
            .where((e) => e.amount < 0)
            .fold<int>(0, (n, e) => n - e.amount);
    final products = <String, (int, int)>{};
    for (final r in sold) {
      final old = products[r.product] ?? (0, 0);
      products[r.product] = (old.$1 + r.quantity, old.$2 + r.amount);
    }
    final finance =
        asMaps((widget.state['integrations'] as Map?)?['settlements'])
            .where(
              (r) =>
                  includes('${r['stamp']}') &&
                  (source == 'Tümü' || r['source'] == source),
            )
            .toList();
    final sorted = products.entries.toList()
      ..sort((a, b) => b.value.$2.compareTo(a.value.$2));
    final onlineProducts = activity.onlineProducts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        panelTitle('Raporlar'),
        const Text('Tarih aralığı ve sipariş kaynağı seçin.'),
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
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Kaynak'),
                    items:
                        [
                              'Tümü',
                              'Masa',
                              'Gel-Al',
                              'Trendyol Go',
                              'Yemeksepeti',
                              'Migros Yemek',
                            ]
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
            metric(
              'Yerel net tahsilat',
              formatTry(net),
              Icons.payments_outlined,
            ),
            metric(
              'Trendyol Go satışları',
              formatTry(activity.onlineSales),
              Icons.delivery_dining_outlined,
            ),
            metric('Yerel iadeler', formatTry(refund), Icons.undo),
            metric(
              'Yerel ürün adedi',
              '${sold.fold<int>(0, (n, e) => n + e.quantity)}',
              Icons.restaurant_outlined,
            ),
            metric(
              'Sipariş sayısı',
              '${activity.orderCount}',
              Icons.receipt_long_outlined,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            for (final name in tabs)
              ChoiceChip(
                label: Text(name),
                selected: tab == name,
                onSelected: (_) => setState(() => tab = name),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (tab == 'Genel Bakış') ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(19),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Dönem Özeti', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 7),
                  const Text('Yerel tahsilat ve platform satış tutarı farklı muhasebe kalemleridir.',
                      style: TextStyle(color: NohutBrand.muted, fontSize: 12)),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 24,
                    runSpacing: 12,
                    children: [
                      _summaryInsight(Icons.timer_outlined, 'Ortalama hazırlık',
                          activity.prepAverage == null ? '—' : '${activity.prepAverage} dk'),
                      _summaryInsight(Icons.cancel_outlined, 'İptal / karşılanamadı',
                          '${activity.cancellations.length}'),
                      _summaryInsight(Icons.delivery_dining_outlined, 'Trendyol teslim edilen',
                          '${activity.onlineCount}'),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(19),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Öne çıkan yerel ürünler',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  const Text('Satış kayıtlarına dayalı ürün dağılımı · Tahsilat değildir.',
                      style: TextStyle(fontSize: 12, color: NohutBrand.muted)),
                  const SizedBox(height: 14),
                  if (sorted.isEmpty)
                    const Text('Bu tarih aralığında yerel ürün kaydı yok.'),
                  for (final entry in sorted.take(5))
                    _productBar(
                      entry.key, entry.value.$1, entry.value.$2,
                      sorted.first.value.$2,
                    ),
                ],
              ),
            ),
          ),
        ],
        if (tab == 'Yoğunluk')
          DemandCharts(
            activity: activity,
            export: () => export('nohut-yogunluk', activity.csv),
          ),
        if (tab == 'Hazırlık Süresi')
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('Tamamlanan hazırlıklar'),
                  subtitle: Text(
                    'Ölçülen sipariş · ${activity.prepared.length}',
                  ),
                  trailing: Text(
                    activity.prepAverage == null
                        ? '—'
                        : '${activity.prepAverage} dk ort.',
                  ),
                ),
                for (final (duration, order) in activity.prepared)
                  ListTile(
                    title: Text(
                      '#${displayOrderNumber(order)} · ${order['source']}',
                    ),
                    subtitle: Text(istanbulStamp(order['readyAt'])),
                    trailing: Text('${duration.inMinutes} dk'),
                  ),
              ],
            ),
          ),
        if (tab == 'İptaller')
          Card(
            child: Column(
              children: [
                ListTile(
                  title: Text(
                    '${activity.cancellations.length} iptal / karşılanamadı',
                  ),
                ),
                for (final (date, order) in activity.cancellations)
                  ListTile(
                    title: Text(
                      '#${displayOrderNumber(order)} · ${order['source']}',
                    ),
                    subtitle: Text(
                      [
                            istanbulStamp(date),
                            order['cancelReason'],
                            order['voidReason'],
                          ]
                          .where(
                            (part) => part != null && '$part'.trim().isNotEmpty,
                          )
                          .join(' · '),
                    ),
                  ),
              ],
            ),
          ),
        if (tab == 'Satışlar')
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    title: const Text('Trendyol Go · Teslim edilen siparişler'),
                    subtitle: Text(
                      '${activity.onlineCount} sipariş · Platform toplamı',
                    ),
                    trailing: Text(formatTry(activity.onlineSales)),
                  ),
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
                    label: const Text('Yerel Ürün Satışları CSV'),
                  ),
                  if (sorted.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(25),
                      child: Text('Bu dönemde yerel ürün satışı yok.'),
                    ),
                  for (final e in sorted)
                    _productBar(
                      e.key,
                      e.value.$1,
                      e.value.$2,
                      sorted.first.value.$2,
                    ),
                  if (onlineProducts.isNotEmpty) ...[
                    const Divider(),
                    const ListTile(
                      title: Text('Trendyol Go · Teslim edilen ürünler'),
                    ),
                    for (final e in onlineProducts)
                      ListTile(
                        title: Text(e.key),
                        trailing: Text('${e.value} adet'),
                      ),
                  ],
                ],
              ),
            ),
          ),
        if (tab == 'Mutabakat')
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Geçmiş platform kayıtları · Yalnızca görüntüleme',
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: () => export(
                      'nohut-mutabakat',
                      '\uFEFF${[
                        ['Sipariş', 'Kaynak', 'Brüt', 'İade', 'Komisyon', 'Net', 'Ödeme emri', 'Durum', 'Tarih'],
                        ...finance.map((r) => [r['orderId'], r['source'], r['gross'], r['refund'], r['commission'], r['net'], r['paymentOrderId'], r['paymentStatus'], r['stamp']]),
                      ].map((r) => r.map(csvCell).join(',')).join('\r\n')}\r\n',
                    ),
                    icon: const Icon(Icons.download),
                    label: const Text('Mutabakat CSV'),
                  ),
                  if (finance.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(25),
                      child: Text('Bu dönemde mutabakat kaydı yok.'),
                    ),
                  for (final r in finance)
                    ListTile(
                      title: Text('${r['source']} · ${r['paymentOrderId']}'),
                      subtitle: Text('${r['paymentStatus']}'),
                      trailing: Text(formatTry(cents(r['net']))),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
