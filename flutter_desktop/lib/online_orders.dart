import 'package:flutter/material.dart';

import 'brand.dart';
import 'order_reporting.dart';
import 'pos_logic.dart';
import 'trendyol_go_readonly.dart';
import 'trendyol_go_ui.dart';

const onlinePartners = {
  'Trendyol Go': (
    label: 'Uber Eats Trendyol Go',
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
          if ((history
                  ? day.compareTo(widget.businessDay) >= 0
                  : day != widget.businessDay) ||
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (value, label) in [(false, 'Bugün'), (true, 'Geçmiş')])
              ChoiceChip(
                label: Text(label),
                selected: history == value,
                onSelected: (_) => setState(() => history = value),
              ),
            const SizedBox(width: 12),
            for (final key in ['Tümü', ...onlinePartners.keys])
              FilterChip(
                label: Text(onlinePartners[key]?.label ?? key),
                selected: source == key,
                onSelected: (_) => setState(() => source = key),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            for (final partner in partners)
              OutlinedButton.icon(
                onPressed: () =>
                    openExternalPage(context, onlinePartners[partner]!.url),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text('${onlinePartners[partner]!.label} paneli'),
              ),
            if (partners.contains('Trendyol Go'))
              IconButton(
                tooltip: 'Trendyol Go siparişlerini yenile',
                icon: const Icon(Icons.refresh),
                onPressed:
                    integration.syncing ||
                        integration.credentials?.valid != true ||
                        !TrendyolGoReadonly.liveSyncEnabled
                    ? null
                    : integration.sync,
              ),
          ],
        ),
        if (partners.contains('Trendyol Go')) ...[
          Text('Trendyol Go · ${integration.status}'),
          if (integration.error.isNotEmpty) Text(integration.error),
          if (integration.syncing) const LinearProgressIndicator(),
        ],
        for (final partner in partners.where((p) => p != 'Trendyol Go'))
          Text('$partner · Bağlı değil'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 230,
              child: TextField(
                decoration: const InputDecoration(
                  labelText: 'Sipariş No / Kod',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (value) =>
                    setState(() => query = value.trim().toLowerCase()),
              ),
            ),
            if (history) ...[
              OutlinedButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.calendar_today_outlined),
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
        const SizedBox(height: 16),
        if (history)
          if (orders.isEmpty)
            const ListTile(title: Text('Bu filtrelere uyan sipariş yok.'))
          else
            for (final order in orders) TgoOrderCard(order: order)
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 830;
              final width = wide
                  ? (constraints.maxWidth - 24) / 3
                  : constraints.maxWidth;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final (i, title) in [
                    'Yeni',
                    'Hazırlanıyor',
                    'Hazır',
                  ].indexed)
                    SizedBox(
                      width: width,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: NohutBrand.green.withAlpha(12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ListTile(
                                dense: true,
                                title: Text(title),
                                trailing: Text('${groups[i].length}'),
                              ),
                              for (final order in groups[i])
                                TgoOrderCard(
                                  order: order,
                                  onKitchenPrint: () => widget.onPrint(order),
                                ),
                              if (groups[i].isEmpty)
                                const Padding(
                                  padding: EdgeInsets.all(10),
                                  child: Text('Sipariş yok'),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        if (!history && completed.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            'Bugün · Tamamlanan ve iptal edilenler',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          for (final order in completed) TgoOrderCard(order: order),
        ],
        if (source == 'Yemeksepeti')
          ExpansionTile(
            title: const Text('Yemeksepeti test alanı'),
            children: [Builder(builder: (_) => widget.demo())],
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
