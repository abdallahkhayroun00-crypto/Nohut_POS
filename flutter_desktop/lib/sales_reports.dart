import 'dart:io';
import 'package:flutter/material.dart';
import 'brand.dart';
import 'operations.dart';
import 'operations_ui.dart';
import 'pos_logic.dart';
import 'order_reporting.dart';
import 'report_activity.dart';
import 'platform_net.dart';

/// Where report CSV files are suggested: the user's Documents folder.
/// The program folder (Program Files) is not writable on Windows.
String reportExportFolder() {
  final env = Platform.environment;
  final home = env['USERPROFILE'] ?? env['HOME'];
  if (home == null || home.isEmpty) return Directory.systemTemp.path;
  final documents = Directory('$home${Platform.pathSeparator}Documents');
  return documents.existsSync() ? documents.path : home;
}

/// Date presets for the report filter, as Istanbul business days.
({String from, String to}) reportPreset(String preset, DateTime now) {
  final local = now.toUtc().add(const Duration(hours: 3));
  final today = DateTime.utc(local.year, local.month, local.day);
  String d(DateTime x) => x.toIso8601String().substring(0, 10);
  return switch (preset) {
    'Dün' => (from: d(today.subtract(const Duration(days: 1))),
        to: d(today.subtract(const Duration(days: 1)))),
    'Son 7 Gün' => (from: d(today.subtract(const Duration(days: 6))), to: d(today)),
    'Son 30 Gün' => (from: d(today.subtract(const Duration(days: 29))), to: d(today)),
    'Bu Ay' => (from: d(DateTime.utc(today.year, today.month, 1)), to: d(today)),
    'Tüm Tarihler' => (from: '', to: ''),
    _ => (from: d(today), to: d(today)),
  };
}

