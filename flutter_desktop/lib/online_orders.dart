import 'package:flutter/material.dart';

import 'brand.dart';
import 'order_reporting.dart';
import 'pos_logic.dart';
import 'trendyol_go_readonly.dart';
import 'trendyol_go_ui.dart';

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
    int? preparationMinutes;
    if (action == 'cancel') {
      const reasons = tgoCancelReasons;
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
    } else if (action == 'accept') {
      final suggested = order['preparationMinutes'];
      var minutes = suggested is int && suggested >= 1 && suggested <= 120
          ? '$suggested' : '20';
      final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Kabul Et · Hazırlama Süresi'),
          content: SizedBox(
            width: 360,
            child: TextFormField(
              key: const ValueKey('tgo-preparation-minutes'),
              initialValue: minutes,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Hazırlama süresi (dakika, 1-120)'),
              onChanged: (next) => minutes = next,
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('Vazgeç')),
            FilledButton(onPressed: () => Navigator.pop(ctx, minutes),
              child: const Text('Devam Et')),
          ],
        ),
      );
      if (result == null || !mounted) return;
      preparationMinutes = int.tryParse(result.trim());
      if (preparationMinutes == null ||
          preparationMinutes < 1 || preparationMinutes > 120) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(
            'Hazırlama süresi 1-120 dakika arasında olmalı.')),
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
          '${preparationMinutes == null ? '' : '\nHazırlama süresi: $preparationMinutes dk'}'
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
        preparationMinutes: preparationMinutes,
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
    Widget partnerPill(String partner) {
      final isTgo = partner == 'Trendyol Go';
      final statusText = isTgo ? integration.status : 'Bağlı değil';
      final ok = isTgo && tgoConnected;
      final warn = isTgo && canSync && !tgoConnected;
      final tone = ok
          ? const Color(0xff2E7D4F)
          : warn ? const Color(0xffB7791F) : const Color(0xff9AA49F);
      return Tooltip(
        message: '$partner panelini aç',
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => openExternalPage(context, onlinePartners[partner]!.url),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: tone.withValues(alpha: 0.35)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
                ),
                const SizedBox(width: 7),
                Text('$partner · $statusText',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 12,
                    color: NohutBrand.ink)),
                const SizedBox(width: 5),
                const Icon(Icons.open_in_new, size: 13, color: NohutBrand.muted),
              ],
            ),
          ),
        ),
      );
    }

    Widget chip({
      required String label,
      required bool selected,
      required VoidCallback onTap,
      IconData? icon,
      bool choice = false,
    }) {
      final text = Text(label, style: TextStyle(
        color: selected ? Colors.white : NohutBrand.ink,
        fontWeight: FontWeight.w700, fontSize: 13));
      final avatar = icon == null ? null : Icon(icon, size: 16,
        color: selected ? Colors.white : NohutBrand.green);
      const shape = StadiumBorder(side: BorderSide(color: Color(0xffD5DED8)));
      return choice
          ? ChoiceChip(
              showCheckmark: false, avatar: avatar, label: text,
              selected: selected, selectedColor: NohutBrand.green,
              backgroundColor: Colors.white, shape: shape,
              visualDensity: VisualDensity.compact,
              onSelected: (value) { if (value) onTap(); },
            )
          : FilterChip(
              showCheckmark: false, label: text,
              selected: selected, selectedColor: NohutBrand.green,
              backgroundColor: Colors.white, shape: shape,
              visualDensity: VisualDensity.compact,
              onSelected: (_) => onTap(),
            );
    }

    final search = TextField(
      key: ValueKey(history),
      decoration: const InputDecoration(
        isDense: true,
        hintText: 'Sipariş no veya kod ara',
        prefixIcon: Icon(Icons.search, size: 20),
      ),
      onChanged: (value) =>
          setState(() => query = value.trim().toLowerCase()),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // One compact header: title + live platform status, then filters.
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.delivery_dining_outlined,
                          color: NohutBrand.green, size: 24),
                        const SizedBox(width: 8),
                        Tooltip(
                          message: 'Tüm platformlar tek ekranda · Bağlantısı '
                            'olmayan platformlar otomatik sipariş göndermez.',
                          child: Text('Sipariş Merkezi',
                            style: Theme.of(context).textTheme.titleLarge),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ),
                    for (final partner in partners) partnerPill(partner),
                    if (partners.contains('Trendyol Go'))
                      integration.syncing
                          ? const Padding(
                              padding: EdgeInsets.all(8),
                              child: SizedBox(width: 18, height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          : IconButton(
                              tooltip: 'Trendyol Go siparişlerini yenile',
                              onPressed: canSync ? integration.sync : null,
                              icon: const Icon(Icons.refresh, size: 20),
                              visualDensity: VisualDensity.compact,
                            ),
                  ],
                ),
                const Divider(height: 20),
                LayoutBuilder(builder: (context, box) {
                  final filters = Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final (value, label) in [(false, 'Bugün'), (true, 'Geçmiş')])
                        chip(
                          label: label, choice: true,
                          icon: value ? Icons.history : Icons.today,
                          selected: history == value,
                          onTap: () => setState(() { history = value; query = ''; }),
                        ),
                      Container(width: 1, height: 22,
                        margin: const EdgeInsets.symmetric(horizontal: 6),
                        color: const Color(0xffD5DED8)),
                      for (final key in ['Tümü', ...onlinePartners.keys])
                        chip(
                          label: onlinePartners[key]?.label ?? key,
                          selected: source == key,
                          onTap: () => setState(() => source = key),
                        ),
                    ],
                  );
                  if (box.maxWidth < 900) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [filters, const SizedBox(height: 10), search],
                    );
                  }
                  return Row(children: [
                    Expanded(child: filters),
                    const SizedBox(width: 12),
                    SizedBox(width: 260, child: search),
                  ]);
                }),
                if (history) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
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
                  ),
                ],
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
