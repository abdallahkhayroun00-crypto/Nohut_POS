import 'package:flutter/material.dart';

import 'brand.dart';
import 'order_reporting.dart';
import 'pos_logic.dart';
import 'trendyol_go_readonly.dart';
import 'trendyol_go_ui.dart';
import 'operations_ui.dart';

const onlinePartners = {
  'Trendyol Go': (
    label: 'Trendyol Go',
    url: 'https://partner.tgoyemek.com/',
  ),
  'Yemeksepeti': (
    label: 'Yemeksepeti',
    url: 'https://partner-app.yemeksepeti.com/',
  ),
  'Migros Yemek': (
    label: 'Migros Yemek',
    url: 'https://restoran.migrosonline.com/login',
  ),
};

class OnlineOrders extends StatefulWidget {
  const OnlineOrders({
    super.key,
    required this.integration,
    required this.businessDay,
    required this.orders,
    required this.onPrint,
    required this.initialSource,
    required this.demo,
  });

  final TrendyolGoReadonly integration;
  final String businessDay, initialSource;
  final List<Json> orders;
  final ValueChanged<Json> onPrint;
  final Widget Function() demo;

  @override
  State<OnlineOrders> createState() => _OnlineOrdersState();
}

class _OnlineOrdersState extends State<OnlineOrders> {
  late String source = widget.initialSource;
  bool history = false;
  String query = '', status = '';
  String? selectedDay;