const reportPresets = ['Bugün', 'Dün', 'Son 7 Gün', 'Son 30 Gün', 'Bu Ay', 'Tüm Tarihler'];

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
      ('Dosya yolu', '${reportExportFolder()}${Platform.pathSeparator}$name-${from.isEmpty ? 'tum' : from}${to.isEmpty || to == from ? '' : '_$to'}.csv'),
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
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xffF4F7F3),
          borderRadius: BorderRadius.circular(13),
        ),
        child: Row(
          children: [
            Icon(icon, color: NohutBrand.green, size: 21),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: NohutBrand.muted, fontSize: 11)),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(value, style: const TextStyle(
                      color: NohutBrand.green, fontWeight: FontWeight.w800,
                      fontSize: 16)),
                  ),
                ],
              ),
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
    final courierMilestones = <String, int>{};
    for (final stage in const ['nearby', 'picked_up', 'delivered']) {
      courierMilestones[stage] = trendyolOrders.where((o) =>
          asMaps(o['courierTimeline']).any((e) => e['stage'] == stage))
          .length;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // The window header already names this page.
                  Text(
                    from.isEmpty
                        ? 'Tüm geçmiş · ${source == 'Tümü' ? 'tüm kaynaklar' : source}'
                        : '${from == to ? from : '$from → $to'} · ${source == 'Tümü' ? 'tüm kaynaklar' : source}',
                    style: const TextStyle(color: NohutBrand.muted)),
                ],
              ),
            ),
          ],
        ),
        if (widget.onlineWarning != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xffFFF6E0),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xffEED9A6)),
            ),
            child: Row(children: [
              const Icon(Icons.info_outline, size: 18, color: Color(0xff8A6516)),
              const SizedBox(width: 10),
              Expanded(child: Text(
                'Online platform verileri eksik olabilir · ${widget.onlineWarning!}',
                style: const TextStyle(color: Color(0xff6B4E10), fontSize: 13))),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xffE1E7E3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(Icons.calendar_month_outlined,
                      size: 19, color: NohutBrand.green),
                  ),
                  for (final preset in reportPresets)
                    ChoiceChip(
                      label: Text(preset),
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      selected: () {
                        final r = reportPreset(preset, DateTime.now());
                        return r.from == from && r.to == to;
                      }(),
                      onSelected: (_) => setState(() {
                        final r = reportPreset(preset, DateTime.now());
                        from = r.from;
                        to = r.to;
                      }),
                    ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                    onPressed: () async {
                      final now = DateTime.now();
                      final dates = await showDateRangePicker(
                        context: context,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(now.year, now.month, now.day),
                      );
                      if (dates != null)
                        setState(() {
                          from = dates.start.toIso8601String().substring(0, 10);
                          to = dates.end.toIso8601String().substring(0, 10);
                        });
                    },
                    icon: const Icon(Icons.date_range, size: 18),
                    label: const Text('Takvimden Seç'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(Icons.storefront_outlined,
                      size: 19, color: NohutBrand.green),
                  ),
                  for (final s in const ['Tümü', 'Masa', 'Gel-Al',
                      'Trendyol Go', 'Yemeksepeti', 'Migros Yemek'])
                    ChoiceChip(
                      label: Text(s == 'Tümü' ? 'Tüm kaynaklar' : s),
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      selected: source == s,
                      onSelected: (_) => setState(() => source = s),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        EvenGrid(
          minTileWidth: 190,
          spacing: 10,
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
                showCheckmark: false,
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
                      EvenGrid(
                        minTileWidth: 180, spacing: 10,
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
                  EvenGrid(
                    minTileWidth: 200,
                    spacing: 10,
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
        if (tab == 'Hazırlık Süresi') ...[
          EvenGrid(minTileWidth: 200, spacing: 10, children: [
            _summaryInsight(Icons.timer_outlined, 'Ortalama hazırlık',
              activity.prepAverage == null ? '—' : '${activity.prepAverage} dk'),
            _summaryInsight(Icons.check_circle_outline, 'Ölçülen sipariş',
              '${activity.prepared.length}'),
            _summaryInsight(Icons.hourglass_bottom, 'En uzun',
              activity.prepared.isEmpty ? '—'
                : '${activity.prepared.first.$1.inMinutes} dk'),
          ]),
          const SizedBox(height: 12),
          _ReportTable(
            title: 'Tamamlanan Hazırlıklar',
            subtitle: 'En uzun süren üstte · hazır olduğu saat',
            columns: const ['Hazır', 'Sipariş', 'Kaynak', 'Süre'],
            flex: const [3, 2, 2, 2],
            empty: 'Bu dönemde ölçülen hazırlık yok.',
            rows: [
              for (final (duration, order) in activity.prepared)
                [
                  Text(istanbulStamp(order['readyAt']), style: const TextStyle(
                    color: NohutBrand.muted, fontSize: 13)),
                  Text('#${displayOrderNumber(order)}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text('${order['source']}'),
                  _Pill('${duration.inMinutes} dk',
                    duration.inMinutes >= 20 ? const Color(0xffB3261E)
                      : duration.inMinutes >= 12 ? const Color(0xffB7791F)
                      : NohutBrand.green),
                ],
            ],
          ),
        ],
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
                  EvenGrid(minTileWidth: 180, spacing: 10, children: [
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
                  EvenGrid(minTileWidth: 180, spacing: 10, children: [
                    for (final row in const [
                      ('nearby', 'Kurye Yaklaşıyor', Icons.near_me_outlined),
                      ('picked_up', 'Kuryeye Teslim Edildi', Icons.delivery_dining_outlined),
                      ('delivered', 'Müşteriye Teslim Edildi', Icons.home_outlined),
                    ])
                      _summaryInsight(row.$3, row.$2,
                        (courierMilestones[row.$1] ?? 0).toString()),
                  ]),
                  const SizedBox(height: 8),
                  const Text('Olay saatleri, platformun gerçek olay zamanı değil, '
                    'POS tarafından ilk görülen zamandır.',
                    style: TextStyle(fontSize: 12, color: NohutBrand.muted)),
                  const Divider(height: 28),
                  const Text('Sipariş Yoğunluğu · Saatlik',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 10),
                  _HourBars(counts: [for (var h = 0; h < 24; h++) hourly[h] ?? 0]),
                ],
              ),
            ),
          ),
        ],
        if (tab == 'İptaller')
          _ReportTable(
            title: 'İptal ve Karşılanamayan Siparişler',
            subtitle: '${activity.cancellations.length} kayıt',
            columns: const ['Tarih', 'Sipariş', 'Kaynak', 'Neden'],
            flex: const [3, 2, 2, 6],
            empty: 'Bu dönemde iptal yok.',
            rows: [
              for (final (date, order) in activity.cancellations)
                [
                  Text(istanbulStamp(date), style: const TextStyle(
                    color: NohutBrand.muted, fontSize: 13)),
                  Text('#${displayOrderNumber(order)}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text('${order['source']}'),
                  Text(
                    [order['cancelReason'], order['voidReason']]
                        .where((part) => part != null && '$part'.trim().isNotEmpty)
                        .join(' · ')
                        .ifEmpty('Neden girilmemiş'),
                    style: const TextStyle(color: Color(0xff8c352e))),
                ],
            ],
          ),
        if (tab == 'Satışlar') ...[
          Builder(builder: (context) {
            final cash = entries.where((e) => e.method == 'Nakit')
                .fold<int>(0, (n, e) => n + e.amount);
            final card = entries.where((e) => e.method == 'Kart')
                .fold<int>(0, (n, e) => n + e.amount);
            return EvenGrid(minTileWidth: 170, spacing: 10, children: [
              _summaryInsight(Icons.payments_outlined, 'Nakit (net)', formatTry(cash)),
              _summaryInsight(Icons.credit_card, 'Kart (net)', formatTry(card)),
              _summaryInsight(Icons.undo, 'İade', formatTry(refund)),
              _summaryInsight(Icons.account_balance_wallet_outlined,
                'Yerel net tahsilat', formatTry(net)),
              _summaryInsight(Icons.delivery_dining_outlined,
                'Trendyol Go · ${activity.onlineCount} teslim',
                formatTry(activity.onlineSales)),
            ]);
          }),
          const SizedBox(height: 12),
          _ReportTable(
            title: 'Tahsilat Kayıtları',
            subtitle: '${entries.length} kayıt · en yenisi üstte',
            action: FilledButton.icon(
              onPressed: () => export('nohut-tahsilat', ledgerCsv(entries)),
              icon: const Icon(Icons.download, size: 18),
              label: const Text('Tahsilat CSV'),
            ),
            columns: const ['Saat', 'Sipariş', 'Kaynak', 'Yöntem', 'Kaydeden', 'Tutar'],
            flex: const [3, 2, 2, 2, 3, 2],
            empty: 'Bu dönemde tahsilat yok.',
            rows: [
              for (final e in entries.reversed)
                [
                  Text(istanbulStamp(e.stamp), style: const TextStyle(
                    color: NohutBrand.muted, fontSize: 13)),
                  Text('#${displayOrderNumber(mutableOrder(widget.state, e.orderId) ?? {'id': e.orderId})}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text(e.source),
                  _Pill(e.amount < 0 ? '${e.method} · İade' : e.method,
                    e.amount < 0 ? const Color(0xffB3261E)
                      : e.method == 'Kart' ? const Color(0xff325577) : NohutBrand.green),
                  Text(e.staff, overflow: TextOverflow.ellipsis),
                  Text(formatTry(e.amount), textAlign: TextAlign.right,
                    style: TextStyle(fontWeight: FontWeight.w800,
                      color: e.amount < 0 ? const Color(0xffB3261E) : NohutBrand.ink)),
                ],
            ],
          ),
        ],
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


extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, this.color);
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12.5)),
    ),
  );
}

