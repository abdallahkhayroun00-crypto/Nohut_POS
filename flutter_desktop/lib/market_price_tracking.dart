import 'package:flutter/material.dart';

import 'brand.dart';
import 'market_prices.dart';
import 'operations_ui.dart';
import 'pos_logic.dart';
import 'pos_store.dart';

/// Manager-only product price watch. No purchasing, shopping basket or costs.
class MarketPriceTracking extends StatefulWidget {
  const MarketPriceTracking({
    super.key, required this.state, required this.edit,
    required this.store, this.api,
  });
  final Json state;
  final EditState edit;
  final PosStore store;
  final MarketPriceClient? api;

  @override
  State<MarketPriceTracking> createState() => _MarketPriceTrackingState();
}

class _MarketPriceTrackingState extends State<MarketPriceTracking> {
  late final MarketPriceClient api;
  late final TextEditingController search, latitude, longitude, radius;
  String market = 'BİM', info = 'Konumu girip yakındaki şubeyi seçin.';
  String? branch;
  bool loading = false;
  String alertFilter = 'Tümü';
  List<MarketDepot> branches = const [];
  List<MarketQuote> results = const [];

  static const markets = ['BİM', 'A101', 'Hakmar'];
  static const examples = [
    ('İnci Patates', 'BİM'), ('Limon Tuzu', 'A101'),
    ('Göbek Marul', 'Hakmar'), ('Patlıcan', 'Hakmar'),
  ];

  @override
  void initState() {
    super.initState();
    api = widget.api ?? MarketPriceClient();
    final config = marketPriceState(widget.state);
    search = TextEditingController();
    latitude = TextEditingController(text: (config['latitude'] ?? '').toString());
    longitude = TextEditingController(text: (config['longitude'] ?? '').toString());
    radius = TextEditingController(text: (config['distance'] ?? 4).toString());
  }

  @override
  void dispose() {
    search.dispose(); latitude.dispose(); longitude.dispose(); radius.dispose();
    if (widget.api == null) api.close();
    super.dispose();
  }

  Json get config => marketPriceState(widget.state);
  bool get enabled => config['enabled'] == true;
  double? get lat => double.tryParse(latitude.text.trim().replaceAll(',', '.'));
  double? get lon => double.tryParse(longitude.text.trim().replaceAll(',', '.'));
  double? get km => double.tryParse(radius.text.trim().replaceAll(',', '.'));
  List<MarketDepot> get available => branches.where((d) =>
    d.market.toLowerCase().contains(market.toLowerCase())).toList();

  MarketDepot? get selected {
    for (final depot in available) {
      if (depot.id == branch) return depot;
    }
    return null;
  }

  void notice(String message) {
    if (mounted) setState(() => info = message);
  }

