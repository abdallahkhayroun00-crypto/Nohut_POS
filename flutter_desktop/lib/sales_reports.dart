import 'dart:io';
import 'package:flutter/material.dart';
import 'brand.dart';
import 'operations.dart';
import 'operations_ui.dart';
import 'pos_logic.dart';
import 'order_reporting.dart';
import 'report_activity.dart';
import 'platform_net.dart';

class SalesReports extends StatefulWidget {
  const SalesReports({
    super.key, required this.state, required this.edit, this.onlineWarning,
  });
  final Json state;
  final EditState edit;
  final String? onlineWarning;
  @override
  State<SalesReports> createState() => _SalesReportsState();
}

class _SalesReportsState extends State<SalesReports> {
  static const tabs = [
    'Genel Bakış',
    'Yoğunluk',
    'Trendyol Analitik',
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

  void _savePlatformRate(String platform, double percent) {
    widget.edit((state) {
      final settings = state.putIfAbsent(
        'settings', () => <String, dynamic>{}) as Map;
      final rates = settings.putIfAbsent(
        'platformDeductionRates', () => <String, dynamic>{}) as Map;
      rates[platform] = percent;
    });
  }

  Future<void> _editPlatformRate(String platform) async {
    final current = deliveryDeductionPercent(widget.state, platform);
    final answer = await askFields(context, '$platform · Kesinti Ayarı', [
      ('Toplam kesinti (%) · KDV dahil',
        current == null ? '' : current.toStringAsFixed(2)),
    ], validate: (values) {
      if (values.isEmpty) return 'Kesinti yüzdesi gerekli';
      final p = double.tryParse(values.first.trim().replaceAll(',', '.'));
      if (p == null || !p.isFinite || p < 0 || p > 100)
        return '0 ile 100 arasında yüzde girin';
      return null;
    });
    if (answer == null || !mounted) return;
    final percent = double.parse(answer.first.trim().replaceAll(',', '.'));
    _savePlatformRate(platform, percent);
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
    final platformNet = deliveryNetEstimates(widget.state, includes,
      source: source);
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
    final trendyolOrders = asMaps(widget.state['trendyolGoOrders'])
        .where((order) => order['testPackage'] != true &&
            includes((order['createdAt'] ?? '').toString()) &&
            (source == 'Tümü' || source == 'Trendyol Go'))
        .toList();
    final hourly = <int, int>{};
    for (final order in trendyolOrders) {
      final created = DateTime.tryParse((order['createdAt'] ?? '').toString());
      if (created == null) continue;
      final hour = created.toUtc().add(const Duration(hours: 3)).hour;
      hourly[hour] = (hourly[hour] ?? 0) + 1;
    }
    final maximumHour = hourly.values.fold<int>(0, (a, b) => a > b ? a : b);
    final courierMilestones = <String, int>{};
    for (final stage in const ['nearby', 'picked_up', 'delivered']) {
      courierMilestones[stage] = trendyolOrders.where((o) =>
          asMaps(o['courierTimeline']).any((e) => e['stage'] == stage))
          .length;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        panelTitle('Raporlar'),
        const Text('Tarih aralığı ve sipariş kaynağı seçin.'),
        if (widget.onlineWarning != null)
          Card(child: ListTile(
            leading: const Icon(Icons.info_outline, color: NohutBrand.gold),
            title: const Text('Online platform verileri eksik olabilir'),
            subtitle: Text(widget.onlineWarning!),
          )),
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
          if (platformNet.isNotEmpty) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(17),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Online Platformlar · Tahmini Net',
                      style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 5),
                    const Text(
                      'Brüt - toplam platform kesintisi (KDV dahil) = '
                      'tahmini kalan tutar. Banka ödemesi veya işletme kârı '
                      'değildir; stopaj, iadeler ve kampanya farkları ayrıca '
                      'mutabık kalınmalıdır.',
                      style: TextStyle(
                        color: NohutBrand.muted, fontSize: 12)),
                    const SizedBox(height: 10),
                    for (final p in platformNet) ...[
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(p.source,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800)),
                        subtitle: Text(
                          '${p.orderCount} kayıtlı teslim edilmiş sipariş · '
                          'Kesinti: ${p.deductionPercent == null
                            ? 'Bilinmiyor'
                            : '%${p.deductionPercent!.toStringAsFixed(2)}'}'),
                        trailing: TextButton(
                          key: ValueKey('platform-fee-edit-${p.source}'),
                          onPressed: () => _editPlatformRate(p.source),
                          child: const Text('Oranı Düzenle'),
                        ),
                      ),
                      Wrap(
                        spacing: 10, runSpacing: 10,
                        children: [
                          _summaryInsight(Icons.payments_outlined,
                            'Brüt', formatTry(p.grossCents)),
                          _summaryInsight(Icons.remove_circle_outline,
                            'Kesinti', p.deductionCents == null
                              ? '—' : formatTry(p.deductionCents!)),
                          _summaryInsight(Icons.account_balance_wallet_outlined,
                            'Tahmini Net', p.estimatedNetCents == null
                              ? '—' : formatTry(p.estimatedNetCents!)),
                        ],
                      ),
                      if (p.source == 'Trendyol Go' &&
                          p.deductionPercent == null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            key: const ValueKey('trendyol-october-reference'),
                            onPressed: () => _savePlatformRate(
                              'Trendyol Go', 38.4),
                            icon: const Icon(Icons.history_outlined, size: 17),
                            label: const Text(
                              'Ekim 2026 ekstre oranını (%38,4) uygula'),
                          ),
                        ),
                      const Divider(height: 23),
                    ],
                    const Text(
                      'Oranlar restoran sözleşmesine ve döneme göre değişebilir. '
                      'Yemeksepeti / Migros Yemek bağlantısı yoksa '
                      '0 sipariş, gerçekten hiç satış olmadığı anlamına gelmez.',
                      style: TextStyle(
                        color: NohutBrand.muted, fontSize: 11)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
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
        if (tab == 'Trendyol Analitik') ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Trendyol Go · Sipariş ve Kurye Analizi',
                    style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 5),
                  const Text('Bu rakamlar yalnızca POS tarafından alınmış platform kayıtlarına dayanır. '
                    'Eksik senkronizasyon gerçek sıfır sipariş anlamına gelmez.'),
                  const SizedBox(height: 14),
                  Wrap(spacing: 12, runSpacing: 10, children: [
                    _summaryInsight(Icons.receipt_long_outlined,
                      'Alınan sipariş', trendyolOrders.length.toString()),
                    _summaryInsight(Icons.check_circle_outline,
                      'Teslim edilen', trendyolOrders.where((o) =>
                        o['status'] == 'Delivered').length.toString()),
                    _summaryInsight(Icons.cancel_outlined,
                      'İptal / karşılanamadı', trendyolOrders.where((o) =>
                        o['status'] == 'Cancelled' || o['status'] == 'UnSupplied').length.toString()),
                    _summaryInsight(Icons.payments_outlined,
                      'Teslim edilen toplam', formatTry(
                        trendyolOrders.where((o) => o['status'] == 'Delivered')
                          .fold<int>(0, (sum, o) => sum +
                            (o['totalCents'] as int? ?? 0)))),
                  ]),
                  const Divider(height: 28),
                  const Text('Kurye Takip · POS gözlemleri',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 9),
                  for (final row in const [
                    ('nearby', 'Kurye Yaklaşıyor'),
                    ('picked_up', 'Kuryeye Teslim Edildi'),
                    ('delivered', 'Müşteriye Teslim Edildi'),
                  ])
                    ListTile(
                      dense: true,
                      title: Text(row.$2),
                      trailing: Text((courierMilestones[row.$1] ?? 0).toString(),
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  const Text('Olay saatleri, platformun gerçek olay zamanı değil, '
                    'POS tarafından ilk görülen zamandır.',
                    style: TextStyle(fontSize: 12, color: NohutBrand.muted)),
                  const Divider(height: 28),
                  const Text('Sipariş Yoğunluğu · Saatlik',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 10),
                  for (var hour = 0; hour < 24; hour++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(children: [
                        SizedBox(width: 55, child: Text(
                          hour.toString().padLeft(2, '0') + ':00')),
                        Expanded(child: LinearProgressIndicator(
                          value: maximumHour == 0 ? 0 :
                            ((hourly[hour] ?? 0) / maximumHour).toDouble(),
                          minHeight: 8,
                          borderRadius: BorderRadius.circular(6),
                        )),
                        const SizedBox(width: 9),
                        SizedBox(width: 28, child: Text(
                          (hourly[hour] ?? 0).toString(),
                          textAlign: TextAlign.right)),
                      ]),
                    ),
                ],
              ),
            ),
          ),
        ],
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
