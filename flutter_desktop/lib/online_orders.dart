import 'dart:async';

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
  // Refreshes the waiting-time badges on active orders.
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

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
    final completed = orders.where((order) => _lane(order) == 3).toList();
    final now = DateTime.now();
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
          Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: const Color(0xffFBE9E6),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              const Icon(Icons.error_outline, size: 18, color: Color(0xffB54737)),
              const SizedBox(width: 8),
              Expanded(child: Text(integration.error,
                style: const TextStyle(color: Color(0xffB54737)))),
            ]),
          ),
        const SizedBox(height: 14),
        if (history)
          _HistoryList(orders: orders, onOpen: _openOrder)
        else ...[
          _Summary(
            counts: [for (final g in groups) g.length],
            late: [for (final g in groups) g.where((o) => tgoOrderLate(o, now)).length],
            revenueCents: orders
                .where((o) => !const ['Cancelled', 'UnSupplied'].contains(o['status']))
                .fold<int>(0, (sum, o) => sum + (o['totalCents'] as int? ?? 0)),
            orderCount: orders
                .where((o) => !const ['Cancelled', 'UnSupplied'].contains(o['status']))
                .length,
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              Widget lane(int i) => _Lane(
                index: i,
                orders: groups[i],
                card: (order) => TgoOrderCard(
                  order: order,
                  now: now,
                  onKitchenPrint: () => widget.onPrint(order),
                  canWrite: integration.canWrite && !integration.writing,
                  onAction: _applyAction,
                ),
              );
              if (constraints.maxWidth < 830) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < 3; i++) ...[
                      if (i > 0) const SizedBox(height: 12),
                      lane(i),
                    ],
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < 3; i++) ...[
                    if (i > 0) const SizedBox(width: 12),
                    Expanded(child: lane(i)),
                  ],
                ],
              );
            },
          ),
          if (completed.isNotEmpty) ...[
            const SizedBox(height: 16),
            Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                leading: const Icon(Icons.task_alt, color: NohutBrand.green),
                title: Text('Bugün · Tamamlanan ve iptal edilenler (${completed.length})',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('Ayrıntı için satıra tıklayın'),
                childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                children: [
                  for (final order in completed)
                    _OrderRow(order: order, onTap: () => _openOrder(order)),
                ],
              ),
            ),
          ],
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

  void _openOrder(Json order) => showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 720),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(6),
          child: TgoOrderCard(order: order),
        ),
      ),
    ),
  );

  static String provider(Json order) => '${order['source'] ?? 'Trendyol Go'}';

  static int _lane(Json order) => switch (order['status']) {
    'Created' => 0,
    'Picking' => 1,
    'Invoiced' => 2,
    _ => 3,
  };
}


const _laneMeta = [
  ('Yeni', 'Onay bekliyor', Icons.notifications_active_outlined, Color(0xff325577)),
  ('Hazırlanıyor', 'Mutfakta', Icons.restaurant_outlined, Color(0xffB7791F)),
  ('Hazır', 'Kurye bekliyor', Icons.shopping_bag_outlined, Color(0xff2E7D4F)),
];

class _Summary extends StatelessWidget {
  const _Summary({
    required this.counts,
    required this.late,
    required this.revenueCents,
    required this.orderCount,
  });
  final List<int> counts, late;
  final int revenueCents, orderCount;

  @override
  Widget build(BuildContext context) {
    Widget tile({
      required IconData icon,
      required Color color,
      required String label,
      required String value,
      String? note,
      bool alert = false,
    }) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: alert ? color.withValues(alpha: 0.08) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: alert ? color.withValues(alpha: 0.5) : const Color(0xffE1E7E3)),
      ),
      child: Row(
        children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12, color: NohutBrand.muted,
                    fontWeight: FontWeight.w600)),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Text(value, maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 21,
                          fontWeight: FontWeight.w800,
                          color: alert ? color : NohutBrand.ink)),
                    ),
                    if (note != null) ...[
                      const SizedBox(width: 8),
                      Text(note, style: TextStyle(fontSize: 12,
                        color: color, fontWeight: FontWeight.w700)),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
    final tiles = [
      for (var i = 0; i < 3; i++)
        tile(
          icon: _laneMeta[i].$3,
          color: late[i] > 0 ? const Color(0xffB3261E) : _laneMeta[i].$4,
          label: '${_laneMeta[i].$1} · ${_laneMeta[i].$2}',
          value: '${counts[i]}',
          note: late[i] > 0 ? '${late[i]} gecikmede' : null,
          alert: (i == 0 && counts[i] > 0) || late[i] > 0,
        ),
      tile(
        icon: Icons.payments_outlined,
        color: NohutBrand.green,
        label: 'Bugün · $orderCount sipariş',
        value: formatTry(revenueCents),
      ),
    ];
    return LayoutBuilder(builder: (context, box) {
      final columns = box.maxWidth >= 900 ? 4 : 2;
      final width = (box.maxWidth - 10 * (columns - 1)) / columns;
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [for (final t in tiles) SizedBox(width: width, child: t)],
      );
    });
  }
}

