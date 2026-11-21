import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import 'brand.dart';
import 'market_prices.dart';
import 'market_refresh_schedule.dart' as clock_schedule;
import 'market_watch_transfer.dart';
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
  String categoryFilter = 'Tümü';
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
      info = selected == null
        ? 'Mağaza seçildi. Kaynak şubesini eşleştirin.'
        : 'Şube hazır. Ürün arayabilirsiniz.';
    });
  }

  void notice(String message) {
    if (mounted) setState(() => info = message);
  }

  void _toast(String message) {
    if (!mounted) return;
    notice(message);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)));
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

  Color _marketColor(Object? market) {
    switch (marketBrandKey((market ?? '').toString())) {
      case 'bim': return const Color(0xffD52D35);
      case 'a101': return const Color(0xff1674C6);
      case 'hakmar': return const Color(0xff26894C);
      default: return NohutBrand.green;
    }
  }

  Widget _marketPill(String label, Object? market, {bool selected = false}) {
    final color = _marketColor(market);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: selected ? color : color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: selected ? 1 : 0.2))),
      child: Text(label, style: TextStyle(
        color: selected ? Colors.white : color,
        fontWeight: FontWeight.w800, fontSize: 11)),
    );
  }

  Future<void> _selectRefreshTime() async {
    final existing = clock_schedule.validMarketRefreshClock(
      config['refreshAt']);
    final initial = existing == null
        ? const TimeOfDay(hour: 11, minute: 0)
        : TimeOfDay(hour: int.parse(existing.substring(0, 2)),
            minute: int.parse(existing.substring(3, 5)));
    final selected = await showTimePicker(
      context: context,
      initialTime: initial,
      helpText: 'Türkiye Saati · Otomatik Kontrol',
      builder: (pickerContext, child) => MediaQuery(
        data: MediaQuery.of(pickerContext).copyWith(
            alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (!mounted || selected == null) return;
    final chosen = selected.hour.toString().padLeft(2, '0') + ':' +
        selected.minute.toString().padLeft(2, '0');
    widget.edit((db) => editMarketPriceState(db, (settings) {
      settings['refreshAt'] = chosen;
      settings['refreshConfiguredAt'] =
          DateTime.now().toUtc().toIso8601String();
    }));
  }

  void _clearRefreshTime() {
    widget.edit((db) => editMarketPriceState(db, (settings) {
      settings.remove('refreshAt');
      settings.remove('refreshConfiguredAt');
    }));
  }

  Future<void> _createCategory() async {
    // Let the dialog own its editing state until the route animation ends.
    // Disposing a TextEditingController immediately after showDialog returns
    // can crash Flutter while EditableText is still animating out.
    String draft = '';
    final proposed = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Yeni Kategori Oluştur'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 370),
          child: TextField(
            onChanged: (value) => draft = value,
            autofocus: true,
            maxLength: 32,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Kategori adı',
              hintText: 'Örn. Soslar, İçecekler, Temizlik',
              border: OutlineInputBorder()),
            onSubmitted: (value) =>
              Navigator.pop(dialogContext, value.trim()),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Vazgeç')),
          FilledButton(
            onPressed: () =>
              Navigator.pop(dialogContext, draft.trim()),
            child: const Text('Kategori Ekle')),
        ],
      ),
    );
    if (!mounted || proposed == null) return;
    if (!validMarketCategoryName(proposed)) {
      _toast('Kategori adı 2–32 karakter olmalı.');
      return;
    }
    String? error;
    final ok = widget.edit((state) {
      try {
        addMarketWatchCategory(state, proposed);
      } on FormatException catch (e) {
        error = e.message;
      }
    });
    if (error != null) {
      _toast(error!);
    } else if (ok) {
      // Keep cards visible so the manager can assign them to the new group.
      setState(() => categoryFilter = 'Tümü');
      _toast('Kategori eklendi: ' + proposed +
        '. Ürün kartındaki kategori ayarından seçebilirsiniz.');
    } else {
      _toast('Kategori kaydedilemedi.');
    }
  }

  void _setProductCategory(Json entry, String category) {
    widget.edit((db) {
      final products = trackedMarketProducts(db);
      for (final product in products) {
        if (product['key'] == entry['key']) {
          product['category'] = category;
          break;
        }
      }
      editMarketPriceState(db, (settings) => settings['tracked'] = products);
    });
  }

  Future<void> _exportWatchlist() async {
    if (loading) return;
    setState(() => loading = true);
    try {
      const types = <XTypeGroup>[
        XTypeGroup(label: 'Nohut Market Takip', extensions: ['json']),
      ];
      final save = await getSaveLocation(
        suggestedName: 'Nohut_Market_Takip.nohut.json',
        acceptedTypeGroups: types,
      );
      if (save == null) return;
      final content = exportMarketWatch(widget.state);
      await File(save.path).writeAsString(content, flush: true);
      _toast('Market takibi yedeği kaydedildi. Dosyayı dükkân PC’sine aktarın.');
    } catch (e) {
      _toast('Dışa aktarma başarısız: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _importWatchlist() async {
    if (loading) return;
    setState(() => loading = true);
    try {
      const types = <XTypeGroup>[
        XTypeGroup(label: 'Nohut Market Takip', extensions: ['json']),
      ];
      final chosen = await openFile(acceptedTypeGroups: types);
      if (chosen == null || !mounted) return;
      final bytes = await chosen.readAsBytes();
      if (bytes.length > 1024 * 1024) {
        throw const FormatException('Dosya 1 MB sınırından büyük.');
      }
      final backup = parseMarketWatch(utf8.decode(bytes));
      if (!mounted) return;
      final existing = trackedMarketProducts(widget.state).length;
      final preview = planMarketWatchMerge(widget.state, backup);
      final accepted = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Market Takibini Birleştir'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Bu PC: ' + existing.toString() +
                    ' ürün  ·  Dosya: ' + backup.count.toString() + ' ürün'),
                const SizedBox(height: 12),
                Text('+ ' + preview.added.toString() +
                  ' yeni ürün eklenecek',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800, color: NohutBrand.green)),
                Text(preview.duplicates.toString() +
                  ' zaten takipte (atlanacak)'),
                Text(preview.mappingsAdded.toString() +
                  ' yeni market şubesi bağlanacak'),
                Text(preview.categoriesAdded.toString() +
                  ' yeni kategori eklenecek'),
                if (preview.conflicts > 0)
                  Text(preview.conflicts.toString() +
                    ' şube uyuşmazlığı veya sınır nedeniyle atlanacak',
                    style: const TextStyle(color: Colors.deepOrange)),
                const SizedBox(height: 12),
                const Text('Mevcut ürünler, fiyatlar, fotoğraflar, '
                  'kategoriler ve mağaza eşleştirmeleri korunur. '
                  'Sipariş, kasa ve personel verileri değişmez. '
                  'Canlı veri bağlantısı bu PC üzerinde ayrıca etkinleştirilir.',
                  style: TextStyle(fontSize: 12, color: NohutBrand.muted)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Vazgeç')),
            FilledButton(
              onPressed: preview.added > 0 ||
                  preview.mappingsAdded > 0 || preview.categoriesAdded > 0
                ? () => Navigator.pop(ctx, true) : null,
              child: const Text('Ekle ve Birleştir')),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      MarketWatchMergePlan? finalResult;
      final ok = widget.edit((db) {
        finalResult = mergeMarketWatchBackup(db, backup);
      });
      if (ok && mounted) {
        final result = finalResult!;
        setState(() {
          alertFilter = 'Tümü';
          categoryFilter = 'Tümü';
          addProductExpanded = result.total == 0;
          branches = [];
          results = [];
          info = result.added.toString() + ' ürün eklendi · ' +
            result.duplicates.toString() + ' mevcut ürün korundu · ' +
            result.conflicts.toString() + ' uyuşmazlık atlandı.';
        });
        _toast(info);
      } else {
        _toast('Birleştirme kaydedilemedi.');
      }
    } catch (e) {
      _toast('Dosya içe aktarılamadı: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
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

  Widget _missingProductPhoto() => const Center(
    child: Icon(Icons.image_not_supported_outlined,
      size: 27, color: NohutBrand.muted),
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
    final stores = nohutStorePlaces.where(
      (p) => p.id == (item['storeId'] ?? '').toString()).toList();
    final localStore = stores.isEmpty ? null : stores.single;
    final storeLabel = localStore?.label ??
        (item['depotName'] ?? item['market'] ?? '').toString();
    final storeAddress = localStore?.address ??
        (item['depotName'] ?? '').toString();
    final brand = localStore?.market ?? (item['market'] ?? '').toString();
    final marketColor = _marketColor(brand);
    final category = marketProductCategory(item);
    final price = item['priceCents'] is int ? item['priceCents'] as int : null;
    final old = item['previousPriceCents'] is int
      ? item['previousPriceCents'] as int : null;
    final down = item['change'] == 'down';
    final up = item['change'] == 'up';
    final changed = hasMarketPriceChange(item);
    final delta = changed ? (price! - old!) * 100 / old : 0.0;
    final trend = down ? const Color(0xff25784B)
      : up ? const Color(0xffB64637) : NohutBrand.muted;
    return LayoutBuilder(builder: (context, constraints) {
      final narrow = constraints.maxWidth < 360;
      final photoSize = narrow ? 70.0 : 82.0;
      return Container(
        key: ValueKey('market-' + item['key'].toString()),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: marketColor.withValues(alpha: 0.35)), 
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _productPhoto(item, photoSize),
              const SizedBox(width: 10),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: Text((item['title'] ?? '').toString(),
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, height: 1.12,
                        fontWeight: FontWeight.w900, color: NohutBrand.ink))),
                    SizedBox(width: 27, height: 27,
                      child: IconButton(
                        tooltip: 'Takipten çıkar',
                        padding: EdgeInsets.zero,
                        iconSize: 16,
                        icon: const Icon(Icons.close_rounded,
                          color: NohutBrand.muted),
                        onPressed: () => remove(item))),
                  ]),
                  const SizedBox(height: 4),
                  Wrap(spacing: 6, runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center, children: [
                    _marketPill(brand, brand),
                    Text((item['unit'] ?? '').toString(),
                      maxLines: 1, style: const TextStyle(
                        color: NohutBrand.muted, fontSize: 10)),
                  ]),
                  const SizedBox(height: 7),
                  Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                    Expanded(child: Text(price == null ? 'Fiyat yok' : money(price),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 23,
                        color: NohutBrand.green, fontWeight: FontWeight.w900))),
                    if (changed)
                      Text((delta > 0 ? '+' : '') +
                        delta.toStringAsFixed(1).replaceAll('.', ',') + '%',
                        style: TextStyle(color: trend, fontSize: 12,
                          fontWeight: FontWeight.w900)),
                  ]),
                  if (changed) Text(
                    'Önce ' + money(old!),
                    style: const TextStyle(color: NohutBrand.muted,
                      fontSize: 10, decoration: TextDecoration.lineThrough)),
                  if (item['discount'] == true)
                    const Text('Kaynak indirimi doğrulanmadı',
                      style: TextStyle(fontSize: 9,
                        color: NohutBrand.muted)),
                ],
              )),
            ]),
          ),
          Container(
            color: const Color(0xffF7FAF6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(children: [
              if (changed) ...[
                Icon(down ? Icons.south_east_rounded : Icons.north_east_rounded,
                  color: trend, size: 14),
                const SizedBox(width: 4),
                Text(down ? 'İndirim' : 'Zam',
                  style: TextStyle(color: trend, fontSize: 10,
                    fontWeight: FontWeight.w800)),
                const SizedBox(width: 8),
              ],
              Expanded(child: Tooltip(message: storeAddress, child: Text(
                storeLabel, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                  color: marketColor)))),
              const SizedBox(width: 4),
              Text(date(item['lastCheckedAt']),
                style: const TextStyle(color: NohutBrand.muted, fontSize: 9)),
              PopupMenuButton<String>(
                tooltip: 'Kategori değiştir',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 140),
                onSelected: (value) => _setProductCategory(item, value),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                  child: Icon(Icons.tune_rounded,
                    color: NohutBrand.muted, size: 16)),
                itemBuilder: (_) => [
                  for (final choice in marketWatchCategoryOptions(widget.state).skip(1))
                    PopupMenuItem(
                      value: choice,
                      child: Row(children: [
                        if (choice == category)
                          const Icon(Icons.check, size: 15),
                        if (choice == category) const SizedBox(width: 4),
                        Text(choice),
                      ])),
                ],
              ),
            ]),
          ),
        ]),
      );
    });
  }

  Widget _cardGroup(String title, List<Json> products, Color groupColor) {
    if (products.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 17),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            Container(width: 4, height: 21,
              decoration: BoxDecoration(color: groupColor,
                borderRadius: BorderRadius.circular(4))),
            const SizedBox(width: 9),
            Text(title, style: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.w800,
              color: NohutBrand.ink)),
            const SizedBox(width: 8),
            Text('(' + products.length.toString() + ')',
              style: const TextStyle(color: NohutBrand.muted)),
          ])),
        LayoutBuilder(builder: (context, constraints) {
          final width = constraints.maxWidth;
          final columns = width >= 1020 ? 3 : width >= 620 ? 2 : 1;
          final cardWidth = (width - (columns - 1) * 12) / columns;
          return Wrap(spacing: 12, runSpacing: 12, children: [
            for (final item in products)
              SizedBox(width: cardWidth, child: watchCard(item)),
          ]);
        }),
      ]),
    );
  }

  Widget _unreadPriceAlerts() {
    final unread = unreadMarketPriceAlerts(widget.state);
    if (unread.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('market-unread-alerts'),
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xffFFF9F0),
        border: Border.all(color: const Color(0xffECD9B5)),
        borderRadius: BorderRadius.circular(17),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 12, runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween, children: [
          Text('Okunmamış Fiyat Uyarıları (' +
            unread.length.toString() + ')',
            style: const TextStyle(color: NohutBrand.ink,
              fontSize: 15, fontWeight: FontWeight.w900)),
          OutlinedButton.icon(
            onPressed: () => widget.edit((db) => markMarketPriceAlertsRead(
              db, unread.map((item) => item['id'].toString()))),
            icon: const Icon(Icons.done_all, size: 17),
            label: const Text('Tümünü Okundu İşaretle')),
        ]),
        const SizedBox(height: 10),
        for (final alert in unread.take(8))
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(11)),
            child: Row(children: [
              Icon(alert['direction'] == 'down'
                ? Icons.south_east_rounded : Icons.north_east_rounded,
                color: alert['direction'] == 'down'
                  ? const Color(0xff277A4E)
                  : const Color(0xffB3453A),
                size: 22),
              const SizedBox(width: 9),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text((alert['title'] ?? '').toString(),
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 12)),
                  Text((alert['depotName'] ?? alert['market'] ?? '').toString() +
                    ' · ' +
                    money((alert['oldPriceCents'] as num).toInt()) +
                    ' → ' +
                    money((alert['newPriceCents'] as num).toInt()),
                    maxLines: 2, style: const TextStyle(fontSize: 11,
                      color: NohutBrand.muted)),
                ],
              )),
              const SizedBox(width: 8),
              TextButton.icon(
                key: ValueKey('market-read-' + alert['id'].toString()),
                onPressed: () => widget.edit((db) =>
                    markMarketPriceAlertsRead(db, [alert['id'].toString()])),
                icon: const Icon(Icons.done_rounded, size: 15),
                label: const Text('Okundu')),
            ]),
          ),
        if (unread.length > 8)
          Text('+' + (unread.length - 8).toString() +
            ' okunmamış uyarı. Tümünü okundu işaretleyebilirsiniz.',
            style: const TextStyle(fontSize: 11,
              color: NohutBrand.muted)),
      ]),
    );
  }

  Widget _alerts(List<Json> watched) {
    // Real changes ALWAYS lead the page; unchanged products stay together by
    // category. Category and trend tabs both filter the same watch records.
    final categoryItems = watched.where((item) =>
        categoryFilter == 'Tümü' ||
        marketProductCategory(item) == categoryFilter).toList();
    final shown = categoryItems.where((item) =>
        alertFilter == 'Tümü' ||
        (alertFilter == 'İndirim' &&
          hasMarketPriceChange(item) && item['change'] == 'down') ||
        (alertFilter == 'Zam' &&
          hasMarketPriceChange(item) && item['change'] == 'up')).toList();
    final categories = marketWatchCategoryOptions(widget.state)
        .skip(1).toList();
    final changed = orderedMarketWatchProducts(
        shown.where(hasMarketPriceChange).toList(),
        categories: categories);
    final unchanged = orderedMarketWatchProducts(
        shown.where((item) => !hasMarketPriceChange(item)).toList(),
        categories: categories);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _sectionLabel(Icons.notifications_active_outlined,
        'Fiyat Uyarıları',
        'İndirim ve zamlar en üstte · Ürünler kategoriye göre yan yana'),
      const SizedBox(height: 13),
      Wrap(spacing: 7, runSpacing: 7,
        crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final filter in const ['Tümü', 'İndirim', 'Zam'])
            ChoiceChip(
              label: Text(filter == 'Tümü'
                ? 'Tümü  (' + watched.length.toString() + ')'
                : filter == 'İndirim'
                  ? 'Fiyat Düştü  (' +
                    watched.where((p) => hasMarketPriceChange(p) &&
                      p['change'] == 'down').length.toString() + ')'
                  : 'Zam Geldi  (' +
                    watched.where((p) => hasMarketPriceChange(p) &&
                      p['change'] == 'up').length.toString() + ')'),
              selected: alertFilter == filter,
              onSelected: (_) => setState(() => alertFilter = filter),
              avatar: Icon(filter == 'İndirim' ? Icons.south_east_rounded
                : filter == 'Zam' ? Icons.north_east_rounded
                : Icons.widgets_outlined, size: 17),
            ),
        ]),
      const SizedBox(height: 9),
      Wrap(spacing: 7, runSpacing: 7,
        crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final category in marketWatchCategoryOptions(widget.state))
            ChoiceChip(
              label: Text(category + ' (' +
                watched.where((item) =>
                  category == 'Tümü' ||
                  marketProductCategory(item) == category).length.toString() +
                ')'),
              selected: categoryFilter == category,
              onSelected: (_) => setState(() => categoryFilter = category),
            ),
          ActionChip(
            avatar: const Icon(Icons.add_circle_outline_rounded,
              size: 17, color: NohutBrand.green),
            label: const Text('Yeni Kategori',
              style: TextStyle(fontWeight: FontWeight.w800,
                color: NohutBrand.green)),
            onPressed: _createCategory,
          ),
        ]),
      const SizedBox(height: 17),
      if ((config['lastRefreshError'] ?? '').toString().isNotEmpty)
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xffFCF2E9),
            borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            const Icon(Icons.info_outline,
              color: Color(0xff9A6040), size: 19),
            const SizedBox(width: 9),
            Expanded(child: Text(config['lastRefreshError'].toString(),
              style: const TextStyle(fontSize: 12,
                color: Color(0xff78432A)))),
          ]),
        ),
      if (shown.isEmpty)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
          decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xffDEE8DF))),
          child: Column(children: [
            const Icon(Icons.inventory_2_outlined,
              size: 32, color: NohutBrand.green),
            const SizedBox(height: 9),
            Text(watched.isEmpty
              ? 'Henüz takip edilen ürün yok'
              : 'Bu filtrede fiyat değişimi yok',
              style: const TextStyle(fontSize: 16,
                color: NohutBrand.ink, fontWeight: FontWeight.w800)),
          ]),
        )
      else ...[
        if (changed.isNotEmpty)
          _cardGroup('Son Fiyat Değişiklikleri', changed,
            const Color(0xffB45E32)),
        for (final category in categories)
          if (unchanged.any((item) =>
              marketProductCategory(item) == category))
            _cardGroup(category,
              unchanged.where((item) =>
                marketProductCategory(item) == category).toList(),
              const Color(0xff39734D)),
      ],
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
            selectedColor: _marketColor(candidate.market),
            backgroundColor:
              _marketColor(candidate.market).withValues(alpha: 0.06),
            side: BorderSide(color:
              _marketColor(candidate.market).withValues(alpha: 0.32)),
            labelStyle: TextStyle(
              color: storeId == candidate.id
                ? Colors.white : _marketColor(candidate.market),
              fontWeight: FontWeight.w800),
            avatar: Icon(Icons.storefront_outlined, size: 17,
              color: storeId == candidate.id
                  ? Colors.white : _marketColor(candidate.market)),
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
                _marketPill(q.market, q.market),
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
      ],
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
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  const Icon(Icons.schedule_outlined,
                    color: NohutBrand.green, size: 20),
                  const SizedBox(width: 10),
                  const Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Otomatik Fiyat Kontrolü',
                        style: TextStyle(fontSize: 13,
                          fontWeight: FontWeight.w800)),
                      Text('POS açıkken seçilen saatlerde; '
                        'yaklaşık 1 dk gecikme olabilir.',
                        style: TextStyle(
                          color: NohutBrand.muted, fontSize: 11)),
                    ],
                  )),
                  DropdownButton<int>(
                    key: const ValueKey('market-refresh-interval'),
                    value: marketPriceRefreshHours(
                      config['refreshIntervalHours']),
                    items: [
                      for (final hours in marketPriceRefreshChoices)
                        DropdownMenuItem(
                          value: hours,
                          child: Text(hours.toString() + ' Saat')),
                    ],
                    onChanged: (hours) {
                      if (hours == null) return;
                      widget.edit((state) => editMarketPriceState(
                        state, (settings) {
                          settings['refreshIntervalHours'] = hours;
                          settings['refreshConfiguredAt'] =
                              DateTime.now().toUtc().toIso8601String();
                        }));
                    },
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Wrap(
                  spacing: 12, runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Icon(Icons.access_time_rounded,
                      size: 20, color: NohutBrand.green),
                    Text(
                      clock_schedule.validMarketRefreshClock(
                            config['refreshAt']) == null
                        ? 'Başlangıç saati: Seçilmedi'
                        : 'Başlangıç saati: ' +
                          config['refreshAt'].toString() + ' (Türkiye)',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: NohutBrand.ink, fontSize: 13)),
                    OutlinedButton.icon(
                      key: const ValueKey('market-refresh-time'),
                      onPressed: _selectRefreshTime,
                      icon: const Icon(Icons.schedule_rounded, size: 17),
                      label: const Text('Saat Seç')),
                    if (clock_schedule.validMarketRefreshClock(
                            config['refreshAt']) != null)
                      TextButton(
                        onPressed: _clearRefreshTime,
                        child: const Text('Saati Sıfırla')),
                  ],
                ),
              ),
              if (clock_schedule.validMarketRefreshClock(
                  config['refreshAt']) != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    marketPriceRefreshHours(config['refreshIntervalHours']) == 1
                      ? 'Her saat, :' +
                        config['refreshAt'].toString().substring(3) +
                        ' dakikada kontrol edilir.'
                      : 'Kontrol saatleri: ' +
                        clock_schedule.marketRefreshClockLabels(
                          marketPriceRefreshHours(config['refreshIntervalHours']),
                          config['refreshAt'].toString()).join(' · '),
                    style: const TextStyle(
                      color: NohutBrand.muted, fontSize: 11),
                  ),
                ),
              const SelectableText('Kullanım koşulları: ' +
                marketPriceTerms, style: TextStyle(
                  fontSize: 11, color: NohutBrand.muted)),
            ],
          ),
        ),
      ),
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
                    const Text('Fiyatları tek bakışta gör.',
                      style: TextStyle(
                        fontFamily: NohutBrand.headingFont,
                        color: Colors.white, fontSize: 27)),
                    const SizedBox(height: 7),
                    const Text('Gerçek şubeler · Ürün fotoğrafları · Fiyat değişiklikleri',
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
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 7,
                  alignment: WrapAlignment.end, children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Color(0xAAFFFFFF))),
                    onPressed: loading ? null : _exportWatchlist,
                    icon: const Icon(Icons.file_download_outlined, size: 17),
                    label: const Text('Dışa Aktar')),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Color(0xAAFFFFFF))),
                    onPressed: loading ? null : _importWatchlist,
                    icon: const Icon(Icons.file_upload_outlined, size: 17),
                    label: const Text('İçe Aktar')),
                ]),
              ]),
            ],
          ),
        ),
      ),
      const SizedBox(height: 24),
      _unreadPriceAlerts(),
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
