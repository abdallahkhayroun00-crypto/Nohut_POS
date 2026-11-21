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
  late final TextEditingController search;
  String storeId = 'a101';
  String info = 'Dört market konumu hazır. Ürün aramak için kaynak şubesini eşleştirin.';
  bool loading = false;
  String alertFilter = 'Tümü';
  bool addProductExpanded = true;
  List<MarketDepot> branches = const [];
  List<MarketQuote> results = const [];

  static const examples = [
    ('İnci Patates', 'bim'), ('Limon Tuzu', 'a101'),
    ('Göbek Marul', 'hakmar-1'), ('Patlıcan', 'hakmar-2'),
  ];

  @override
  void initState() {
    super.initState();
    api = widget.api ?? MarketPriceClient();
    search = TextEditingController();
    addProductExpanded = trackedMarketProducts(widget.state).isEmpty;
  }

  @override
  void dispose() {
    search.dispose();
    if (widget.api == null) api.close();
    super.dispose();
  }

  Json get config => marketPriceState(widget.state);
  bool get enabled => config['enabled'] == true;

  MarketStorePlace get place =>
      nohutStorePlaces.firstWhere((item) => item.id == storeId);

  MarketDepot? get selected {
    final matches = config['storeMatches'];
    if (matches is! Map || matches[storeId] is! Map) return null;
    final saved = matches[storeId] as Map;
    final id = (saved['depotId'] ?? '').toString();
    final market = (saved['market'] ?? '').toString();
    if (id.isEmpty || market.isEmpty || saved['confirmed'] != true ||
        (saved['googleMapsFeatureId'] ?? '').toString() !=
            place.googleMapsFeatureId ||
        marketBrandKey(market) != marketBrandKey(place.market)) return null;
    return MarketDepot(id, market, (saved['name'] ?? market).toString());
  }

  void selectStore(String id) {
    setState(() {
      storeId = id;
      branches = [];
      results = [];
      info = 'Mağaza seçildi. Ürün aramadan önce kaynak şubesini eşleştirin.';
    });
  }

  void notice(String message) {
    if (mounted) setState(() => info = message);
  }

  Future<void> findBranches() async {
    if (loading) return;
    if (!enabled) {
      notice('Canlı veri için Kaynak Ayarları bölümünden kaynağı açın. '
          'Önce kullanım koşullarını doğrulayın.');
      return;
    }
    final target = place;
    setState(() {
      loading = true;
      branches = [];
      results = [];
      info = 'Seçilen mağaza yakınındaki kaynak şubeler aranıyor...';
    });
    try {
      final all = await api.nearby(target.latitude, target.longitude, 4);
      final candidates = matchMarketDepots(
          target, all, maximumDistanceMeters: 300);
      if (!mounted || storeId != target.id) return;
      setState(() {
        branches = candidates;
        info = candidates.isEmpty
          ? 'Kaynakta bu Google Maps konumuna yakın doğrulanabilir '
              'şube bulunamadı. Yanlış markete otomatik bağlanılmadı.'
          : 'Aşağıdaki kaynak şubeyi kontrol edip eşleştirin. '
              'Google Maps konumu tek başına API şube ID değildir.';
      });
    } catch (e) {
      notice('Şube eşleştirmesi başarısız: ' + e.toString() +
          '. Deneysel kaynak çalışmıyor olabilir.');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> confirmBranch(String? depotId) async {
    if (depotId == null || loading) return;
    final candidates = matchMarketDepots(place, branches);
    final matches = candidates.where((d) => d.id == depotId).toList();
    if (matches.length != 1) return;
    final depot = matches.single;
    final target = place;
    final distance = storeDistanceMeters(target.latitude, target.longitude,
        depot.latitude!, depot.longitude!).round();
    final confirmed = await showDialog<bool>(context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Market Fiyatı şubesini bağla'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(target.label, style: const TextStyle(
                fontWeight: FontWeight.w800, fontSize: 18)),
              const SizedBox(height: 5),
              Text(target.address),
              const Divider(height: 25),
              const Text('MARKET FİYATI KAYDI', style: TextStyle(
                color: NohutBrand.muted, fontSize: 11,
                fontWeight: FontWeight.w800)),
              Text(depot.name, style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.bold)),
              Text('Kaynak şube ID: ' + depot.id),
              Text('Haritaya göre yaklaşık ' +
                  distance.toString() + ' m uzaklıkta',
                style: const TextStyle(
                  color: NohutBrand.muted, fontSize: 12)),
              const SizedBox(height: 10),
              const Text('Aynı marketin doğru fiziksel şubesi olduğundan '
                'emin olmadan bağlamayın. Kaynak API adresi doğrulamıyor.',
                style: TextStyle(color: NohutBrand.muted)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Bu şubeyi bağla')),
        ],
      ),
    );
    if (confirmed != true || !mounted || storeId != target.id) return;
    final ok = widget.edit((db) {
      editMarketPriceState(db, (settings) {
        final saved = settings['storeMatches'] is Map
            ? Map<String, dynamic>.from(settings['storeMatches'] as Map)
            : <String, dynamic>{};
        saved[target.id] = {
          'depotId': depot.id,
          'market': depot.market,
          'name': depot.name,
          'storeId': target.id,
          'branchName': target.branchName,
          'address': target.address,
          'googleMapsFeatureId': target.googleMapsFeatureId,
          'distanceMeters': distance,
          'confirmed': true,
          'matchedAt': DateTime.now().toUtc().toIso8601String(),
        };
        settings['storeMatches'] = saved;
        settings['latitude'] = 40.7650391;
        settings['longitude'] = 30.3602224;
        settings['distance'] = 4.0;
      });
    });
    if (ok) {
      setState(() {
        branches = [];
        results = [];
        info = 'Bağlantı kaydedildi: ' + target.label + ' → ' +
            depot.name + '. Artık ürün arayabilirsiniz.';
      });
    }
  }

  Future<void> findProducts() async {
    if (loading) return;
    if (search.text.trim().length < 2) {
      notice('Önce ürün adını yazın.');
      return;
    }
    if (!enabled) {
      notice('Fiyat kaynağı kapalı. Kaynak Ayarları üzerinden '
          'gerekli izinleri doğruladıktan sonra etkinleştirin.');
      return;
    }
    final depot = selected;
    if (depot == null) {
      notice('Önce bu marketi kaynak şubeyle eşleştirin.');
      return;
    }
    final current = place;
    setState(() {
      loading = true;
      results = [];
      info = 'Ürün aranıyor...';
    });
    try {
      final found = await api.search(
        keywords: search.text,
        depotId: depot.id,
        market: depot.market,
        latitude: current.latitude,
        longitude: current.longitude,
        distance: 4,
      );
      if (!mounted || current.id != storeId) return;
      setState(() {
        results = found;
        info = found.isEmpty
          ? 'Bu mağaza için eşleşen fiyat yok. Ürün stokta yok anlamına gelmez.'
          : 'Ürünün markasını ve ambalajını kontrol edip Takibe Ekle seçin.';
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

  Widget _missingProductPhoto() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.add_photo_alternate_outlined,
        size: 30, color: NohutBrand.green),
      const SizedBox(height: 6),
      const Text('FOTOĞRAF EKLE',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 9,
          letterSpacing: 0.7, fontWeight: FontWeight.w800,
          color: NohutBrand.green)),
    ]),
  );

  Widget _productPhoto(Json item, double size) {
    final url = marketImageUrl(item['customImageUrl']) ??
        marketImageUrl(item['imageUrl']);
    return Tooltip(
      message: url == null ? 'Gerçek ürün fotoğrafı ekle'
          : 'Ürün fotoğrafını değiştir',
      child: InkWell(
        onTap: () => _editPhoto(item),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: size, height: size,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: const Color(0xffF3F5EF),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xffE0E9DF))),
          child: Stack(fit: StackFit.expand, children: [
            if (url == null)
              _missingProductPhoto()
            else Image.network(url,
              fit: BoxFit.contain,
              cacheWidth: 450,
              cacheHeight: 450,
              loadingBuilder: (context, child, progress) {
                if (progress == null) return child;
                return const Center(child: SizedBox(
                  height: 20, width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2)));
              },
              errorBuilder: (context, error, stack) =>
                  _missingProductPhoto(),
            ),
            Positioned(right: 6, bottom: 6,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: const [BoxShadow(
                    color: Color(0x11000000), blurRadius: 5)]),
                child: const Padding(
                  padding: EdgeInsets.all(5),
                  child: Icon(Icons.photo_camera_outlined, size: 15,
                    color: NohutBrand.green)))),
          ]),
        ),
      ),
    );
  }

  Future<void> _editPhoto(Json item) async {
    final controller = TextEditingController(
      text: (item['customImageUrl'] ?? '').toString());
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Ürün Fotoğrafı'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((item['title'] ?? '').toString(),
                style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 13),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Gerçek ürün fotoğrafı URL (HTTPS)',
                  hintText: 'https://.../urun.jpg',
                  border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              const Text('Market Fiyatı görseli varsa otomatik gelir. '
                'Eksikse yalnızca bu ürünün gerçek fotoğraf bağlantısını girin.',
                style: TextStyle(color: NohutBrand.muted, fontSize: 12)),
            ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Vazgeç')),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, '__source__'),
            child: const Text('Kaynak Fotoğrafı')),
          FilledButton(
            onPressed: () {
              final url = marketImageUrl(controller.text);
              if (url == null) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Geçerli HTTPS fotoğraf bağlantısı girin.')));
                return;
              }
              Navigator.pop(dialogContext, url);
            },
            child: const Text('Fotoğrafı Kaydet')),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || result == null) return;
    widget.edit((db) {
      final products = trackedMarketProducts(db);
      for (final product in products) {
        if (product['key'] != item['key']) continue;
        if (result == '__source__') {
          product.remove('customImageUrl');
        } else {
          product['customImageUrl'] = result;
        }
        break;
      }
      editMarketPriceState(db, (settings) => settings['tracked'] = products);
    });
  }

  Widget watchCard(Json item) {
    final linkedStores = nohutStorePlaces.where(
      (p) => p.id == (item['storeId'] ?? '').toString()).toList();
    final localStore = linkedStores.isEmpty ? null : linkedStores.single;
    final storeLabel = localStore?.label ??
        (item['market'] ?? '').toString();
    final storeAddress = localStore?.address ??
        (item['depotName'] ?? '').toString();
    final price = item['priceCents'] is int ? item['priceCents'] as int : null;
    final old = item['previousPriceCents'] is int
        ? item['previousPriceCents'] as int : null;
    final down = item['change'] == 'down';
    final up = item['change'] == 'up';
    final changed = (down || up) && price != null && old != null && old > 0;
    final delta = changed ? (price - old) * 100 / old : 0.0;
    final trendColor = down ? const Color(0xff287B51)
        : up ? const Color(0xffAF503F) : NohutBrand.muted;
    final trendBackground = down ? const Color(0xffE5F5E9)
        : up ? const Color(0xffFCEBE6) : const Color(0xffEDF1ED);
    return LayoutBuilder(builder: (context, constraints) {
      final photoSize = constraints.maxWidth < 440 ? 102.0 : 128.0;
      return Container(
        key: ValueKey('market-' + item['key'].toString()),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xffD8E5DB)),
          boxShadow: const [BoxShadow(
            color: Color(0x0B153D2B), blurRadius: 17, offset: Offset(0, 5))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 15, 13, 15),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _productPhoto(item, photoSize),
                const SizedBox(width: 15),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: Text((item['title'] ?? '').toString(),
                          maxLines: 3, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 16,
                            height: 1.15, fontWeight: FontWeight.w900,
                            color: NohutBrand.ink))),
                        IconButton(
                          tooltip: 'Takipten çıkar',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close_rounded,
                            size: 18, color: NohutBrand.muted),
                          onPressed: () => remove(item)),
                      ]),
                    const SizedBox(height: 5),
                    Text(storeLabel + '  ·  ' +
                      (item['unit'] ?? '').toString(),
                      style: const TextStyle(color: NohutBrand.muted,
                        fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 13),
                    Wrap(spacing: 9, runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _pill(down ? 'İndirim' : up ? 'Zam' : 'İlk Fiyat',
                          down ? Icons.south_east_rounded
                            : up ? Icons.north_east_rounded
                            : Icons.remove_rounded,
                          trendColor, trendBackground),
                        if (changed) Text(
                          (delta > 0 ? '+' : '') +
                          delta.toStringAsFixed(1).replaceAll('.', ',') + '%',
                          style: TextStyle(fontSize: 15,
                            color: trendColor, fontWeight: FontWeight.w900)),
                      ]),
                    const SizedBox(height: 12),
                    Wrap(spacing: 11, runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.end, children: [
                        Text(price == null ? 'Fiyat yok' : money(price),
                          style: const TextStyle(fontSize: 28, height: 1.1,
                            color: NohutBrand.green,
                            fontWeight: FontWeight.w900)),
                        if (changed)
                          Text(money(old),
                            style: const TextStyle(
                              decoration: TextDecoration.lineThrough,
                              color: NohutBrand.muted, fontSize: 15)),
                      ]),
                  ],
                )),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 15, vertical: 11),
            color: const Color(0xffF7FAF6),
            child: Row(children: [
              const Icon(Icons.place_outlined,
                size: 15, color: NohutBrand.muted),
              const SizedBox(width: 6),
              Expanded(child: Text(storeAddress,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: NohutBrand.muted, fontSize: 11))),
              const SizedBox(width: 8),
              const Icon(Icons.schedule_outlined,
                size: 14, color: NohutBrand.muted),
              const SizedBox(width: 4),
              Text(date(item['lastCheckedAt']),
                style: const TextStyle(
                  color: NohutBrand.muted, fontSize: 11)),
            ]),
          ),
        ]),
      );
    });
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

  Widget _resultPhoto(MarketQuote quote) {
    final url = quote.imageUrl;
    return Container(
      width: 74, height: 74,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xffF3F5EF),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xffE2EBE1))),
      child: url == null
        ? const Icon(Icons.image_not_supported_outlined,
            color: NohutBrand.muted, size: 27)
        : Image.network(url,
            fit: BoxFit.contain, cacheWidth: 220,
            errorBuilder: (context, error, stack) =>
              const Icon(Icons.image_not_supported_outlined,
                color: NohutBrand.muted, size: 27)),
    );
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
      Row(children: [
        Expanded(child: _sectionLabel(Icons.add_circle_outline_rounded,
          'Yeni Ürün Takibe Ekle',
          '4 market seçimi · Gerçek ürün fotoğrafları · Fiyat takibi')),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: () => setState(
            () => addProductExpanded = !addProductExpanded),
          icon: Icon(addProductExpanded
            ? Icons.keyboard_arrow_up_rounded
            : Icons.add_rounded, size: 19),
          label: Text(addProductExpanded ? 'Kapat' : 'Ürün Ekle'),
        ),
      ]),
      if (addProductExpanded) ...[
      const SizedBox(height: 19),
      const Text('MAĞAZA SEÇ',
        style: TextStyle(color: NohutBrand.muted,
          fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.1)),
      const SizedBox(height: 9),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final candidate in nohutStorePlaces)
          ChoiceChip(
            label: Text(candidate.label),
            selected: storeId == candidate.id,
            avatar: Icon(Icons.storefront_outlined, size: 17,
              color: storeId == candidate.id
                  ? Colors.white : NohutBrand.green),
            onSelected: (_) => selectStore(candidate.id),
          ),
      ]),
      const SizedBox(height: 14),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xffF3F7F2),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: const Color(0xffE0EBDF))),
        child: Wrap(
          spacing: 13, runSpacing: 9,
          crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Icon(Icons.place_outlined,
              color: NohutBrand.green, size: 22),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(place.label,
                style: const TextStyle(color: NohutBrand.ink,
                  fontSize: 14, fontWeight: FontWeight.w800)),
              Text(place.address,
                style: const TextStyle(fontSize: 12,
                  color: NohutBrand.muted)),
              const Text('Serdivan, Sakarya · Google Maps konumu',
                style: TextStyle(
                  fontSize: 11, color: NohutBrand.muted)),
            ]),
            if (selected != null)
              _pill('Kaynak şubesi eşleşti', Icons.check_circle_outline,
                const Color(0xff27734B), const Color(0xffE3F2E8)),
            OutlinedButton.icon(
              onPressed: loading ? null : findBranches,
              icon: const Icon(Icons.link_rounded, size: 17),
              label: Text(selected == null
                  ? 'Şubeyi Eşleştir' : 'Eşleştirmeyi Değiştir'),
            ),
          ],
        ),
      ),
      if (selected != null)
        Padding(
          padding: const EdgeInsets.only(top: 9),
          child: Text('Fiyat kaynağındaki şube: ' + selected!.name,
            style: const TextStyle(
              fontSize: 11, color: NohutBrand.muted)),
        ),
      if (branches.isNotEmpty) ...[
        const SizedBox(height: 13),
        const Text('YAKIN KAYNAK ŞUBELERİ',
          style: TextStyle(fontSize: 11, letterSpacing: 1,
            color: NohutBrand.muted, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        for (final depot in branches)
          Container(
            margin: const EdgeInsets.only(bottom: 7),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xffE3EAE1))),
            child: Wrap(spacing: 10, runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center, children: [
              const Icon(Icons.store_mall_directory_outlined,
                size: 18, color: NohutBrand.green),
              SizedBox(width: 230, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(depot.name, style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700,
                    color: NohutBrand.ink)),
                  Text('Kaynak kaydı · Yaklaşık ' +
                    storeDistanceMeters(place.latitude, place.longitude,
                      depot.latitude!, depot.longitude!)
                      .round().toString() + ' m',
                    style: const TextStyle(
                      fontSize: 11, color: NohutBrand.muted)),
                ])),
              OutlinedButton.icon(
                onPressed: () => confirmBranch(depot.id),
                icon: const Icon(Icons.check_rounded, size: 17),
                label: const Text('Eşleştir'),
              ),
            ]),
          ),
        const Text('Google Maps konumu ile fiyat verisi şubesi '
          'farklı kayıt sistemleridir; doğru şubeyi onaylayın.',
          style: TextStyle(fontSize: 11, color: NohutBrand.muted)),
      ],
      const SizedBox(height: 19),
      TextField(
        controller: search,
        decoration: const InputDecoration(
          hintText: 'Örn. Limon Tuzu, İnci Patates, Göbek Marul...',
          prefixIcon: Icon(Icons.search_rounded),
          labelText: 'Ürün adı',
        ),
        onSubmitted: (_) => findProducts(),
      ),
      const SizedBox(height: 11),
      Wrap(spacing: 7, runSpacing: 7, children: [
        for (final example in examples)
          ActionChip(
            label: Text(example.$1 + '  ·  ' +
              nohutStorePlaces.firstWhere((p) => p.id == example.$2).label),
            avatar: const Icon(Icons.north_east_rounded, size: 15),
            onPressed: () {
              search.text = example.$1;
              selectStore(example.$2);
            },
          ),
      ]),
      const SizedBox(height: 14),
      Align(alignment: Alignment.centerRight,
        child: FilledButton.icon(
          onPressed: loading ? null : findProducts,
          icon: const Icon(Icons.search_rounded, size: 18),
          label: const Text('Ürün Ara'),
        )),
      if (loading)
        const Padding(padding: EdgeInsets.only(top: 11),
          child: LinearProgressIndicator()),
      if (info.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 11),
          child: Text(info,
            style: const TextStyle(
              fontSize: 12, color: NohutBrand.muted))),
      if (results.isNotEmpty) ...[
        const SizedBox(height: 12),
        const Divider(height: 18),
        Text('ARAMA SONUÇLARI · ' + results.length.toString(),
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
            child: Wrap(spacing: 12, runSpacing: 9,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: [
                _resultPhoto(q),
                SizedBox(width: 250,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(q.title, style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w800,
                        color: NohutBrand.ink)),
                      const SizedBox(height: 3),
                      Text(q.market + ' · ' + q.depotName + ' · ' + q.unit,
                        style: const TextStyle(
                          fontSize: 11, color: NohutBrand.muted)),
                    ])),
                Text(money(q.priceCents),
                  style: const TextStyle(fontSize: 16,
                    fontWeight: FontWeight.w900, color: NohutBrand.green)),
                OutlinedButton.icon(
                  onPressed: trackedKeys.contains(q.key) ? null : () {
                    widget.edit((db) => addTrackedMarketQuote(db, q,
                        storeId: storeId));
                    notice('Ürün takibe eklendi.');
                  },
                  icon: Icon(trackedKeys.contains(q.key)
                    ? Icons.check_circle_outline : Icons.add_rounded,
                    size: 18),
                  label: Text(trackedKeys.contains(q.key)
                    ? 'Eklendi' : 'Takibe Ekle'),
                ),
              ]),
          ),
      ],
      const SizedBox(height: 15),
      Theme(data: Theme.of(context).copyWith(
          dividerColor: Colors.transparent),
        child: Material(
          type: MaterialType.transparency,
          child: ExpansionTile(
            initiallyExpanded: false,
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            leading: const Icon(Icons.tune_rounded,
              color: NohutBrand.green),
            title: const Text('Kaynak Ayarları',
              style: TextStyle(fontSize: 14,
                fontWeight: FontWeight.w800)),
            subtitle: const Text('Deneysel fiyat bağlantısı',
              style: TextStyle(fontSize: 11)),
            children: [
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: enabled,
                onChanged: (v) => widget.edit((db) =>
                  editMarketPriceState(db, (s) => s['enabled'] = v)),
                title: const Text('Canlı fiyat kaynağı (deneysel)',
                  style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700)),
                subtitle: const Text('Resmî API değildir. '
                  'Ticari kullanımdan önce kaynak izinlerini doğrulayın.',
                  style: TextStyle(fontSize: 11)),
              ),
              const SelectableText('Kullanım koşulları: ' +
                marketPriceTerms, style: TextStyle(
                  fontSize: 11, color: NohutBrand.muted)),
            ],
          ),
        ),
      ),
      ],
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