class _Lane extends StatelessWidget {
  const _Lane({required this.index, required this.orders, required this.card});
  final int index;
  final List<Json> orders;
  final Widget Function(Json order) card;

  @override
  Widget build(BuildContext context) {
    final (title, subtitle, icon, color) = _laneMeta[index];
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xffF4F6F2),
        borderRadius: BorderRadius.circular(16),
        border: Border(top: BorderSide(color: color, width: 4)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: title, style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800)),
                      TextSpan(text: '  · $subtitle', style: const TextStyle(
                        fontSize: 12.5, color: NohutBrand.muted)),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  constraints: const BoxConstraints(minWidth: 28),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: orders.isEmpty ? Colors.white : color,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text('${orders.length}', textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13,
                      color: orders.isEmpty ? NohutBrand.muted : Colors.white)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          if (orders.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xffDDE3DF)),
              ),
              child: const Column(
                children: [
                  Icon(Icons.inbox_outlined, color: Color(0xffA9B3AD)),
                  SizedBox(height: 4),
                  Text('Bu aşamada sipariş yok',
                    style: TextStyle(color: NohutBrand.muted, fontSize: 12.5)),
                ],
              ),
            ),
          for (final (i, order) in orders.indexed) ...[
            if (i > 0) const SizedBox(height: 10),
            card(order),
          ],
        ],
      ),
    );
  }
}

/// One compact line per closed order; tapping opens the full card.
class _OrderRow extends StatelessWidget {
  const _OrderRow({required this.order, required this.onTap});
  final Json order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (label, fg, bg) = tgoStatusStyle('${order['status'] ?? ''}');
    final items = asMaps(order['lines'])
        .map((l) => '${l['qty']}× ${l['name']}')
        .join(', ');
    final stamp = istanbulStamp(order['createdAt']);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        child: Row(
          children: [
            SizedBox(
              width: 132,
              child: Text(stamp, style: const TextStyle(
                fontSize: 12.5, color: NohutBrand.muted)),
            ),
            SizedBox(
              width: 72,
              child: Text('#${displayOrderNumber(order)}',
                style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(items.isEmpty ? '—' : items,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text('${order['source'] ?? 'Trendyol Go'} · '
                      'Platform no: ${order['orderNumber']}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12, color: NohutBrand.muted)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(formatTry(order['totalCents'] as int? ?? 0),
              style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            Container(
              width: 104,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                color: bg, borderRadius: BorderRadius.circular(14)),
              child: Text(label, style: TextStyle(
                color: fg, fontWeight: FontWeight.w700, fontSize: 12)),
            ),
            const Icon(Icons.chevron_right, color: NohutBrand.muted),
          ],
        ),
      ),
    );
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({required this.orders, required this.onOpen});
  final List<Json> orders;
  final void Function(Json order) onOpen;

  @override
  Widget build(BuildContext context) {
    if (orders.isEmpty) {
      return const Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 36),
          child: Column(children: [
            Icon(Icons.inbox_outlined, size: 32, color: Color(0xffA9B3AD)),
            SizedBox(height: 6),
            Text('Bu filtrelere uyan sipariş yok.',
              style: TextStyle(color: NohutBrand.muted)),
          ]),
        ),
      );
    }
    final valid = orders.where(
      (o) => !const ['Cancelled', 'UnSupplied'].contains(o['status']));
    final total = valid.fold<int>(
      0, (sum, o) => sum + (o['totalCents'] as int? ?? 0));
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text(
                '${orders.length} sipariş · ${valid.length} geçerli · '
                'Toplam ${formatTry(total)}',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            for (final (i, order) in orders.indexed) ...[
              if (i > 0) const Divider(height: 1),
              _OrderRow(order: order, onTap: () => onOpen(order)),
            ],
          ],
        ),
      ),
    );
  }
}