  Future<void> findBranches() async {
    if (!enabled || !validMarketCoordinates(lat, lon, km)) {
      notice('Canlı kaynağı etkinleştirip geçerli konum girin.');
      return;
    }
    setState(() { loading = true; info = 'Şubeler aranıyor...'; });
    try {
      final data = await api.nearby(lat!, lon!, km!);
      if (!mounted) return;
      widget.edit((db) => editMarketPriceState(db, (s) {
        s['latitude'] = lat; s['longitude'] = lon; s['distance'] = km;
      }));
      setState(() {
        branches = data; branch = null; results = [];
        info = data.isEmpty ? 'Şube bulunamadı; veri kapsamı sınırlı olabilir.'
          : 'Bir şube seçin. Deneysel şube listesi eksik olabilir.';
      });
    } catch (e) {
      notice('Şube sorgusu başarısız: ' + e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> findProducts() async {
    if (!enabled || selected == null || search.text.trim().length < 2 ||
        !validMarketCoordinates(lat, lon, km)) {
      notice('Ürün adı, konum ve şube seçin.');
      return;
    }
    final depot = selected!;
    setState(() { loading = true; results = []; info = 'Ürün aranıyor...'; });
    try {
      final found = await api.search(
        keywords: search.text, depotId: depot.id, market: depot.market,
        latitude: lat!, longitude: lon!, distance: km!,
      );
      if (!mounted) return;
      setState(() {
        results = found;
        info = found.isEmpty
          ? 'Eşleşen fiyat bulunamadı. Stokta yok anlamına gelmez.'
          : 'Marka, ambalaj ve gramajı doğrulayarak Takibe Ekle seçin.';
      });
    } catch (e) {
      notice('Ürün sorgusu başarısız: ' + e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> refresh() async {
    if (loading) return;
    setState(() { loading = true; info = 'Fiyatlar kontrol ediliyor...'; });
    try {
      final n = await refreshMarketPrices(widget.store, api, force: true);
      notice(n.updated.toString() + ' güncellendi · ' +
        n.unavailable.toString() + ' bulunamadı · ' +
        n.failed.toString() + ' hata');
    } catch (e) {
      notice('Fiyat kontrolü başarısız: ' + e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> remove(Json item) async {
    final accepted = await showDialog<bool>(context: context,
      builder: (c) => AlertDialog(
        title: const Text('Takipten Çıkar'),
        content: Text((item['title'] ?? '').toString() + ' izlenmesin mi?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false),
            child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(c, true),
            child: const Text('Çıkar')),
        ],
      ));
    if (accepted != true || !mounted) return;
    widget.edit((db) {
      final next = trackedMarketProducts(db)
        ..removeWhere((p) => p['key'] == item['key']);
      editMarketPriceState(db, (s) => s['tracked'] = next);
    });
  }

  String money(int value) =>
    (value / 100).toStringAsFixed(2).replaceAll('.', ',') + ' TL';

  String date(Object? value) {
    final t = DateTime.tryParse((value ?? '').toString())?.toLocal();
    if (t == null) return '—';
    String p(int n) => n.toString().padLeft(2, '0');
    return p(t.day) + '.' + p(t.month) + '.' + t.year.toString() +
      ' ' + p(t.hour) + ':' + p(t.minute);
  }

  Widget _sectionLabel(IconData icon, String title, String caption) =>
      Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Container(
          width: 42, height: 42,
          decoration: BoxDecoration(
            color: const Color(0xffEBF2ED),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, size: 21, color: NohutBrand.green),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(
              fontSize: 20, fontWeight: FontWeight.w800,
              color: NohutBrand.ink,
            )),
            const SizedBox(height: 3),
            Text(caption, style: const TextStyle(
              fontSize: 12, color: NohutBrand.muted,
            )),
          ],
        )),
      ]);

  Widget _pill(String label, IconData icon, Color color, Color background) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: background, borderRadius: BorderRadius.circular(30),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(
            fontSize: 12, color: color, fontWeight: FontWeight.w800,
          )),
        ]),
      );

  Widget watchCard(Json item) {
    final price = item['priceCents'] is int ? item['priceCents'] as int : null;
    final old = item['previousPriceCents'] is int
        ? item['previousPriceCents'] as int : null;
    final down = item['change'] == 'down';
    final up = item['change'] == 'up';
    final changed = (up || down) && old != null && old > 0 && price != null;
    final delta = changed ? (price - old) * 100 / old : 0.0;
    final trendColor = down ? const Color(0xff23734D)
        : up ? const Color(0xffAE4C38) : NohutBrand.muted;
    final trendSurface = down ? const Color(0xffEAF6EE)
        : up ? const Color(0xffFCEFEA) : const Color(0xffF1F3F0);
    final label = down ? 'Fiyat Düştü' : up ? 'Zam Geldi' : 'İlk Fiyat';
    final trendIcon = down ? Icons.south_east_rounded
        : up ? Icons.north_east_rounded : Icons.remove_rounded;
    return Container(
      key: ValueKey('market-' + item['key'].toString()),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: const Color(0xffDCE8DE)),
        boxShadow: const [
          BoxShadow(color: Color(0x0B18372C),
            blurRadius: 18, offset: Offset(0, 5)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(child: Row(children: [
        Container(width: 5, color: trendColor),
        Expanded(child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 17, 12, 15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(width: 44, height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xffF1F4EF),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.local_grocery_store_outlined,
                  color: NohutBrand.green, size: 22),
              ),
              const SizedBox(width: 11),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text((item['title'] ?? '').toString(),
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 17, height: 1.2,
                      fontWeight: FontWeight.w800, color: NohutBrand.ink)),
                  const SizedBox(height: 5),
                  Text((item['market'] ?? '').toString() + '  ·  ' +
                    (item['unit'] ?? '').toString(),
                    style: const TextStyle(fontSize: 12,
                      color: NohutBrand.muted, fontWeight: FontWeight.w600)),
                ],
              )),
              IconButton(
                icon: const Icon(Icons.more_horiz_rounded),
                tooltip: 'Takipten çıkar',
                color: NohutBrand.muted,
                visualDensity: VisualDensity.compact,
                onPressed: () => remove(item),
              ),
            ]),
            const SizedBox(height: 15),
            Row(children: [
              _pill(label, trendIcon, trendColor, trendSurface),
              const Spacer(),
              if (changed)
                Text((delta > 0 ? '+' : '') +
                  delta.toStringAsFixed(1).replaceAll('.', ',') + '%',
                  style: TextStyle(
                    fontSize: 19, fontWeight: FontWeight.w900,
                    color: trendColor,
                  )),
            ]),
            const SizedBox(height: 17),
            Wrap(crossAxisAlignment: WrapCrossAlignment.end,
              spacing: 16, runSpacing: 7, children: [
                if (changed)
                  Column(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('ÖNCEKİ', style: TextStyle(
                        fontSize: 10, letterSpacing: 1.2,
                        fontWeight: FontWeight.w800,
                        color: NohutBrand.muted)),
                      const SizedBox(height: 4),
                      Text(money(old), style: const TextStyle(
                        fontSize: 17, color: NohutBrand.muted,
                        decoration: TextDecoration.lineThrough)),
                    ]),
                Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(changed ? 'YENİ FİYAT' : 'SON FİYAT',
                      style: const TextStyle(
                        fontSize: 10, letterSpacing: 1.2,
                        color: NohutBrand.muted,
                        fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(price == null ? 'Bulunamadı' : money(price),
                      style: const TextStyle(fontSize: 28,
                        height: 1.1, fontWeight: FontWeight.w900,
                        color: NohutBrand.green)),
                  ]),
              ]),
            const SizedBox(height: 16),
            const Divider(height: 1, color: Color(0xffE8EEE8)),
            const SizedBox(height: 11),
            Row(children: [
              const Icon(Icons.storefront_outlined, size: 15,
                color: NohutBrand.muted),
              const SizedBox(width: 5),
              Expanded(child: Text((item['depotName'] ?? '').toString(),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11,
                  color: NohutBrand.muted))),
              const SizedBox(width: 8),
              const Icon(Icons.schedule_outlined, size: 14,
                color: NohutBrand.muted),
              const SizedBox(width: 4),
              Text(date(item['lastCheckedAt']),
                style: const TextStyle(fontSize: 11,
                  color: NohutBrand.muted)),
            ]),
            if (item['discount'] == true) ...[
              const SizedBox(height: 8),
              const Text('Kaynak indirim işareti · Mağazada doğrulanmadı',
                style: TextStyle(fontSize: 11,
                  color: NohutBrand.muted)),
            ],
          ]),
        )),
      ])),
    );
  }

  Widget _alerts(List<Json> watched) {
    final visible = watched.where((item) => alertFilter == 'Tümü' ||
      (alertFilter == 'İndirim' && item['change'] == 'down') ||
      (alertFilter == 'Zam' && item['change'] == 'up')).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _sectionLabel(Icons.notifications_active_outlined,
        'Fiyat Uyarıları', 'Aynı ürün · Aynı market şubesi · Gerçek fiyat değişimi'),
      const SizedBox(height: 13),
      Wrap(spacing: 7, runSpacing: 7, crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final filter in const ['Tümü', 'İndirim', 'Zam'])
            ChoiceChip(
              label: Text(filter == 'Tümü'
                ? 'Tümü  (' + watched.length.toString() + ')'
                : filter == 'İndirim'
                  ? 'Fiyat Düştü  (' +
                      watched.where((p) => p['change'] == 'down').length.toString() + ')'
                  : 'Zam Geldi  (' +
                      watched.where((p) => p['change'] == 'up').length.toString() + ')'),
              selected: alertFilter == filter,
              onSelected: (_) => setState(() => alertFilter = filter),
              avatar: Icon(filter == 'İndirim' ? Icons.south_east_rounded
                : filter == 'Zam' ? Icons.north_east_rounded
                : Icons.widgets_outlined, size: 17),
            ),
        ]),
      const SizedBox(height: 15),
      if ((config['lastRefreshError'] ?? '').toString().isNotEmpty)
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xffFCF2E9),
            borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            const Icon(Icons.info_outline, color: Color(0xff9A6040), size: 19),
            const SizedBox(width: 9),
            Expanded(child: Text(config['lastRefreshError'].toString(),
              style: const TextStyle(fontSize: 12, color: Color(0xff78432A)))),
          ]),
        ),
      if (visible.isEmpty)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 37),
          decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xffDEE8DF))),
          child: Column(children: [
            Container(
              width: 72, height: 72,
              decoration: const BoxDecoration(
                color: Color(0xffEDF4EC), shape: BoxShape.circle),
              child: const Icon(Icons.monitor_heart_outlined,
                color: NohutBrand.green, size: 31),
            ),
            const SizedBox(height: 13),
            Text(watched.isEmpty ? 'Henüz takip edilen ürün yok'
                : 'Bu filtrede fiyat değişimi yok',
              style: const TextStyle(fontSize: 17,
                color: NohutBrand.ink, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(watched.isEmpty
              ? 'Aşağıdan İnci Patates, Limon Tuzu veya sebzeleri takibe ekleyin.'
              : 'Fiyat değiştiğinde burada gösterilecek.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: NohutBrand.muted,
                fontSize: 12)),
          ]),
        )
      else LayoutBuilder(builder: (context, constraints) {
        final cardWidth = constraints.maxWidth >= 980
          ? (constraints.maxWidth - 16) / 2
          : constraints.maxWidth;
        return Wrap(spacing: 16, runSpacing: 16, children: [
          for (final item in visible)
            SizedBox(width: cardWidth, child: watchCard(item)),
        ]);
      }),
    ]);
  }

  Widget _searchPanel(Set<Object?> trackedKeys) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(21),
      border: Border.all(color: const Color(0xffDCE7DF)),
      boxShadow: const [BoxShadow(
        color: Color(0x0718372C), blurRadius: 16, offset: Offset(0, 4))],
    ),
    padding: const EdgeInsets.all(21),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionLabel(Icons.add_circle_outline_rounded,
        'Yeni Ürün Takibe Ekle',
        'Ürün ara, doğru ambalajı ve şubeyi seç, bir kere ekle.'),
      const SizedBox(height: 18),
      TextField(
        controller: search,
        decoration: const InputDecoration(
          hintText: 'Göbek Marul, İnci Patates, Limon Tuzu...',
          prefixIcon: Icon(Icons.search_rounded),
          labelText: 'Ürün adı',
        ),
        onSubmitted: (_) => findProducts(),
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 7, runSpacing: 8, children: [
        for (final example in examples)
          ActionChip(
            label: Text(example.$1 + '  ·  ' + example.$2),
            avatar: const Icon(Icons.north_east_rounded, size: 15),
            onPressed: () => setState(() {
              search.text = example.$1;
              market = example.$2;
              branch = null;
              results = [];
            }),
          ),
      ]),
      const SizedBox(height: 17),
      const Text('MARKET SEÇ',
        style: TextStyle(color: NohutBrand.muted,
          fontWeight: FontWeight.w800, fontSize: 11, letterSpacing: 1.1)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, children: [
        for (final m in markets)
          ChoiceChip(
            label: Text(m), selected: market == m,
            onSelected: (_) => setState(() {
              market = m; branch = null; results = [];
            }),
          ),
      ]),
      const SizedBox(height: 15),
      if (available.isEmpty)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xffF5F7F3),
            borderRadius: BorderRadius.circular(12)),
          child: const Row(children: [
            Icon(Icons.store_mall_directory_outlined,
              size: 19, color: NohutBrand.muted),
            SizedBox(width: 10),
            Expanded(child: Text('Şube seçmek için aşağıdaki kaynak '
              'ayarlarından Şubeleri Bul seçin.',
              style: TextStyle(fontSize: 12, color: NohutBrand.muted))),
          ]),
        )
      else DropdownButtonFormField<String>(
        key: ValueKey(market),
        initialValue: branch,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Market şubesi',
          prefixIcon: Icon(Icons.storefront_outlined)),
        items: [
          for (final depot in available)
            DropdownMenuItem<String>(
              value: depot.id,
              child: Text(depot.name + ' · ' + depot.market,
                overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (value) => setState(() {
          branch = value; results = [];
        }),
      ),
      const SizedBox(height: 13),
      Align(alignment: Alignment.centerRight,
        child: FilledButton.icon(
          onPressed: enabled && !loading && selected != null
            ? findProducts : null,
          icon: const Icon(Icons.search_rounded, size: 18),
          label: const Text('Ürün Ara'),
        )),
      if (loading)
        const Padding(padding: EdgeInsets.only(top: 12),
          child: LinearProgressIndicator()),
      if (info.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 12),
          child: Text(info,
            style: const TextStyle(fontSize: 12, color: NohutBrand.muted))),
      if (results.isNotEmpty) ...[
        const SizedBox(height: 12),
        const Divider(height: 18),
        Text('ARAMA SONUÇLARI  ·  ' + results.length.toString(),
          style: const TextStyle(fontSize: 11,
            fontWeight: FontWeight.w800, letterSpacing: 1,
            color: NohutBrand.muted)),
        const SizedBox(height: 8),
        for (final q in results)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: const Color(0xffF7F9F5),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: const Color(0xffE6EEE7))),
            child: Wrap(
              spacing: 12, runSpacing: 9,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: [
                SizedBox(width: 250,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(q.title, style: const TextStyle(
                        color: NohutBrand.ink, fontSize: 14,
                        fontWeight: FontWeight.w800)),
                      const SizedBox(height: 3),
                      Text(q.market + ' · ' + q.depotName + ' · ' + q.unit,
                        style: const TextStyle(
                          fontSize: 11, color: NohutBrand.muted)),
                    ]),
                ),
                Text(money(q.priceCents),
                  style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w900,
                    color: NohutBrand.green)),
                OutlinedButton.icon(
                  onPressed: trackedKeys.contains(q.key) ? null : () {
                    widget.edit((db) => addTrackedMarketQuote(db, q));
                    notice('Ürün takibe eklendi.');
                  },
                  icon: Icon(trackedKeys.contains(q.key)
                    ? Icons.check_circle_outline : Icons.add_rounded,
                    size: 18),
                  label: Text(trackedKeys.contains(q.key)
                    ? 'Eklendi' : 'Takibe Ekle'),
                ),
              ],
            ),
          ),
      ],
      const SizedBox(height: 15),
      Theme(data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: true,
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          leading: const Icon(Icons.tune_rounded, color: NohutBrand.green),
          title: const Text('Kaynak ve Konum Ayarları',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          subtitle: const Text('Deneysel bağlantı · Şube keşfi',
            style: TextStyle(fontSize: 11)),
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: enabled,
              onChanged: (v) => widget.edit((db) =>
                editMarketPriceState(db, (s) => s['enabled'] = v)),
              title: const Text('Canlı fiyat kaynağı (deneysel)',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              subtitle: const Text('Resmî API değildir. Ticari kullanımdan önce '
                'kaynak izinlerini doğrulayın.', style: TextStyle(fontSize: 11)),
            ),
            Wrap(spacing: 9, runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center, children: [
                SizedBox(width: 145, child: TextField(
                  controller: latitude,
                  decoration: const InputDecoration(
                    labelText: 'Enlem', prefixIcon: Icon(Icons.place_outlined)))),
                SizedBox(width: 145, child: TextField(
                  controller: longitude,
                  decoration: const InputDecoration(
                    labelText: 'Boylam', prefixIcon: Icon(Icons.place_outlined)))),
                SizedBox(width: 110, child: TextField(
                  controller: radius,
                  decoration: const InputDecoration(
                    labelText: 'Yarıçap (km)'))),
                OutlinedButton.icon(
                  onPressed: enabled && !loading ? findBranches : null,
                  icon: const Icon(Icons.location_searching_rounded),
                  label: const Text('Şubeleri Bul')),
              ]),
            const SizedBox(height: 9),
            const SelectableText('Kullanım koşulları: ' + marketPriceTerms,
              style: TextStyle(fontSize: 11, color: NohutBrand.muted)),
          ],
        )),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    final watched = trackedMarketProducts(widget.state);
    final keys = watched.map((p) => p['key']).toSet();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(23),
          gradient: const LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xff123B2D), Color(0xff285F42)]),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 23, 24),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            runSpacing: 18,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 15,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 410),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.radar_rounded,
                        color: NohutBrand.gold, size: 18),
                      const SizedBox(width: 8),
                      Text('NOHUT  /  MARKET RADARI',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.75),
                          letterSpacing: 1.6, fontSize: 11,
                          fontWeight: FontWeight.w800)),
                    ]),
                    const SizedBox(height: 9),
                    const Text('Market Fiyat Takibi',
                      style: TextStyle(
                        fontFamily: NohutBrand.headingFont,
                        color: Colors.white, fontSize: 29)),
                    const SizedBox(height: 7),
                    const Text('BİM · A101 · Hakmar\n'
                      'Güncel fiyatlar, zamlar ve indirimler bir ekranda.',
                      style: TextStyle(color: Color(0xffDFEAE1),
                        height: 1.45, fontSize: 13)),
                  ])),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                _pill(watched.length.toString() + ' ürün takipte',
                  Icons.visibility_outlined,
                  NohutBrand.green, const Color(0xffF3F5ED)),
                const SizedBox(height: 11),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: NohutBrand.green),
                  onPressed: enabled && !loading && watched.isNotEmpty
                    ? refresh : null,
                  icon: const Icon(Icons.sync_rounded),
                  label: const Text('Fiyatları Kontrol Et')),
              ]),
            ],
          ),
        ),
      ),
      const SizedBox(height: 24),
      _alerts(watched),
      const SizedBox(height: 26),
      _searchPanel(keys),
      const SizedBox(height: 14),
      const Text('Fiyatlar mağaza stok ve kampanya garantisi değildir. '
        'Son kontrol zamanı gösterilir; eşleşmeyen verilerden fiyat uyarısı üretilmez.',
        style: TextStyle(fontSize: 11, color: NohutBrand.muted)),
    ]);
  }
}