/// A compact titled table used by the report tabs.
class _ReportTable extends StatelessWidget {
  const _ReportTable({
    required this.title,
    required this.columns,
    required this.flex,
    required this.rows,
    required this.empty,
    this.subtitle,
    this.action,
  });
  final String title, empty;
  final String? subtitle;
  final Widget? action;
  final List<String> columns;
  final List<int> flex;
  final List<List<Widget>> rows;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xffE1E7E3)),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 12),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800)),
                  if (subtitle != null)
                    Text(subtitle!, style: const TextStyle(
                      fontSize: 12.5, color: NohutBrand.muted)),
                ],
              ),
            ),
            ?action,
          ]),
        ),
        Container(
          color: const Color(0xffF4F6F2),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(children: [
            for (final (i, c) in columns.indexed)
              Expanded(
                flex: flex[i],
                child: Text(c,
                  textAlign: i == columns.length - 1 && c == 'Tutar'
                      ? TextAlign.right : TextAlign.left,
                  style: const TextStyle(fontSize: 12,
                    fontWeight: FontWeight.w700, color: NohutBrand.muted)),
              ),
          ]),
        ),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Text(empty, textAlign: TextAlign.center,
              style: const TextStyle(color: NohutBrand.muted)),
          ),
        for (final (i, row) in rows.indexed) ...[
          if (i > 0) const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(children: [
              for (final (j, cell) in row.indexed)
                Expanded(flex: flex[j], child: cell),
            ]),
          ),
        ],
      ],
    ),
  );
}

/// 24 vertical bars, one per Istanbul hour.
class _HourBars extends StatelessWidget {
  const _HourBars({required this.counts});
  final List<int> counts;

  @override
  Widget build(BuildContext context) {
    final peak = counts.fold<int>(0, (a, b) => a > b ? a : b);
    return SizedBox(
      height: 150,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var h = 0; h < 24; h++)
            Expanded(
              child: Tooltip(
                message: '${h.toString().padLeft(2, '0')}:00 · ${counts[h]} sipariş',
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (counts[h] > 0)
                      Text('${counts[h]}', style: const TextStyle(
                        fontSize: 10.5, fontWeight: FontWeight.w700)),
                    Container(
                      height: peak == 0 ? 2 : 2 + 100 * counts[h] / peak,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        color: counts[h] == 0
                            ? const Color(0xffE6ECE8) : const Color(0xffF27A1A),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(h % 3 == 0 ? h.toString().padLeft(2, '0') : '',
                      style: const TextStyle(fontSize: 10, color: NohutBrand.muted)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
