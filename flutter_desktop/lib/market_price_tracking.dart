import 'package:flutter/material.dart';

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

  Widget watchCard(Json item) {
    final price = item['priceCents'] is int ? item['priceCents'] as int : null;
    final old = item['previousPriceCents'] is int
      ? item['previousPriceCents'] as int : null;
    final kind = item['change'];
    final down = kind == 'down', up = kind == 'up';
    final delta = old != null && price != null && old > 0
      ? (price - old) * 100 / old : 0.0;
    final colored = down ? Colors.green.shade700 : up
      ? Colors.red.shade700 : Colors.blueGrey;
    return Card(
      key: ValueKey('market-' + item['key'].toString()),
      child: Padding(padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(down ? Icons.trending_down : up
              ? Icons.trending_up : Icons.sell_outlined, color: colored),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text((item['title'] ?? '').toString(),
                  style: const TextStyle(fontSize: 17,
                    fontWeight: FontWeight.bold)),
                Text((item['market'] ?? '').toString() + ' · ' +
                  (item['depotName'] ?? '').toString() + ' · ' +
                  (item['unit'] ?? '').toString(),
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ],
            )),
            Chip(label: Text(down ? 'Fiyat Düştü'
              : up ? 'Zam Geldi' : 'İlk Fiyat')),
            IconButton(onPressed: () => remove(item),
              tooltip: 'Takipten çıkar', icon: const Icon(Icons.close)),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if ((up || down) && old != null && old > 0)
                Text(money(old), style: const TextStyle(
                  decoration: TextDecoration.lineThrough,
                  color: Colors.black54, fontSize: 16)),
              Text(price == null ? 'Fiyat yok' : money(price),
                style: const TextStyle(fontWeight: FontWeight.bold,
                  fontSize: 25)),
              if ((up || down) && old != null && old > 0 && price != null)
                Text((delta > 0 ? '+' : '') +
                  delta.toStringAsFixed(1).replaceAll('.', ',') + '%',
                  style: TextStyle(color: colored,
                    fontWeight: FontWeight.bold)),
            ]),
          const SizedBox(height: 8),
          Text('Son kontrol: ' + date(item['lastCheckedAt']) +
            ((up || down) ? ' · Son değişim: ' +
              date(item['lastChangedAt']) : ''),
            style: const TextStyle(color: Colors.black54, fontSize: 11)),
          if (item['discount'] == true)
            const Text('Kaynak indirim işareti (mağazada doğrulanmadı).',
              style: TextStyle(fontSize: 11, color: Colors.black54)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final watched = trackedMarketProducts(widget.state);
    final keys = watched.map((p) => p['key']).toSet();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Market Fiyat Takibi',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            Text('BİM · A101 · Hakmar — Zam ve indirim uyarıları',
              style: TextStyle(color: Colors.black54)),
          ])),
        FilledButton.icon(
          onPressed: enabled && !loading && watched.isNotEmpty ? refresh : null,
          icon: const Icon(Icons.refresh),
          label: const Text('Fiyatları Kontrol Et')),
      ]),
      const SizedBox(height: 12),
      Card(child: Padding(padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Canlı fiyat kaynağı (deneysel)'),
            subtitle: const Text('Resmî API değildir. Kaynak kullanım '
              'koşullarını işletme ayrıca doğrulamalıdır.'),
            value: enabled,
            onChanged: (v) => widget.edit((db) =>
              editMarketPriceState(db, (s) => s['enabled'] = v)),
          ),
          const SelectableText('Koşullar: ' + marketPriceTerms,
            style: TextStyle(fontSize: 11, color: Colors.black54)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            SizedBox(width: 145, child: TextField(controller: latitude,
              decoration: const InputDecoration(labelText: 'Enlem',
                border: OutlineInputBorder()))),
            SizedBox(width: 145, child: TextField(controller: longitude,
              decoration: const InputDecoration(labelText: 'Boylam',
                border: OutlineInputBorder()))),
            SizedBox(width: 115, child: TextField(controller: radius,
              decoration: const InputDecoration(labelText: 'Yarıçap km',
                border: OutlineInputBorder()))),
            OutlinedButton.icon(onPressed: enabled && !loading
              ? findBranches : null,
              icon: const Icon(Icons.location_on_outlined),
              label: const Text('Şubeleri Bul')),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 7, children: [
            for (final m in markets) ChoiceChip(
              label: Text(m), selected: market == m,
              onSelected: (_) => setState(() {
                market = m; branch = null; results = [];
              }),
            ),
          ]),
          if (available.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Önce yakındaki şubeleri arayın.',
                style: TextStyle(fontSize: 12, color: Colors.black54)))
          else DropdownButtonFormField<String>(
            key: ValueKey(market),
            initialValue: branch,
            decoration: const InputDecoration(
              labelText: 'Market Şubesi', border: OutlineInputBorder()),
            items: [
              for (final depot in available)
                DropdownMenuItem(value: depot.id,
                  child: Text(depot.name + ' · ' + depot.market)),
            ],
            onChanged: (v) => setState(() { branch = v; results = []; }),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final example in examples)
              ActionChip(label: Text(example.$1 + ' · ' + example.$2),
                onPressed: () => setState(() {
                  search.text = example.$1;
                  market = example.$2; branch = null; results = [];
                })),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: search,
              decoration: const InputDecoration(
                hintText: 'Ürün ara: Göbek Marul, Patlıcan...',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder()),
              onSubmitted: (_) => findProducts())),
            const SizedBox(width: 8),
            FilledButton(onPressed: enabled && !loading && selected != null
              ? findProducts : null, child: const Text('Ürün Ara')),
          ]),
          if (loading) const LinearProgressIndicator(),
          Padding(padding: const EdgeInsets.only(top: 10),
            child: Text(info, style: const TextStyle(
              fontSize: 12, color: Colors.black54))),
          for (final q in results)
            ListTile(
              title: Text(q.title),
              subtitle: Text(q.market + ' · ' + q.depotName + ' · ' + q.unit),
              trailing: Wrap(spacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(money(q.priceCents)),
                  OutlinedButton.icon(
                    onPressed: keys.contains(q.key) ? null : () {
                      widget.edit((db) => addTrackedMarketQuote(db, q));
                      notice('Ürün takibe eklendi.');
                    },
                    icon: Icon(keys.contains(q.key) ? Icons.check : Icons.add),
                    label: Text(keys.contains(q.key)
                      ? 'Eklendi' : 'Takibe Ekle'),
                  ),
                ]),
            ),
        ]),
      )),
      const SizedBox(height: 16),
      Text('Fiyat Uyarıları · ' + watched.length.toString() + ' ürün',
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      if ((config['lastRefreshError'] ?? '').toString().isNotEmpty)
        Text(config['lastRefreshError'].toString(),
          style: const TextStyle(color: Colors.deepOrange)),
      if (watched.isEmpty)
        const Card(child: Padding(padding: EdgeInsets.all(18),
          child: Text('Henüz ürün eklenmedi. Ürün arayıp Takibe Ekle seçin.')))
      else for (final item in watched) watchCard(item),
      const Text('Fiyat, stok veya kampanya garantisi değildir. '
        'Fiyat değişimi aynı ürün ve aynı şube için hesaplanır.',
        style: TextStyle(color: Colors.black54, fontSize: 11)),
    ]);
  }
}
