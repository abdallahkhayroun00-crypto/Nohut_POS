import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:nohut_core/report_period.dart';

import 'brand.dart';
import 'finance_logic.dart';
import 'finance_pdf.dart';
import 'market_prices.dart';
import 'operations_ui.dart' show askFields, EditState;
import 'order_reporting.dart';
import 'pos_logic.dart';

/// Owner-facing operational finance UI. This is a local management estimate,
/// not a fiscal invoice, bank transfer, inventory/COGS, or tax calculation.
class FinancePanel extends StatefulWidget {
  const FinancePanel({
    super.key, required this.state, required this.edit, this.onlineWarning,
    this.onOpenMarketTracking,
  });
  final Json state;
  final EditState edit;
  final String? onlineWarning;
  final VoidCallback? onOpenMarketTracking;

  @override
  State<FinancePanel> createState() => _FinancePanelState();
}

class _FinancePanelState extends State<FinancePanel> {
  String tab = 'Genel Bakış';
  String month = _today().substring(0, 7);
  String day = _today();
  String week = weekStartOf(_today());
  bool _pdfBusy = false;

  static String _today() => istanbulDay(DateTime.now().toUtc());
  static String _try(double value) => value.toStringAsFixed(2);
  static String _tl(int cents) => (cents / 100).toStringAsFixed(2);
  static String _quantity(int milli) {
    var text = (milli / 1000).toStringAsFixed(3);
    while (text.contains('.') && text.endsWith('0')) {
      text = text.substring(0, text.length - 1);
    }
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
    return text;
  }

  static double _decimal(String value, {bool allowZero = false}) {
    final n = double.tryParse(value.trim().replaceAll(',', '.'));
    if (n == null || !n.isFinite || n < (allowZero ? 0 : 0.001) ||
        n > 100000000) {
      throw const FormatException('Miktar veya fiyat geçersiz.');
    }
    return n;
  }
  static int _price(String text, {bool allowZero = false}) {
    final v = _decimal(text, allowZero: allowZero);
    final cents = (v * 100).round();
    if (cents == 0 && !allowZero) {
      throw const FormatException('Fiyat en az 0,01 ₺ olmalı.');
    }
    return cents;
  }
  static int _qty(String text) {
    final milli = (_decimal(text) * 1000).round();
    if (milli < 1) throw const FormatException('Miktar 0 olamaz.');
    return milli;
  }

  void _shiftMonth(int delta) {
    final d = DateTime.parse(month + '-01');
    final next = DateTime(d.year, d.month + delta);
    setState(() {
      month = next.toIso8601String().substring(0, 7);
    });
  }

  void _shiftDay(int delta) {
    final d = DateTime.parse(day).add(Duration(days: delta));
    setState(() => day = d.toIso8601String().substring(0, 10));
  }

  void _shiftWeek(int delta) {
    final d = DateTime.parse(week).add(Duration(days: delta * 7));
    setState(() => week = d.toIso8601String().substring(0, 10));
  }