  Future<void> _createTrendyolProductDraft() async {
    final result = await askFields(context, 'Trendyol Go · Yeni Ürün Taslağı', [
      ('Ürün Adı', ''),
      ('Kategori', ''),
      ('Satış Fiyatı (₺)', ''),
      ('Ürün Açıklaması', ''),
      ('Görsel URL (isteğe bağlı)', ''),
      ('Seçenekler / Ekstralar', ''),
    ], validate: (v) {
      if (v[0].trim().isEmpty || v[1].trim().isEmpty) {
        return 'Ürün adı ve kategori gerekli';
      }
      final amount = double.tryParse(v[2].trim().replaceAll(',', '.'));
      if (amount == null || !amount.isFinite || amount <= 0 ||
          amount > 1000000) return 'Geçerli fiyat gerekli';
      if (v[0].length > 180 || v[1].length > 120 ||
          v[3].length > 2000 || v[4].length > 1000 ||
          v[5].length > 1000) return 'Alan uzunluğu geçersiz';
      return null;
    });
    if (result == null || !mounted) return;
    var stored = false;
    for (var attempt = 0; attempt < 4 && !stored; attempt++) {
      final snapshot = widget.integration.store.read();
      final next = copyJson(snapshot.data);
      final drafts = next.putIfAbsent('tgoProductDrafts', () => <dynamic>[]) as List;
      if (drafts.length >= 500) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Taslak sınırına ulaşıldı.')));
        return;
      }
      drafts.add({
        'id': DateTime.now().toUtc().microsecondsSinceEpoch,
        'supplierId': widget.integration.credentials?.supplierId,
        'name': result[0].trim(),
        'category': result[1].trim(),
        'price': double.parse(result[2].trim().replaceAll(',', '.')),
        'description': result[3].trim(),
        'imageUrl': result[4].trim(),
        'options': result[5].trim(),
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'status': 'Yerel Taslak',
      });
      stored = widget.integration.store.replace(next, snapshot.revision).ok;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(stored
          ? 'Ürün taslağı kaydedildi. Trendyol Go yayını yapılmadı.'
          : 'Taslak kaydedilemedi. Tekrar deneyin.'),
      ));
      setState(() {});
    }
  }

  Future<void> _pickDate() async {
    final today = DateTime.parse(widget.businessDay);
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: today,
      initialDate: DateTime.tryParse(selectedDay ?? '') ?? today,
    );
    if (date != null && mounted) {
      setState(() => selectedDay = date.toIso8601String().substring(0, 10));
    }
  }

  Future<void> _applyAction(Json order, String action) async {
    if (!widget.integration.canWrite || widget.integration.writing) return;
    int? reasonId;
    String? explanation;
    double? receiptAmount;
    int? bagCount;
    if (action == 'cancel') {
      const reasons = {
        621: 'Tedarik problemi',
        622: 'Mağaza kapalı',
        623: 'Sipariş hazırlanamadı',
        627: 'Sipariş karışıklığı',
      };
      reasonId = await showDialog<int>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Sipariş iptal nedeni'),
          children: [
            for (final entry in reasons.entries)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, entry.key),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text('${entry.key} · ${entry.value}'),
                ),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Vazgeç'),
            ),
          ],
        ),
      );
      if (reasonId == null || !mounted) return;
      explanation = reasons[reasonId];
    } else if (action == 'ready') {
      var value = ((order['totalCents'] as int? ?? 0) / 100)
          .toStringAsFixed(2);
      var bags = '1';
      final result = await showDialog<List<String>>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Hazır · Fiş ve Poşet Bilgileri'),
          content: SizedBox(
            width: 390,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Platforma gönderilecek gerçek mali fiş tutarını doğrulayın. '
                  'Bu işlem banka tahsilatı veya mali fiş oluşturmaz.',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: value,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Fiş tutarı (₺)'),
                  onChanged: (next) => value = next,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  initialValue: bags,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Gerçek poşet adedi (1-10)'),
                  onChanged: (next) => bags = next,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('Vazgeç')),
            FilledButton(onPressed: () => Navigator.pop(ctx, [value, bags]),
              child: const Text('Devam Et')),
          ],
        ),
      );
      if (result == null || !mounted) return;
      receiptAmount = double.tryParse(result[0].replaceAll(',', '.'));
      bagCount = int.tryParse(result[1]);
      if (receiptAmount == null || !receiptAmount.isFinite ||
          receiptAmount <= 0 || bagCount == null ||
          bagCount < 1 || bagCount > 10) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(
            'Geçerli mali fiş tutarı ve gerçek poşet adedi gerekli.')),
        );
        return;
      }
    }
    final caption = switch (action) {
      'accept' => 'Kabul Et',
      'ready' => 'Hazır',
      _ => 'Siparişi İptal Et',
    };
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$caption · Onay'),
        content: Text(
          'Platform siparişi #${order['orderNumber']}\n'
          'Bu işlem doğrudan platform API’sine gönderilir. '
          'Sipariş durumu platform tarafından onaylanmadan değişmez.'
          '${explanation == null ? '' : '\nNeden: $explanation'}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Vazgeç')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(caption),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final verified = await widget.integration.updateOrder(
        order, action,
        reasonId: reasonId,
        explanation: explanation,
        receiptAmount: receiptAmount,
        bagCount: bagCount,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(verified
              ? 'Platform durumu API üzerinden doğrulandı.'
              : 'İşlem API’ye gönderildi ancak son durum doğrulanamadı. '
                  'Tekrar göndermeden önce Partner Paneli’ni kontrol edin.'),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Platform işlemi tamamlanamadı: $e'),
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final integration = widget.integration;
    final orders =
        widget.orders.where((order) {
          if (order['testPackage'] == true) return false;
          if (source != 'Tümü' && source != provider(order)) return false;
          final stamp = DateTime.tryParse('${order['createdAt']}');
          if (stamp == null) return false;
          final day = istanbulDay(stamp);
          if ((!history && day != widget.businessDay) ||
              (history && day.compareTo(widget.businessDay) >= 0) ||
              (history && selectedDay != null && day != selectedDay))
            return false;
          if (history && status.isNotEmpty && status != order['status'])
            return false;
          return query.isEmpty ||
              [
                order['orderNumber'],
                order['orderCode'],
                displayOrderNumber(order),
              ].any((value) => '${value ?? ''}'.toLowerCase().contains(query));
        }).toList()..sort(
          (a, b) => DateTime.parse(
            '${b['createdAt']}',
          ).compareTo(DateTime.parse('${a['createdAt']}')),
        );
    final groups = List.generate(
      3,
      (i) => orders.where((order) => _lane(order) == i).toList(),
    );
    final completed = orders.where((order) => _lane(order) == 3);
    final partners = source == 'Tümü' ? onlinePartners.keys : [source];
    final canSync = integration.credentials?.valid == true &&
        TrendyolGoReadonly.liveSyncEnabled;
    final tgoConnected = integration.status.startsWith('Bağlı ·');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.delivery_dining_outlined, color: NohutBrand.green, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Sipariş Merkezi',
                  style: Theme.of(context).textTheme.titleLarge),
            ),
            if (integration.syncing)
              const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
        const SizedBox(height: 5),
        const Text('Tüm platformlar tek ekranda · Bağlantısı olmayan platformlar otomatik sipariş göndermez.'),
        Card(
          key: const ValueKey('online-availability-controls'),
          color: const Color(0xffeaf2ec),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(children: [
                  Icon(Icons.power_settings_new, color: NohutBrand.green),
                  SizedBox(width: 9),
                  Text('ONLINE SİPARİŞLERİ AÇ / KAPAT',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                ]),
                const SizedBox(height: 5),
                const Text('Anlık satışa açık/kapalı durumu sipariş senkronizasyonundan doğrulanamaz. '
                  'Yanlışlıkla kapatılmış gibi göstermemek için durum bilinmiyor.'),
                const SizedBox(height: 11),
                for (final platform in onlinePartners.keys)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 10,
                      runSpacing: 6,
                      children: [
                        SizedBox(
                          width: 140,
                          child: Text('$platform · Durum', style: const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                        const Chip(
                          avatar: Icon(Icons.help_outline, size: 16),
                          label: Text('Durum doğrulanmadı'),
                        ),
                        FilledButton.icon(
                          onPressed: () => openExternalPage(context, onlinePartners[platform]!.url),
                          icon: const Icon(Icons.open_in_new, size: 17),
                          label: const Text('Online Aç / Kapat'),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 6),
                const Text('Butonlar resmi partner panelini açar. POS içinden anlık aç/kapat yazma işlemi '
                  'API yetkisi ve doğrulanmış restoran durumu olmadan gönderilmez.',
                  style: TextStyle(fontSize: 12, color: NohutBrand.muted)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (source == 'Trendyol Go' || source == 'Tümü')
          Card(
            child: Padding(
              padding: const EdgeInsets.all(15),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Trendyol Go · Menü ve Restoran Yönetimi',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  const SizedBox(height: 5),
                  const Text('Fiyat, ürün/kategori aktif-pasif, çalışma saatleri ve yeni ürün '
                    'işlemleri için partner paneli. Menü API yazma izni doğrulanana kadar '
                    'POS eski fiyatları değiştirmez.'),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: _createTrendyolProductDraft,
                    icon: const Icon(Icons.add_circle_outline),
                    label: const Text('Yeni Ürün Taslağı Oluştur'),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    'Kaydedilmiş yerel taslak: ' +
                    asMaps(widget.integration.store.read().data['tgoProductDrafts'])
                      .length.toString(),
                    style: const TextStyle(fontSize: 12, color: NohutBrand.muted),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final label in const [
                        'Ürün Fiyatı', 'Ürün Aktif / Pasif',
                        'Kategori Aktif / Pasif', 'Çalışma Saatleri',
                        'Yeni Ürün Ekle',
                      ])
                        OutlinedButton.icon(
                          onPressed: () => openExternalPage(context, onlinePartners['Trendyol Go']!.url),
                          icon: const Icon(Icons.open_in_new, size: 16),
                          label: Text(label),
                        ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  const Text('Yeni ürünün yayınlanması ve gerekli bilgiler partner panelindeki '
                    'onay sürecine bağlıdır; POS üzerinden oluşturulmuş sayılmaz.',
                    style: TextStyle(fontSize: 12, color: NohutBrand.muted)),
                ],
              ),
            ),
          ),
        const SizedBox(height: 14),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 9,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final (value, label) in [(false, 'Bugün'), (true, 'Geçmiş')])
                      ChoiceChip(
                        showCheckmark: false,
                        avatar: Icon(value ? Icons.history : Icons.today,
                            size: 16,
                            color: history == value
                                ? Colors.white : NohutBrand.green),
                        label: Text(label,
                            style: TextStyle(
                              color: history == value
                                  ? Colors.white : NohutBrand.ink,
                              fontWeight: FontWeight.w700,
                            )),
                        selectedColor: NohutBrand.green,
                        backgroundColor: Colors.white,
                        selected: history == value,
                        onSelected: (selected) {
                          if (!selected) return;
                          setState(() { history = value; query = ''; });
                        },
                      ),
                    const SizedBox(width: 8),
                    for (final key in ['Tümü', ...onlinePartners.keys])
                      FilterChip(
                        showCheckmark: false,
                        label: Text(onlinePartners[key]?.label ?? key,
                            style: TextStyle(
                              color: source == key
                                  ? Colors.white : NohutBrand.ink,
                              fontWeight: FontWeight.w600,
                            )),
                        selectedColor: NohutBrand.green,
                        backgroundColor: Colors.white,
                        selected: source == key,
                        onSelected: (_) => setState(() => source = key),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 280,
                      child: TextField(
                        key: ValueKey(history),
                        decoration: const InputDecoration(
                          hintText: 'Sipariş numarası veya kodu ara',
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (value) =>
                            setState(() => query = value.trim().toLowerCase()),
                      ),
                    ),
                    if (history) ...[
                      OutlinedButton.icon(
                        onPressed: _pickDate,
                        icon: const Icon(Icons.calendar_today_outlined, size: 17),
                        label: Text(selectedDay ?? 'Tarih seç'),
                      ),
                      if (selectedDay != null)
                        TextButton(
                          onPressed: () => setState(() => selectedDay = null),
                          child: const Text('Tüm tarihler'),
                        ),
                      DropdownButton<String>(
                        value: status,
                        items: [
                          for (final (value, label) in const [
                            ('', 'Tüm durumlar'),
                            ('Created', 'Yeni'),
                            ('Picking', 'Hazırlanıyor'),
                            ('Invoiced', 'Hazır'),
                            ('Shipped', 'Yolda'),
                            ('Delivered', 'Teslim edildi'),
                            ('Cancelled', 'İptal'),
                            ('UnSupplied', 'Karşılanamadı'),
                          ])
                            DropdownMenuItem(value: value, child: Text(label)),
                        ],
                        onChanged: (value) => setState(() => status = value ?? ''),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final partner in partners)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        partner == 'Trendyol Go' && tgoConnected
                            ? Icons.check_circle_outline
                            : Icons.info_outline,
                        size: 17,
                        color: partner == 'Trendyol Go' && canSync
                            ? NohutBrand.green
                            : NohutBrand.gold,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '$partner · ${partner == 'Trendyol Go' ? integration.status : 'Bağlı değil'}',
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: '$partner panelini aç',
                        icon: const Icon(Icons.open_in_new, size: 17),
                        onPressed: () => openExternalPage(context, onlinePartners[partner]!.url),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                if (partners.contains('Trendyol Go'))
                  OutlinedButton.icon(
                    onPressed: integration.syncing || !canSync ? null : integration.sync,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Yenile'),
                  ),
              ],
            ),
          ),
        ),
        if (integration.error.isNotEmpty && partners.contains('Trendyol Go'))
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text(integration.error,
                style: const TextStyle(color: Color(0xffB54737))),
          ),
        const SizedBox(height: 12),
        if (history)
          if (orders.isEmpty)
            const Card(child: ListTile(leading: Icon(Icons.inbox_outlined),
                title: Text('Bu filtrelere uyan sipariş yok.')))
          else
            for (final order in orders)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TgoOrderCard(order: order),
              )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 830;
              final width = wide
                  ? (constraints.maxWidth - 24) / 3
                  : constraints.maxWidth;
              const titles = ['Yeni', 'Hazırlanıyor', 'Hazır'];
              const icons = [Icons.fiber_new_outlined, Icons.restaurant_outlined, Icons.check_circle_outline];
              const tones = [Color(0xffEAF1E7), Color(0xffFFF2DA), Color(0xffE5F3EA)];
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (var i = 0; i < 3; i++)
                    SizedBox(
                      width: width,
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: tones[i],
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xffDCE6DA)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Icon(icons[i], color: NohutBrand.green, size: 19),
                                const SizedBox(width: 8),
                                Expanded(child: Text(titles[i],
                                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800))),
                                CircleAvatar(
                                  radius: 15,
                                  backgroundColor: Colors.white,
                                  child: Text('${groups[i].length}',
                                      style: const TextStyle(fontWeight: FontWeight.bold,
                                          color: NohutBrand.green, fontSize: 12)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            if (groups[i].isEmpty)
                              Container(
                                padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 12),
                                decoration: BoxDecoration(
                                  color: Colors.white.withAlpha(200),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Column(
                                  children: [
                                    Icon(Icons.inbox_outlined, color: NohutBrand.muted),
                                    SizedBox(height: 5),
                                    Text('Bu aşamada sipariş yok',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(color: NohutBrand.muted)),
                                  ],
                                ),
                              ),
                            for (final order in groups[i])
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: TgoOrderCard(
                                  order: order,
                                  onKitchenPrint: () => widget.onPrint(order),
                                  canWrite: integration.canWrite && !integration.writing,
                                  onAction: _applyAction,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        if (!history && completed.isNotEmpty) ...[
          const SizedBox(height: 16),
          Card(
            child: ExpansionTile(
              leading: const Icon(Icons.task_alt, color: NohutBrand.green),
              title: Text('Bugün · Tamamlanan ve iptal edilenler (${completed.length})'),
              subtitle: const Text('Teslim edilen veya kapanan siparişler'),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              children: [
                for (final order in completed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TgoOrderCard(order: order),
                  ),
              ],
            ),
          ),
        ],
        if (source == 'Yemeksepeti')
          Card(
            child: ExpansionTile(
              title: const Text('Yemeksepeti test alanı'),
              subtitle: const Text('Canlı siparişlerle karıştırılmaz'),
              children: [Builder(builder: (_) => widget.demo())],
            ),
          ),
      ],
    );
  }

  static String provider(Json order) => '${order['source'] ?? 'Trendyol Go'}';

  static int _lane(Json order) => switch (order['status']) {
    'Created' => 0,
    'Picking' => 1,
    'Invoiced' => 2,
    _ => 3,
  };
}