  Future<void> _exportPdfReport() async {
    if (_pdfBusy) return;
    var selected = 'Bu Ay';
    var range = ReportPeriod.preset(selected);
    String? error;
    final request = await showDialog<ReportPeriod>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, redraw) => AlertDialog(
          title: const Text('Tam Yönetim Raporu · Tek PDF'),
          content: SizedBox(width: 460, child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('Tüm finans, personel, masa, sipariş, ürün, online satış, '
                  'malzeme ve kasa bilgileri tek A4 PDF dosyasında.'),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(key: ValueKey('report-preset-' + selected), initialValue: selected,
                  decoration: const InputDecoration(labelText: 'Rapor dönemi'),
                  isExpanded: true,
                  items: [for (final p in ReportPeriod.presets)
                    DropdownMenuItem(value: p, child: Text(p))],
                  onChanged: (v) => redraw(() {
                    selected = v ?? 'Bu Ay';
                    if (selected != 'Özel Tarih') range = ReportPeriod.preset(selected);
                    error = null;
                  })),
                const SizedBox(height: 12),
                for (final start in [true, false])
                  OutlinedButton.icon(
                    icon: const Icon(Icons.calendar_today_outlined),
                    label: Text((start ? 'Başlangıç: ' : 'Bitiş: ') +
                      (start ? range.from : range.to)),
                    onPressed: () async {
                      final d = await showDatePicker(context: context,
                        initialDate: ReportPeriod.parse(start ? range.from : range.to),
                        firstDate: DateTime(2000), lastDate: ReportPeriod.today());
                      if (d != null && context.mounted) redraw(() {
                        selected = 'Özel Tarih';
                        range = ReportPeriod(start ? ReportPeriod.day(d) : range.from,
                          start ? range.to : ReportPeriod.day(d));
                        error = null;
                      });
                    }),
                const Text('Yöneticiye özel: personel maaşları ve işletme bilgileri içerir. '
                  'Kısmi ay giderleri ve manuel aylık gelirler ayrı gösterilir.',
                  style: TextStyle(color: Color(0xffa25b39), fontSize: 12)),
                if (error != null) Text(error!, style: const TextStyle(color: Colors.red)),
              ]))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Vazgeç')),
            FilledButton.icon(key: const ValueKey('finance-pdf-create'),
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('Tek PDF Oluştur'),
              onPressed: () {
                try {
                  range.validate();
                  Navigator.pop(dialogContext, range);
                } on FormatException catch (e) {
                  redraw(() => error = e.message);
                }
              }),
          ],
        )),
    );
    if (request == null || !mounted) return;
    try {
      final location = await getSaveLocation(
        suggestedName: request.fileName,
        acceptedTypeGroups: const [
          XTypeGroup(label: 'PDF', extensions: ['pdf']),
        ],
      );
      if (location == null || !mounted) return;
      var outputPath = location.path;
      if (!outputPath.toLowerCase().endsWith('.pdf')) {
        outputPath += '.pdf';
      }
      final output = File(outputPath);
      if (await output.exists()) {
        if (!mounted) return;
        final overwrite = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Dosya zaten var'),
            content: const Text(
              'Seçtiğiniz PDF dosyası mevcut. '
              'Üzerine yazmak istediğinize emin misiniz?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Vazgeç')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Üzerine Yaz')),
            ],
          ),
        );
        if (overwrite != true || !mounted) return;
      }
      setState(() => _pdfBusy = true);
      final pdfBytes = await generateManagementPdf(widget.state, request);
      await output.writeAsBytes(pdfBytes, flush: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('PDF kaydedildi: ' + output.path),
        duration: const Duration(seconds: 6),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('PDF oluşturulamadı: $e'),
        duration: const Duration(seconds: 6),
      ));
    } finally {
      if (mounted) setState(() => _pdfBusy = false);
    }
  }

  Widget _heading(String text, {Widget? action}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      children: [
        Expanded(child: Text(text,
          style: Theme.of(context).textTheme.titleLarge)),
        if (action != null) action,
      ],
    ),
  );

  Widget _metric(String name, String value, IconData icon, {
    bool important = false,
  }) => SizedBox(
    width: 205,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: NohutBrand.green, size: 21),
            const SizedBox(height: 10),
            Text(name, style: const TextStyle(
              color: NohutBrand.muted, fontSize: 12)),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value,
                style: TextStyle(fontSize: important ? 25 : 20,
                  color: NohutBrand.green,
                  fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _notice(String message) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xfffff5e4),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(message, style: const TextStyle(
      color: Color(0xff795832), fontSize: 12)),
  );

  void _error(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  static Color _marketAccent(String brand) => switch (brand) {
    'BİM' => const Color(0xffCA283C),
    'A101' => const Color(0xff1686B5),
    'Hakmar' => const Color(0xff268052),
    _ => const Color(0xff6F7180),
  };

  Widget _marketBadge(String brand) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: _marketAccent(brand).withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: _marketAccent(brand).withValues(alpha: 0.35)),
    ),
    child: Text(brand, style: TextStyle(
      color: _marketAccent(brand), fontSize: 12,
      fontWeight: FontWeight.w800)),
  );

  Future<String?> _chooseMaterialMarket() => showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Önce Marketi Seçin'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Bugünkü malzemeleri nereden aldınız?',
              style: TextStyle(color: NohutBrand.muted)),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final store in materialStores)
                  SizedBox(
                    width: 190,
                    height: 66,
                    child: OutlinedButton(
                      key: ValueKey('finance-store-$store'),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: _marketAccent(store)
                          .withValues(alpha: 0.09),
                        side: BorderSide(
                          color: _marketAccent(store).withValues(alpha: 0.6),
                          width: 1.5),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13)),
                      ),
                      onPressed: () => Navigator.pop(ctx, store),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(store == 'Diğer'
                            ? Icons.add_business_outlined
                            : Icons.storefront_outlined,
                            color: _marketAccent(store)),
                          const SizedBox(width: 8),
                          Text(store, style: TextStyle(
                            color: _marketAccent(store),
                            fontSize: 17, fontWeight: FontWeight.w900)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx),
          child: const Text('Vazgeç')),
      ],
    ),
  );

  Future<void> _materialForm([Json? existing]) async {
    final selected = existing == null
        ? await _chooseMaterialMarket()
        : materialPurchaseStore(existing);
    if (selected == null || !mounted) return;
    String selectedStore = selected;
    final tracked = trackedMarketProducts(widget.state);
    final byKey = <String, Json>{
      for (final p in tracked)
        if ((p['key'] ?? '').toString().isNotEmpty)
          p['key'].toString(): p,
    };
    String chosen = existing?['marketKey'] is String &&
      byKey.containsKey(existing!['marketKey']) ?
      existing['marketKey'] as String : '__manual__';
    String unit = (existing?['unit'] ?? 'kg').toString();
    String method = (existing?['paymentMethod'] ?? 'Nakit').toString();
    final date = TextEditingController(text: (existing?['date'] ?? day).toString());
    final name = TextEditingController(text: (existing?['title'] ?? '').toString());
    final quantity = TextEditingController(text: existing == null ?
      '1' : _quantity(existing['quantityMilli'] as int));
    final price = TextEditingController(text: existing == null ?
      '' : _tl(existing['pricePerUnitCents'] as int));
    String discountType = (existing?['discountType'] ?? 'Yok').toString();
    if (!materialDiscountTypes.contains(discountType)) discountType = 'Yok';
    final discount = TextEditingController(text:
      existing?['discountValue'] is int && discountType != 'Yok'
        ? _tl(existing!['discountValue'] as int) : '0');
    final notes = TextEditingController(text: (existing?['note'] ?? '').toString());
    final search = TextEditingController();
    final otherStore = TextEditingController(text: selectedStore == 'Diğer' &&
      existing != null ? (existing['market'] ?? '').toString() : '');
    String? error;
    var onlineBusy = false;
    var onlineStatus = '';
    var sourceNeedsSetup = false;
    var dialogOpen = true;
    List<MarketQuote> onlineResults = <MarketQuote>[];
    Map<String, String> onlineStoreIds = <String, String>{};
    void selectQuote(String key) {
      chosen = key;
      final item = byKey[key];
      if (item == null) return;
      final quote = marketUnitQuote(item);
      name.text = (item['title'] ?? '').toString();
      if (selectedStore == 'Diğer') {
        otherStore.text = (item['market'] ?? '').toString();
      }
      if (quote == null) {
        price.clear();
      } else {
        unit = quote.unit;
        price.text = _tl(quote.priceCents);
      }
    }

    Future<void> searchUntracked(StateSetter updateDialog) async {
      if (onlineBusy || !dialogOpen || !mounted) return;
      final query = search.text.trim();
      final store = selectedStore;
      void notify(String message, {bool setup = false}) {
        if (!dialogOpen || !mounted) return;
        updateDialog(() {
          onlineStatus = message;
          sourceNeedsSetup = setup;
          onlineResults = <MarketQuote>[];
          onlineStoreIds = <String, String>{};
        });
      }
      if (query.length < 2) {
        notify('Kaynakta aramak için en az 2 harf yazın.');
        return;
      }
      if (store == 'Diğer') {
        notify('Diğer marketler için bağlı bir fiyat kaynağı yok. '
          'Manuel Ürün Ekle ile alış kaydedebilirsiniz.');
        return;
      }
      final settings = marketPriceState(widget.state);
      if (settings['enabled'] != true) {
        notify('Market fiyat kaynağı etkin değil. Market Fiyat Takibi '
          '→ Kaynak Ayarları bölümünden etkinleştirin.', setup: true);
        return;
      }
      final matches = settings['storeMatches'];
      final sources = <(MarketStorePlace, String, String)>[];
      if (matches is Map) {
        for (final place in nohutStorePlaces.where(
            (p) => materialStoreFromBrand(p.market) == store)) {
          final raw = matches[place.id];
          if (raw is! Map ||
              raw['confirmed'] != true ||
              (raw['googleMapsFeatureId'] ?? '').toString() !=
                place.googleMapsFeatureId) continue;
          final depotId = (raw['depotId'] ?? '').toString();
          final market = (raw['market'] ?? '').toString();
          if (depotId.isEmpty ||
              marketBrandKey(market) != marketBrandKey(place.market)) {
            continue;
          }
          sources.add((place, depotId, market));
        }
      }
      if (sources.isEmpty) {
        notify('Bu marketin doğrulanmış fiyat kaynağı şubesi yok. '
          'Önce Market Fiyat Takibi → Şubeyi Eşleştir.', setup: true);
        return;
      }
      updateDialog(() {
        onlineBusy = true;
        sourceNeedsSetup = false;
        onlineStatus = 'Kaynakta ürün aranıyor…';
        onlineResults = <MarketQuote>[];
        onlineStoreIds = <String, String>{};
      });
      final client = MarketPriceClient();
      final found = <MarketQuote>[];
      final sourceIds = <String, String>{};
      String? firstError;
      try {
        for (final source in sources) {
          // Only operator-confirmed depot IDs, never Google Maps location IDs.
          try {
            final quotes = await client.search(
              keywords: query,
              depotId: source.$2,
              market: source.$3,
              latitude: source.$1.latitude,
              longitude: source.$1.longitude,
              distance: 4,
            );
            for (final quote in quotes) {
              if (sourceIds.containsKey(quote.key)) continue;
              found.add(quote);
              sourceIds[quote.key] = source.$1.id;
            }
          } catch (e) {
            firstError ??= e.toString();
          }
        }
      } finally {
        client.close();
      }
      if (!dialogOpen || !mounted) return;
      updateDialog(() {
        onlineBusy = false;
        if (store != selectedStore || query != search.text.trim()) {
          onlineResults = <MarketQuote>[];
          onlineStoreIds = <String, String>{};
          onlineStatus = '';
          return;
        }
        onlineResults = found;
        onlineStoreIds = sourceIds;
        onlineStatus = found.isNotEmpty
          ? 'Ürün ambalajını ve şubesini kontrol edin; '
            'Takip Et ile Market Fiyat Takibi listesine ekleyin.'
          : firstError != null
            ? 'Fiyat sorgusu başarısız: $firstError. '
              'Ürün yine de manuel eklenebilir.'
            : 'Kaynakta eşleşen ürün bulunamadı. '
              'Bu, ürün stokta yok demek değildir.';
      });
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, changeDialog) {
          int? total, subtotal, discountAmount;
          try {
            final count = _qty(quantity.text);
            final rate = _price(price.text);
            subtotal = materialTotalCents(count, rate);
            final value = discountType == 'Yok' ? 0 :
              _price(discount.text, allowZero: true);
            discountAmount = materialDiscountCents(
              subtotal, discountType, value);
            total = subtotal - discountAmount;
          } on FormatException { /* show blank total while typing */ }
          final market = byKey[chosen];
          final products = marketTrackedForMaterial(widget.state,
            selectedStore, query: search.text);
          final activeOnline = onlineResults.where((q) =>
            materialStoreFromBrand(q.market) == selectedStore).toList();
          return AlertDialog(
            title: Text(existing == null ?
              'Günlük Malzeme Alımı' : 'Malzeme Kaydını Düzenle'),
            content: SizedBox(
              width: 530,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Market · Önce seçildi',
                      style: TextStyle(color: NohutBrand.muted, fontSize: 12)),
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        for (final store in materialStores)
                          ChoiceChip(
                            key: ValueKey('finance-store-chip-$store'),
                            label: Text(store),
                            avatar: store == selectedStore
                              ? Icon(Icons.check, size: 16,
                                  color: _marketAccent(store))
                              : null,
                            selected: selectedStore == store,
                            selectedColor: _marketAccent(store)
                              .withValues(alpha: 0.15),
                            side: BorderSide(
                              color: _marketAccent(store).withValues(
                                alpha: selectedStore == store ? 0.85 : 0.32)),
                            labelStyle: TextStyle(
                              color: _marketAccent(store),
                              fontWeight: FontWeight.w800),
                            onSelected: (_) => changeDialog(() {
                              if (store == selectedStore) return;
                              selectedStore = store;
                              chosen = '__manual__';
                              search.clear();
                              name.clear();
                              price.clear();
                              otherStore.clear();
                              unit = 'kg';
                              onlineResults = <MarketQuote>[];
                              onlineStoreIds = <String, String>{};
                              onlineStatus = '';
                              sourceNeedsSetup = false;
                              error = null;
                            }),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('finance-material-search'),
                      controller: search,
                      onChanged: (_) => changeDialog(() {
                        onlineResults = <MarketQuote>[];
                        onlineStoreIds = <String, String>{};
                        onlineStatus = '';
                        sourceNeedsSetup = false;
                      }),
                      decoration: InputDecoration(
                        labelText: '$selectedStore · Ürün Ara',
                        hintText: 'Malzeme adı yazın…',
                        prefixIcon: Icon(Icons.search,
                          color: _marketAccent(selectedStore)),
                        suffixIcon: search.text.isEmpty ? null :
                          IconButton(
                            tooltip: 'Aramayı temizle',
                            onPressed: () => changeDialog(search.clear),
                            icon: const Icon(Icons.close)),
                        filled: true,
                        fillColor: _marketAccent(selectedStore)
                          .withValues(alpha: 0.045),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: _marketAccent(selectedStore)
                              .withValues(alpha: 0.55),
                            width: 1.3)),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: _marketAccent(selectedStore),
                            width: 2)),
                      ),
                    ),
                    const SizedBox(height: 7),
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxHeight: 195),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: _marketAccent(selectedStore)
                            .withValues(alpha: 0.22)),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          ListTile(
                            key: const ValueKey('finance-manual-material'),
                            dense: true,
                            leading: Icon(Icons.edit_note,
                              color: _marketAccent(selectedStore)),
                            title: const Text('Manuel Ürün Ekle'),
                            subtitle: const Text(
                              'Listede yoksa adı, miktarı ve fiyatı yazın'),
                            selected: chosen == '__manual__',
                            onTap: () => changeDialog(() {
                              chosen = '__manual__';
                              name.clear();
                              price.clear();
                              unit = 'kg';
                            }),
                          ),
                          if (products.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(12),
                              child: Text(
                                'Bu markette eşleşen takip ürünü yok. '
                                'Manuel Ürün Ekle kullanabilirsiniz.',
                                style: TextStyle(
                                  color: NohutBrand.muted, fontSize: 12)),
                            ),
                          for (final item in products.take(30))
                            ListTile(
                              key: ValueKey('finance-market-product-' +
                                (item['key'] ?? '').toString()),
                              dense: true,
                              selected: chosen == item['key'],
                              selectedTileColor: _marketAccent(selectedStore)
                                .withValues(alpha: 0.08),
                              leading: _marketBadge(selectedStore),
                              title: Text((item['title'] ?? '').toString(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                (item['depotName'] ?? '').toString() + ' · ' +
                                (item['unit'] ?? '').toString(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                              trailing: Text(item['priceCents'] is int
                                ? formatTry(item['priceCents'] as int)
                                : 'Fiyat yok',
                                style: TextStyle(
                                  color: _marketAccent(selectedStore),
                                  fontWeight: FontWeight.w700)),
                              onTap: () => changeDialog(() {
                                selectQuote(item['key'].toString());
                              }),
                            ),
                          if (products.length > 30)
                            Padding(
                              padding: const EdgeInsets.all(10),
                              child: Text(products.length.toString() +
                                ' sonuçtan ilk 30 gösteriliyor. Aramayı daraltın.',
                                style: const TextStyle(
                                  fontSize: 11, color: NohutBrand.muted)),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Text('Takip listesinde bulamadınız mı?',
                            style: TextStyle(
                              color: _marketAccent(selectedStore),
                              fontSize: 12, fontWeight: FontWeight.w700)),
                        ),
                        OutlinedButton.icon(
                          key: const ValueKey('finance-market-live-search'),
                          onPressed: onlineBusy ? null :
                            () => searchUntracked(changeDialog),
                          icon: onlineBusy
                            ? const SizedBox(
                                width: 15, height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2))
                            : const Icon(Icons.travel_explore, size: 18),
                          label: const Text('Kaynakta Ara'),
                        ),
                      ],
                    ),
                    if (onlineStatus.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(onlineStatus,
                          style: const TextStyle(
                            fontSize: 12, color: NohutBrand.muted)),
                      ),
                    if (sourceNeedsSetup && widget.onOpenMarketTracking != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const ValueKey('finance-open-market-tracking'),
                          icon: const Icon(Icons.open_in_new),
                          onPressed: () {
                            Navigator.pop(dialogContext);
                            widget.onOpenMarketTracking!();
                          },
                          label: const Text('Market Fiyat Takibi’ne Git'),
                        ),
                      ),
                    for (final quote in activeOnline.take(20))
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(9),
                          child: Row(
                            children: [
                              _marketBadge(selectedStore),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(quote.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700)),
                                    Text(quote.depotName + ' · ' + quote.unit +
                                      ' · ' + formatTry(quote.priceCents) +
                                      (quote.discount == true
                                        ? ' · İndirim etiketi' : ''),
                                      style: const TextStyle(
                                        fontSize: 11, color: NohutBrand.muted)),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 7),
                              OutlinedButton(
                                key: ValueKey('finance-track-' + quote.key),
                                onPressed: () {
                                  final storeId = onlineStoreIds[quote.key];
                                  if (storeId == null) return;
                                  if (!byKey.containsKey(quote.key)) {
                                    final ok = widget.edit((db) =>
                                      addTrackedMarketQuote(db, quote,
                                        storeId: storeId));
                                    if (!ok) return;
                                  }
                                  byKey[quote.key] = {
                                    'key': quote.key,
                                    'title': quote.title,
                                    'market': quote.market,
                                    'depotName': quote.depotName,
                                    'unit': quote.unit,
                                    'priceCents': quote.priceCents,
                                  };
                                  changeDialog(() {
                                    selectQuote(quote.key);
                                    search.clear();
                                    onlineResults = <MarketQuote>[];
                                    onlineStoreIds = <String, String>{};
                                    onlineStatus = 'Ürün takibe eklendi '
                                      've alış formuna seçildi.';
                                  });
                                },
                                child: Text(byKey.containsKey(quote.key)
                                  ? 'Kullan' : 'Takip Et'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (activeOnline.length > 20)
                      Text('İlk 20 sonuç gösteriliyor. Aramayı daraltın.',
                        style: const TextStyle(
                          fontSize: 11, color: NohutBrand.muted)),
                    if (selectedStore == 'Diğer') ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: otherStore,
                        decoration: const InputDecoration(
                          labelText: 'Diğer marketin adı (isteğe bağlı)',
                          hintText: 'Örn. ŞOK, manav, toptancı')),
                    ],
                    if (market != null) ...[
                      const SizedBox(height: 7),
                      Text(
                        (market['market'] ?? '').toString() + ' · ' +
                        (market['depotName'] ?? '').toString() +
                        ' · Market fiyatı: ' +
                        (market['priceCents'] is int ?
                          formatTry(market['priceCents'] as int) : '—') +
                        ' / ' + (market['unit'] ?? '').toString(),
                        style: const TextStyle(
                          color: NohutBrand.muted, fontSize: 12)),
                    ],
                    const SizedBox(height: 12),
                    TextField(controller: date,
                      decoration: const InputDecoration(
                        labelText: 'Alım Tarihi (YYYY-MM-DD)')),
                    const SizedBox(height: 10),
                    TextField(controller: name,
                      decoration: const InputDecoration(
                        labelText: 'Ürün / Malzeme Adı')),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      key: ValueKey('purchase-unit-' + unit),
                      initialValue: unit,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Miktar Birimi'),
                      items: [
                        for (final u in financeUnits)
                          DropdownMenuItem(value: u, child: Text(u)),
                      ],
                      onChanged: (v) => changeDialog(() {
                        if (v == null || v == unit) return;
                        // Changing unit removes a stale price to prevent
                        // treating a kg price as a per-piece price.
                        unit = v;
                        price.clear();
                      }),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: quantity,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                      onChanged: (_) => changeDialog(() {}),
                      decoration: InputDecoration(
                        labelText: 'Kaç ' + unit + '? (ör. 2,5)')),
                    const SizedBox(height: 10),
                    TextField(
                      controller: price,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                      onChanged: (_) => changeDialog(() {}),
                      decoration: InputDecoration(
                        labelText: 'Gerçek alış fiyatı (₺ / ' + unit + ')',
                        helperText: 'Hatalı market fiyatını burada düzeltin. '
                          'Market Fiyat Takibi değişmez.')),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: method,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Ödeme'),
                      items: [
                        for (final value in financeMethods)
                          DropdownMenuItem(value: value, child: Text(value)),
                      ],
                      onChanged: (v) => changeDialog(() {
                        method = v ?? method;
                      }),
                    ),
                    const SizedBox(height: 10),
                    const SizedBox(height: 12),
                    const Text('İNDİRİM',
                      style: TextStyle(
                        color: NohutBrand.muted, fontSize: 12,
                        fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                    const SizedBox(height: 7),
                    DropdownButtonFormField<String>(
                      key: ValueKey('finance-discount-type-$discountType'),
                      initialValue: discountType,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'İndirim Türü'),
                      items: const [
                        DropdownMenuItem(value: 'Yok',
                          child: Text('İndirim yok')),
                        DropdownMenuItem(value: 'Tutar',
                          child: Text('Tutar · ₺')),
                        DropdownMenuItem(value: 'Yüzde',
                          child: Text('Yüzde · %')),
                      ],
                      onChanged: (v) => changeDialog(() {
                        discountType = v ?? 'Yok';
                        discount.text = '0';
                      }),
                    ),
                    if (discountType != 'Yok') ...[
                      const SizedBox(height: 9),
                      TextField(
                        key: const ValueKey('finance-discount-value'),
                        controller: discount,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                        onChanged: (_) => changeDialog(() {}),
                        decoration: InputDecoration(
                          labelText: discountType == 'Tutar'
                            ? 'İndirim Tutarı (₺)' : 'İndirim Yüzdesi (%)',
                          helperText: 'Fişte gördüğünüz ek indirimi yazın.'),
                      ),
                    ],
                    const SizedBox(height: 5),
                    const Text(
                      'Kaynak fiyat zaten indirimliyse aynı indirimi '
                      'bir daha uygulamayın. Bu alan sadece alış kaydını '
                      'etkiler, Market Fiyat Takibi fiyatını değiştirmez.',
                      style: TextStyle(
                        fontSize: 11, color: NohutBrand.muted)),
                    TextField(controller: notes, maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Not (isteğe bağlı)')),
                    const SizedBox(height: 10),
                    if (subtotal != null && discountAmount != null)
                      Text('Ara toplam: ' + formatTry(subtotal) +
                        '   ·   İndirim: −' + formatTry(discountAmount),
                        style: const TextStyle(
                          color: NohutBrand.muted, fontSize: 12)),
                    Text('Ödenecek toplam: ' +
                        (total == null ? '—' : formatTry(total)),
                      key: const ValueKey('finance-material-net'),
                      style: const TextStyle(fontWeight: FontWeight.w800,
                        color: NohutBrand.green, fontSize: 19)),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(error!,
                          style: const TextStyle(color: Colors.red)),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Vazgeç')),
              FilledButton(
                key: const ValueKey('finance-material-save'),
                onPressed: () {
                  try {
                    final marketQuote = byKey[chosen];
                    final ok = widget.edit((state) => saveMaterialPurchase(
                      state,
                      id: existing?['id'] as int?,
                      date: date.text.trim(),
                      title: name.text.trim(),
                      unit: unit,
                      quantityMilli: _qty(quantity.text),
                      pricePerUnitCents: _price(price.text),
                      discountType: discountType,
                      discountValue: discountType == 'Yok' ? 0 :
                        _price(discount.text, allowZero: true),
                      marketKey: marketQuote == null ? '' : chosen,
                      storeBrand: selectedStore,
                      market: marketQuote == null
                        ? (selectedStore == 'Diğer'
                            ? (otherStore.text.trim().isEmpty
                                ? 'Diğer' : otherStore.text.trim())
                            : selectedStore)
                        : (marketQuote['market'] ?? '').toString() + ' · ' +
                          (marketQuote['depotName'] ?? '').toString(),
                      marketUnit: (marketQuote?['unit'] ?? '').toString(),
                      referencePriceCents: marketQuote?['priceCents'] as int?,
                      paymentMethod: method,
                      note: notes.text,
                    ));
                    if (ok) Navigator.pop(dialogContext);
                  } on FormatException catch (e) {
                    changeDialog(() => error = e.message);
                  }
                },
                child: const Text('Kaydet'),
              ),
            ],
          );
        },
      ),
    );
    dialogOpen = false;
    // Match the repo's existing dialog controller disposal timing.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    for (final c in [date, name, quantity, price, notes, search, otherStore, discount]) {
      c.dispose();
    }
  }

  Future<String?> _pickMaterialDay(String current, BuildContext ctx) async {
    final today = DateTime.parse(_today());
    final first = DateTime(2000);
    final parsed = DateTime.tryParse(current) ?? today;
    final initial = parsed.isAfter(today) ? today :
      (parsed.isBefore(first) ? first : parsed);
    final picked = await showDatePicker(
      context: ctx, initialDate: initial, firstDate: first, lastDate: today,
      helpText: 'Alış Tarihi Seçin',
    );
    return picked?.toIso8601String().substring(0, 10);
  }

  Future<void> _quickMaterialForm([Json? existing]) async {
    final pickedStore = existing == null
      ? await _chooseMaterialMarket() : materialPurchaseStore(existing);
    if (pickedStore == null || !mounted) return;
    var store = pickedStore;
    var selectedDay = (existing?['date'] ?? day).toString();
    if (selectedDay.compareTo(_today()) > 0) selectedDay = _today();
    var method = (existing?['paymentMethod'] ?? 'Nakit').toString();
    final market = TextEditingController(
      text: store == 'Diğer' ? (existing?['market'] ?? '').toString() : '');
    final note = TextEditingController(text: (existing?['note'] ?? '').toString());
    final amounts = <TextEditingController>[
      if (existing?['amountsCents'] is List)
        for (final value in existing!['amountsCents'] as List)
          if (value is int) TextEditingController(text: _tl(value)),
    ];
    if (amounts.isEmpty) amounts.add(TextEditingController());
    final removed = <TextEditingController>[];
    String? error;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (context, redraw) {
        int? total;
        try {
          total = quickMaterialTotalCents(
            amounts.map((c) => parseExpenseCents(c.text)).toList());
        } on FormatException {
          // Incomplete input is not a zero-value expense.
        }
        return AlertDialog(
          title: Text(existing == null ?
            'Hızlı Gider Ekle' : 'Hızlı Gider Düzenle'),
          content: SizedBox(width: 490, child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Ürün ve miktar girmeden, aynı marketteki '
                  'alış tutarlarını kaydedin. Fişteki net tutarları girin.',
                  style: TextStyle(color: NohutBrand.muted)),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const ValueKey('finance-quick-date'),
                  onPressed: () async {
                    final value = await _pickMaterialDay(selectedDay, context);
                    if (value != null && context.mounted) {
                      redraw(() => selectedDay = value);
                    }
                  },
                  icon: const Icon(Icons.calendar_today_outlined),
                  label: Text('Alış tarihi: $selectedDay'),
                ),
                const SizedBox(height: 10),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final name in materialStores)
                    ChoiceChip(
                      label: Text(name), selected: name == store,
                      selectedColor: _marketAccent(name).withValues(alpha: 0.15),
                      labelStyle: TextStyle(color: _marketAccent(name),
                        fontWeight: FontWeight.w700),
                      onSelected: (_) => redraw(() => store = name),
                    ),
                ]),
                if (store == 'Diğer') ...[
                  const SizedBox(height: 10),
                  TextField(controller: market,
                    decoration: const InputDecoration(
                      labelText: 'Market / tedarikçi adı (isteğe bağlı)')),
                ],
                const SizedBox(height: 12),
                for (var i = 0; i < amounts.length; i++)
                  Padding(
                    key: ObjectKey(amounts[i]),
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(children: [
                      Expanded(child: TextField(
                        key: ValueKey('finance-quick-amount-$i'),
                        controller: amounts[i],
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                        decoration: InputDecoration(
                          labelText: 'Tutar ' + (i + 1).toString() + ' (₺)'),
                        onChanged: (_) => redraw(() => error = null),
                      )),
                      IconButton(
                        tooltip: 'Tutarı kaldır',
                        onPressed: amounts.length == 1 ? null : () =>
                          redraw(() => removed.add(amounts.removeAt(i))),
                        icon: const Icon(Icons.remove_circle_outline)),
                    ]),
                  ),
                OutlinedButton.icon(
                  key: const ValueKey('finance-quick-add-amount'),
                  onPressed: amounts.length >= 100 ? null : () =>
                    redraw(() => amounts.add(TextEditingController())),
                  icon: const Icon(Icons.add),
                  label: const Text('Tutar Ekle'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: method, isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Ödeme'),
                  items: [
                    for (final item in financeMethods)
                      DropdownMenuItem(value: item, child: Text(item)),
                  ],
                  onChanged: (value) => redraw(() => method = value ?? method),
                ),
                const SizedBox(height: 10),
                TextField(controller: note,
                  decoration: const InputDecoration(labelText: 'Not (isteğe bağlı)')),
                const SizedBox(height: 12),
                Text('Toplam: ' + (total == null ? '—' : formatTry(total)),
                  key: const ValueKey('finance-quick-total'),
                  style: const TextStyle(fontSize: 20,
                    fontWeight: FontWeight.w800, color: NohutBrand.green)),
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red)),
              ],
            ),
          )),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Vazgeç')),
            FilledButton(
              key: const ValueKey('finance-quick-save'),
              onPressed: () {
                try {
                  final values = amounts.map((c) => parseExpenseCents(c.text)).toList();
                  quickMaterialTotalCents(values);
                  final ok = widget.edit((db) => saveQuickMaterialPurchase(
                    db, id: existing?['id'] as int?, date: selectedDay,
                    storeBrand: store, amountsCents: values,
                    market: market.text, paymentMethod: method, note: note.text));
                  if (ok) Navigator.pop(ctx, true);
                } on FormatException catch (e) {
                  redraw(() => error = e.message);
                }
              },
              child: const Text('Kaydet')),
          ],
        );
      }),
    );
    if (saved == true && mounted) {
      setState(() {
        day = selectedDay;
        month = selectedDay.substring(0, 7);
      });
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    for (final c in [...amounts, ...removed, market, note]) {
      c.dispose();
    }
  }

  Future<void> _voidMaterial(Json item) async {
    final answer = await askFields(context, 'Malzeme İptal',
      [('İptal nedeni', '')], validate: (v) =>
        v[0].trim().isEmpty ? 'İptal nedeni gerekli' : null);
    if (answer == null) return;
    widget.edit((s) =>
      voidMaterialPurchase(s, item['id'] as int, answer.first));
  }

  Widget _materials() {
    final list = financeRows(widget.state, 'materials')
      .where((p) => p['date'] == day)
      .toList()..sort((a, b) => (b['id'] as int).compareTo(a['id'] as int));
    final sum = list.where((p) => p['voided'] != true)
      .fold<int>(0, (v, p) => v + (p['totalCents'] as int));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Günlük Malzeme Alımı'),
        // §24.8: new daily purchases use only the quick form. Itemized
        // (product) records from before stay readable and editable below.
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: const ValueKey('finance-new-quick-material'),
            onPressed: () => _quickMaterialForm(),
            icon: const Icon(Icons.add),
            label: const Text('Hızlı Gider Ekle')),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            IconButton(
              tooltip: 'Önceki gün', onPressed: () => _shiftDay(-1),
              icon: const Icon(Icons.chevron_left)),
            TextButton.icon(
              key: const ValueKey('finance-material-day-picker'),
              icon: const Icon(Icons.calendar_today_outlined, size: 16),
              label: Text(day),
              onPressed: () async {
                final picked = await _pickMaterialDay(day, context);
                if (picked != null && mounted) setState(() {
                  day = picked;
                  month = picked.substring(0, 7);
                });
              },
            ),
            IconButton(
              tooltip: 'Sonraki gün', onPressed: () => _shiftDay(1),
              icon: const Icon(Icons.chevron_right)),
            const Spacer(),
            Text('Günlük toplam: ' + formatTry(sum),
              style: const TextStyle(fontWeight: FontWeight.w800,
                color: NohutBrand.green)),
          ],
        ),
        if (list.isEmpty)
          const Card(child: Padding(padding: EdgeInsets.all(20),
            child: Text('Bu gün malzeme alımı kaydedilmedi.'))),
        for (final p in list)
          Card(child: ListTile(
            leading: _marketBadge(materialPurchaseStore(p)),
            title: Text((p['title'] ?? '').toString() +
              (p['voided'] == true ? ' · İPTAL' : '')),
            subtitle: Text(
              (isQuickMaterial(p)
                ? (p['amountsCents'] as List).whereType<int>()
                    .map(formatTry).join(' + ') + ' · Hızlı kayıt'
                : _quantity(p['quantityMilli'] as int) + ' ' +
              p['unit'].toString() + ' × ' +
              formatTry(p['pricePerUnitCents'] as int) +
              ((p['discountCents'] ?? 0) is int &&
                (p['discountCents'] ?? 0) > 0
                ? ' · İndirim: −' +
                    formatTry(p['discountCents'] as int) : '')) +
              (p['market'] == '' ? '' : '\n' + p['market'].toString()) +
              '\n' + (p['paymentMethod'] ?? '').toString()),
            isThreeLine: true,
            trailing: Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(formatTry(p['totalCents'] as int),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
                if (p['voided'] != true)
                  PopupMenuButton<String>(
                    tooltip: 'Malzeme işlemleri',
                    onSelected: (action) =>
                      action == 'edit'
                        ? (isQuickMaterial(p) ? _quickMaterialForm(p) : _materialForm(p))
                        : _voidMaterial(p),
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'edit', child: Text('Düzenle')),
                      PopupMenuItem(value: 'void', child: Text('İptal Et')),
                    ],
                  ),
              ],
            ),
          )),
      ],
    );
  }

  Future<void> _payrollForm([Json? current]) async {
    final people = asMaps(widget.state['employees']);
    if (people.isEmpty) {
      _error('Ayarlar → Personel üzerinden çalışan ekleyin.');
      return;
    }
    int selected = current?['employeeId'] is int ?
      current!['employeeId'] as int : people.first['id'] as int;
    final hours = TextEditingController(text: current == null ?
      '0' : _try((current['workedMinutes'] as int) / 60));
    final bonus = TextEditingController(text: current == null ?
      '0' : _tl(current['bonusCents'] as int));
    final advance = TextEditingController(text: current == null ?
      '0' : _tl(current['advanceCents'] as int));
    bool paid = current?['paid'] == true;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, changeDialog) {
          final employee = people.where((p) => p['id'] == selected).first;
          final payType = (employee['payType'] ?? '').toString();
          final rate = employee['payRateCents'];
          final configured = rate is int && rate > 0 &&
            ['Saatlik', 'Haftalık Sabit'].contains(payType);
          final hourly = payType == 'Saatlik';
          return AlertDialog(
            title: Text('Haftalık Maaş · ' + week),
            content: SizedBox(
              width: 470,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DropdownButtonFormField<int>(
                      initialValue: selected,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Personel (Ayarlar bağlantısı)'),
                      items: [
                        for (final p in people)
                          DropdownMenuItem(
                            value: p['id'] as int,
                            child: Text((p['name'] ?? '').toString())),
                      ],
                      onChanged: current != null ? null : (v) =>
                        changeDialog(() => selected = v ?? selected),
                    ),
                    const SizedBox(height: 12),
                    Text(configured ?
                      payType + ' · ' + formatTry(rate) :
                      'Önce Ayarlar → Personel → Düzenle: Ücret girin.',
                      style: TextStyle(
                        color: configured ? NohutBrand.green : Colors.red,
                        fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),
                    if (hourly) ...[
                      TextField(controller: hours,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Haftalık çalışma saati')),
                      const SizedBox(height: 10),
                    ],
                    TextField(controller: bonus,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Prim / Ek ödeme (₺)')),
                    const SizedBox(height: 10),
                    TextField(controller: advance,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Önceden verilen avans (₺)',
                        helperText: 'Avans giderden tekrar düşülmez; '
                          'yalnızca kalan ödeme tutarını azaltır.')),
                    const SizedBox(height: 10),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: paid,
                      title: const Text('Maaş ödendi'),
                      subtitle: const Text(
                        'Yalnızca kayıt; banka/kasadan para çekmez.'),
                      onChanged: current?['paid'] == true ? null : (v) =>
                        changeDialog(() => paid = v ?? false),
                    ),
                    if (error != null)
                      Text(error!, style: const TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Vazgeç')),
              FilledButton(
                key: const ValueKey('finance-payroll-save'),
                onPressed: !configured ? null : () {
                  try {
                    final minutes = hourly ?
                      (_decimal(hours.text, allowZero: true) * 60).round() : 0;
                    final ok = widget.edit((state) => saveWeeklyPayroll(state,
                      employeeId: selected,
                      weekStart: week,
                      workedMinutes: minutes,
                      bonusCents: _price(bonus.text, allowZero: true),
                      advanceCents: _price(advance.text, allowZero: true),
                      paid: paid));
                    if (ok) Navigator.pop(dialogContext);
                  } on FormatException catch (e) {
                    changeDialog(() => error = e.message);
                  }
                },
                child: const Text('Kaydet'),
              ),
            ],
          );
        },
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    hours.dispose(); bonus.dispose(); advance.dispose();
  }

  Widget _payroll() {
    final list = financeRows(widget.state, 'weeklyPayroll')
      .where((p) => p['weekStart'] == week)
      .toList();
    final total = list.fold<int>(0, (v, p) => v + (p['grossCents'] as int));
    final end = weekEndOf(week);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Haftalık Personel Maaşları',
          action: FilledButton.icon(
            key: const ValueKey('finance-new-payroll'),
            onPressed: () => _payrollForm(),
            icon: const Icon(Icons.add),
            label: const Text('Haftalık Maaş Ekle'))),
        _notice('Maaş oranları Ayarlar → Personel kaydından gelir. '
          'Saatler otomatik tahmin edilmez. Haftalık gider, '
          'haftanın bittiği ayda bir kez sayılır. SGK ayrı aylık giderdir.'),
        const SizedBox(height: 10),
        Row(children: [
          IconButton(tooltip: 'Önceki hafta', icon: const Icon(Icons.chevron_left),
            onPressed: () => _shiftWeek(-1)),
          Expanded(child: Text(week + ' → ' + end,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700))),
          IconButton(tooltip: 'Sonraki hafta', icon: const Icon(Icons.chevron_right),
            onPressed: () => _shiftWeek(1)),
        ]),
        _metric('Haftalık hak ediş', formatTry(total),
          Icons.groups_outlined),
        if (list.isEmpty)
          const Card(child: Padding(padding: EdgeInsets.all(20),
            child: Text('Bu hafta için maaş kaydı yok.'))),
        for (final p in list)
          Card(child: ListTile(
            title: Text((p['employeeName'] ?? '').toString()),
            subtitle: Text(
              (p['payType'] ?? '').toString() +
              ' · ' + formatTry(p['rateCents'] as int) +
              (p['payType'] == 'Saatlik' ?
                ' × ' + _quantity((p['workedMinutes'] as int) * 1000 ~/ 60) +
                  ' saat' : '') +
              '\nPrim: ' + formatTry(p['bonusCents'] as int) +
              ' · Avans: ' + formatTry(p['advanceCents'] as int) +
              '\nKalan ödeme: ' + formatTry(p['payableCents'] as int) +
              (p['paid'] == true ? ' · Ödendi' : ' · Ödenmedi')),
            isThreeLine: true,
            trailing: Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(formatTry(p['grossCents'] as int),
                  style: const TextStyle(fontWeight: FontWeight.w800)),
                if (p['paid'] != true)
                  PopupMenuButton<String>(
                    tooltip: 'Maaş işlemleri',
                    onSelected: (action) {
                      if (action == 'edit') {
                        _payrollForm(p);
                      } else {
                        widget.edit((s) => markWeeklyPayrollPaid(
                          s, p['employeeId'] as int, week));
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'edit', child: Text('Düzenle')),
                      PopupMenuItem(value: 'paid',
                        child: Text('Ödendi Olarak İşaretle')),
                    ],
                  ),
              ],
            ),
          )),
      ],
    );
  }

  Future<void> _fixedForm([Json? old]) async {
    final answers = await askFields(context,
      old == null ? 'Aylık Sabit Gider Ekle' : 'Sabit Gider Düzenle',
      [
        ('Kategori', (old?['category'] ?? 'Kira').toString()),
        ('Gider Adı', (old?['name'] ?? '').toString()),
        ('Aylık Tutar (₺)', old == null ? '' :
          _tl(old['amountCents'] as int)),
        ('Başlangıç Ayı (YYYY-MM)',
          (old?['startMonth'] ?? month).toString()),
        ('Ödeme Günü (1–28)', (old?['dueDay'] ?? 1).toString()),
        ('Aktif', old?['active'] == false ? 'Hayır' : 'Evet'),
      ],
      choices: {
        0: financeFixedCategories,
        5: ['Evet', 'Hayır'],
      },
      validate: (values) {
        if (values[1].trim().isEmpty ||
            !validFinanceMonth(values[3]) ||
            (int.tryParse(values[4]) ?? 0) < 1 ||
            (int.tryParse(values[4]) ?? 29) > 28) {
          return 'Ad, ay veya ödeme günü geçersiz.';
        }
        try { _price(values[2]); } on FormatException catch (e) {
          return e.message;
        }
        return null;
      },
    );
    if (answers == null) return;
    widget.edit((state) => saveMonthlyFixed(state,
      id: old?['id'] as int?,
      category: answers[0],
      name: answers[1],
      amountCents: _price(answers[2]),
      startMonth: answers[3],
      dueDay: int.parse(answers[4]),
      active: answers[5] == 'Evet',
    ));
  }

  Widget _fixed() {
    final fixed = financeRows(widget.state, 'monthlyFixed');
    final payments = financeRows(widget.state, 'fixedPayments');
    final dueRows = fixedDueRows(widget.state, month);
    final dueIds = {for (final (f, _) in dueRows) f['id']};
    final amountFor = {for (final (f, a) in dueRows) f['id']: a};
    final total = dueRows.fold<int>(0, (v, r) => v + r.$2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Aylık Sabit Giderler',
          action: FilledButton.icon(
            onPressed: () => _fixedForm(),
            icon: const Icon(Icons.add),
            label: const Text('Sabit Gider Ekle'))),
        _notice('Kira, SGK, Muhasebe gibi aylık tutarlar otomatik '
          'tahakkuk eder. Tutar değişikliği bu aydan itibaren geçerlidir; '
          'pasif yapılan gider geçmiş aylardan silinmez. Ödendi işareti '
          'sadece takip içindir; kasa bakiyesine işlem göndermez.'),
        const SizedBox(height: 10),
        Builder(builder: (context) {
          bool isPaid(Map f) => payments.any((r) =>
              r['templateId'] == f['id'] && r['month'] == month);
          final paidTotal = dueRows.where((r) => isPaid(r.$1))
              .fold<int>(0, (v, r) => v + r.$2);
          return EvenGrid(minTileWidth: 200, spacing: 8, children: [
            _metric('Bu ay tahakkuk eden', formatTry(total),
              Icons.calendar_month_outlined),
            _metric('Ödenen', formatTry(paidTotal), Icons.check_circle_outline),
            _metric('Kalan', formatTry(total - paidTotal),
              Icons.pending_actions_outlined, important: total > paidTotal),
          ]);
        }),
        const SizedBox(height: 8),
        for (final f in fixed)
          Builder(builder: (context) {
            final due = dueIds.contains(f['id']);
            final paid = payments.any((r) =>
                r['templateId'] == f['id'] && r['month'] == month);
            final today = istanbulDay(DateTime.now().toUtc());
            final late = due && !paid && (month.compareTo(today.substring(0, 7)) < 0 ||
                (month == today.substring(0, 7) &&
                  int.parse(today.substring(8)) > (f['dueDay'] as int? ?? 1)));
            final (label, color) = !due
                ? (f['active'] == false ? 'Pasif' : 'Bu ay yok', NohutBrand.muted)
                : paid ? ('Ödendi', const Color(0xff2E7D4F))
                : late ? ('Gecikti', const Color(0xffB3261E))
                : ('Bekliyor', const Color(0xffB7791F));
            return Card(child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              child: Row(children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10)),
                  child: Icon(paid ? Icons.check : Icons.event_note_outlined,
                    color: color, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((f['name'] ?? '').toString(), style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 15)),
                    Text(
                      '${f['category']} · Her ayın ${f['dueDay']}. günü · '
                      'Başlangıç: ${financeMonthLabel('${f['startMonth']}')}',
                      style: const TextStyle(fontSize: 12.5,
                        color: NohutBrand.muted)),
                  ],
                )),
                Text(formatTry(amountFor[f['id']] ?? f['amountCents'] as int),
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                const SizedBox(width: 12),
                Container(
                  width: 82,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12)),
                  child: Text(label, style: TextStyle(color: color,
                    fontWeight: FontWeight.w800, fontSize: 12)),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 130,
                  child: due
                      ? TextButton(
                          onPressed: () => widget.edit((s) =>
                            markMonthlyFixedPaid(s, f['id'] as int, month, !paid)),
                          child: Text(paid ? 'Geri Al' : 'Ödendi İşaretle'),
                        )
                      : const SizedBox.shrink(),
                ),
                IconButton(
                  tooltip: 'Sabit gider düzenle',
                  onPressed: () => _fixedForm(f),
                  icon: const Icon(Icons.edit_outlined)),
              ]),
            ));
          }),
      ],
    );
  }

  Future<void> _otherForm() async {
    final answers = await askFields(context, 'Diğer Gider Ekle', [
      ('Kategori', 'Yol / Nakliye'),
      ('Gider Adı', ''),
      ('Tarih (YYYY-MM-DD)', day),
      ('Tutar (₺)', ''),
      ('Ödeme', 'Nakit'),
    ],
      choices: {0: financeOtherCategories, 4: financeMethods},
      validate: (v) {
        if (v[1].trim().isEmpty || !validBusinessDate(v[2])) {
          return 'Ad veya tarih geçersiz.';
        }
        try { _price(v[3]); } on FormatException catch (e) {
          return e.message;
        }
        return null;
      },
    );
    if (answers == null) return;
    widget.edit((s) => saveOtherExpense(s,
      category: answers[0], name: answers[1], day: answers[2],
      amountCents: _price(answers[3]), paymentMethod: answers[4]));
  }

  Widget _other() {
    final items = financeRows(widget.state, 'other')
      .where((r) => (r['date'] as String? ?? '').startsWith(month))
      .toList()..sort((a, b) =>
        (b['date'] as String).compareTo(a['date'] as String));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Diğer Günlük Giderler',
          action: FilledButton.icon(
            onPressed: _otherForm, icon: const Icon(Icons.add),
            label: const Text('Gider Ekle'))),
        for (final p in items)
          Card(child: ListTile(
            title: Text(p['name'].toString() +
              (p['voided'] == true ? ' · İPTAL' : '')),
            subtitle: Text(p['date'].toString() + ' · ' +
              p['category'].toString() + ' · ' +
              p['paymentMethod'].toString()),
            trailing: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              children: [
                Text(formatTry(p['amountCents'] as int)),
                if (p['voided'] != true)
                  IconButton(
                    icon: const Icon(Icons.cancel_outlined),
                    tooltip: 'Gider iptal et',
                    onPressed: () async {
                      final answer = await askFields(context, 'Gider İptal',
                        [('İptal nedeni', '')],
                        validate: (v) => v.first.isEmpty ?
                          'İptal nedeni gerekli' : null);
                      if (answer != null) {
                        widget.edit((s) => voidOtherExpense(
                          s, p['id'] as int, answer.first));
                      }
                    },
                  ),
              ],
            ),
          )),
        if (items.isEmpty) const Card(
          child: Padding(padding: EdgeInsets.all(20),
            child: Text('Bu ay diğer gider kaydı yok.'))),
      ],
    );
  }


  Future<void> _manualPlatformForm(String source) async {
    if (platformHasAutomaticSales(widget.state, source, month)) {
      _error('Otomatik satışlar bulundu. Manuel toplam eklenemez.');
      return;
    }
    final current = manualPlatformIncome(widget.state, source, month);
    final values = await askFields(
      context, source + ' · Manuel Gelir (' + month + ')', [
        ('Tutar Türü', (current?['kind'] ?? 'Brüt').toString()),
        ('Tutar (₺)', current == null ? '' :
          _tl(current['amountCents'] as int)),
        ('Not / Ekstre Kaynağı', (current?['note'] ?? '').toString()),
      ],
      choices: {0: manualIncomeTypes},
      validate: (v) {
        if (v.length < 3 || !manualIncomeTypes.contains(v[0])) {
          return 'Brüt veya Net seçin.';
        }
        try {
          _price(v[1]);
        } on FormatException catch (e) {
          return e.message;
        }
        return null;
      },
    );
    if (values == null || !mounted) return;
    try {
      widget.edit((db) => saveManualPlatformIncome(db,
        source: source, month: month, kind: values[0],
        amountCents: _price(values[1]), note: values[2]));
    } on FormatException catch (e) {
      _error(e.message);
    }
  }

  Future<void> _deleteManualPlatform(String source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Manuel gelir kaydını iptal et'),
        content: Text(source + ' · ' + month +
          '\nBu manuel toplam finans hesabından çıkarılacak.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Vazgeç')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Kaydı İptal Et')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      widget.edit((db) => voidManualPlatformIncome(db, source, month));
    } on FormatException catch (e) {
      _error(e.message);
    }
  }

  Widget _manualPlatformSection() {
    final figures = financePlatformFigures(widget.state, month)
      .where((p) => manualIncomePlatforms.contains(p.source)).toList();
    return Card(child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Yemeksepeti & Migros Yemek',
            style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 5),
          const Text(
            'Otomatik veri gelmiyorsa aylık toplamı manuel girin. '
            'Brüt mü Net mi seçin. Net tutardan ikinci kez komisyon '
            'düşülmez; Brüt tutar için kayıtlı kesinti oranı kullanılır.',
            style: TextStyle(color: NohutBrand.muted, fontSize: 12)),
          const SizedBox(height: 12),
          for (final p in figures) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(p.isAutomatic
                ? Icons.cloud_done_outlined : Icons.edit_note_outlined,
                color: NohutBrand.green),
              title: Text(p.source,
                style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(p.isAutomatic
                ? 'Otomatik · ' + p.automaticOrders.toString() +
                    ' teslim edilmiş sipariş'
                : p.isManual
                  ? 'Manuel ' + (p.inputKind ?? '') + ' · ' + month +
                    (p.netCents == null ? ' · Komisyon oranı eksik' : '')
                  : 'Otomatik kayıt yok · Manuel giriş yapılabilir'),
              trailing: p.isAutomatic
                ? const Text('Otomatik',
                    style: TextStyle(color: NohutBrand.muted))
                : OutlinedButton(
                    key: ValueKey('finance-manual-platform-' + p.source),
                    onPressed: () => _manualPlatformForm(p.source),
                    child: Text(p.isManual ? 'Düzenle' : 'Manuel Gelir Gir')),
            ),
            if (p.isManual) ...[
              Row(children: [
                Expanded(child: Text(
                  'Brüt: ' + (p.grossCents == null
                    ? '—' : formatTry(p.grossCents!)) +
                  ' · Kesinti: ' + (p.deductionCents == null
                    ? '—' : formatTry(p.deductionCents!)) +
                  ' · Net: ' + (p.netCents == null
                    ? '—' : formatTry(p.netCents!)),
                  style: const TextStyle(
                    fontSize: 12, color: NohutBrand.green))),
                TextButton(
                  onPressed: () => _deleteManualPlatform(p.source),
                  child: const Text('İptal Et')),
              ]),
            ],
            if (p.isAutomatic &&
                manualPlatformIncome(widget.state, p.source, month) != null)
              const Text(
                'Manuel toplam saklanır ama otomatik satış varken '
                'hesaba katılmaz (çifte sayım önleme).',
                style: TextStyle(
                  color: Color(0xffa25b39), fontSize: 11)),
            const Divider(height: 20),
          ],
          const Text(
            'Manuel giriş yalnızca Finans raporuna eklenir; '
            'sipariş oluşturmaz ve kasa/banka bakiyesini değiştirmez.',
            style: TextStyle(color: NohutBrand.muted, fontSize: 11)),
        ],
      ),
    ));
  }

  Widget _overview() {
    final report = financeMonthSummary(widget.state, month);
    final breakdown = <(String, int)>[
      ('Günlük Malzeme', report.materialsCents),
      ('Haftalık Maaşlar', report.payrollCents),
      ('Aylık Sabit Giderler', report.fixedCents),
      ('Diğer Giderler', report.otherCents),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Aylık Gelir · Gider'),
        if (widget.onlineWarning != null)
          _notice(widget.onlineWarning!),
        const SizedBox(height: 8),
        EvenGrid(
          minTileWidth: 200,
          spacing: 8,
          children: [
            _metric('Yerel Tahsilat (Masa / Gel-Al)',
              formatTry(report.localReceiptsCents), Icons.payments_outlined),
            _metric('Online Tahmini Net',
              formatTry(report.onlineKnownNetCents),
              Icons.delivery_dining_outlined),
            _metric('Toplam Gider',
              formatTry(report.totalExpensesCents),
              Icons.trending_down_outlined),
            _metric('Tahmini Faaliyet Farkı',
              report.estimateCents == null ? '—' :
                formatTry(report.estimateCents!),
              Icons.account_balance_wallet_outlined,
              important: true),
          ],
        ),
        const SizedBox(height: 12),
        _manualPlatformSection(),
        const SizedBox(height: 12),
        if (report.missingOnlineRate)
          _notice('Bazı online siparişlerin komisyon oranı bilinmiyor: ' +
            formatTry(report.onlineUnpricedGrossCents) +
            ' brüt. Tahmini faaliyet farkı bilinçli olarak gizlendi. '
            'Raporlar → Genel Bakış üzerinden oranları girin.'),
        const SizedBox(height: 10),
        _notice('Yönetim amaçlı yaklaşık hesap: yerel gerçek tahsilat + '
          'kaydedilmiş online siparişlerin tahmini neti − kaydedilen '
          'malzeme alımları, haftalık maaş tahakkuku ve sabit giderler. '
          'Stok tüketimi, vergi, gerçek banka mutabakatı ve eksik '
          'entegrasyonlar hesaplanmadı; yasal kâr değildir.'),
        const SizedBox(height: 12),
        Card(child: Padding(
          padding: const EdgeInsets.all(17),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Gider Dağılımı',
                style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 10),
              for (final item in breakdown) ...[
                Row(children: [
                  Expanded(child: Text(item.$1)),
                  Text(formatTry(item.$2),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
                const SizedBox(height: 5),
                LinearProgressIndicator(
                  value: report.totalExpensesCents > 0 ?
                    item.$2 / report.totalExpensesCents : 0,
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(9),
                  backgroundColor: const Color(0xffEDF1EC),
                  color: NohutBrand.green,
                ),
                const SizedBox(height: 13),
              ],
            ],
          ),
        )),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Finans', style: Theme.of(context).textTheme.headlineSmall),
              const Text('Günlük alımlar · Haftalık maaşlar · Aylık giderler',
                style: TextStyle(color: NohutBrand.muted)),
            ],
          )),
          const SizedBox(width: 8),
          FilledButton.icon(
            key: const ValueKey('finance-pdf-export'),
            onPressed: _pdfBusy ? null : _exportPdfReport,
            icon: _pdfBusy
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(
                    color: Colors.white, strokeWidth: 2))
              : const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('PDF Raporu İndir'),
          ),
        ],
      ),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 14, 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xffE1E7E3)),
        ),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(icon: const Icon(Icons.chevron_left),
                tooltip: 'Önceki ay',
                onPressed: () => _shiftMonth(-1)),
              SizedBox(
                width: 150,
                child: Text(financeMonthLabel(month),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 19,
                    color: NohutBrand.green, fontWeight: FontWeight.w800)),
              ),
              IconButton(icon: const Icon(Icons.chevron_right),
                tooltip: 'Sonraki ay',
                onPressed: () => _shiftMonth(1)),
              if (month != istanbulDay(DateTime.now().toUtc()).substring(0, 7))
                TextButton(
                  onPressed: () => setState(() {
                    final today = istanbulDay(DateTime.now().toUtc());
                    month = today.substring(0, 7);
                    day = today;
                  }),
                  child: const Text('Bu Ay'),
                ),
            ]),
            Wrap(
              spacing: 6, runSpacing: 6,
              children: [
                for (final name in const [
                  'Genel Bakış', 'Günlük Malzeme',
                  'Haftalık Maaşlar', 'Sabit Giderler', 'Diğer Giderler',
                ])
                  ChoiceChip(label: Text(name), selected: tab == name,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() => tab = name)),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      if (tab == 'Genel Bakış') _overview(),
      if (tab == 'Günlük Malzeme') _materials(),
      if (tab == 'Haftalık Maaşlar') _payroll(),
      if (tab == 'Sabit Giderler') _fixed(),
      if (tab == 'Diğer Giderler') _other(),
    ],
  );
}
