import 'package:flutter/material.dart';

import 'brand.dart';
import 'customer_accounts.dart';
import 'dashboard_sales.dart';
import 'overview_metrics.dart';
import 'pos_logic.dart';

const _channelColors = <String, Color>{
  'Masa': Color(0xff184C3A),
  'Gel-Al': Color(0xff4D7C6D),
  'Trendyol Go': Color(0xffF27A1A),
  'Yemeksepeti': Color(0xffE91E63),
  'Migros Yemek': Color(0xffEF642B),
};

const _border = Color(0xffE1E7E3);
const _up = Color(0xff2E7D4F);
const _down = Color(0xffB3261E);

/// Genel Bakış: today's results compared with earlier days, what needs
/// attention right now, and where the sales come from.
class OverviewPanel extends StatelessWidget {
  const OverviewPanel({
    super.key,
    required this.state,
    required this.businessDay,
    required this.onNavigate,
    this.onlineWarning,
    this.now,
  });

  final Json state;
  final String businessDay;
  final ValueChanged<String> onNavigate;
  final String? onlineWarning;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final clock = now ?? DateTime.now();
    final minute = istanbulMinuteOfDay(clock);
    final today = daySales(state, businessDay);
    final yesterday = daySales(state, shiftDay(businessDay, -1),
      untilMinute: minute);
    final lastWeek = daySales(state, shiftDay(businessDay, -7),
      untilMinute: minute);
    final collected = dayCollections(state, businessDay);
    final live = liveOperations(state, businessDay);
    final top = topProducts(state, businessDay);
    final peak = peakHour(state, businessDay);
    final accounts = pickupOpenAccounts(state);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (onlineWarning != null) ...[
          _Notice(text: onlineWarning!),
          const SizedBox(height: 12),
        ],
        _Grid(minTileWidth: 210, children: [
          _Kpi(
            icon: Icons.payments_outlined,
            label: 'Bugünkü Ciro',
            value: formatTry(today.revenueCents),
            yesterday: percentChange(today.revenueCents, yesterday.revenueCents),
            lastWeek: percentChange(today.revenueCents, lastWeek.revenueCents),
            highlight: true,
          ),
          _Kpi(
            icon: Icons.receipt_long_outlined,
            label: 'Sipariş',
            value: '${today.orders}',
            yesterday: percentChange(today.orders, yesterday.orders),
            lastWeek: percentChange(today.orders, lastWeek.orders),
          ),
          _Kpi(
            icon: Icons.shopping_basket_outlined,
            label: 'Ortalama Sepet',
            value: formatTry(today.averageCents),
            yesterday: percentChange(today.averageCents, yesterday.averageCents),
            lastWeek: percentChange(today.averageCents, lastWeek.averageCents),
          ),
          _Kpi(
            icon: Icons.account_balance_wallet_outlined,
            label: 'Tahsil Edilen',
            value: formatTry(collected.cashCents + collected.cardCents),
            detail: 'Nakit ${formatTry(collected.cashCents)} · '
                'Kart ${formatTry(collected.cardCents)}'
                '${collected.refundCents > 0 ? ' · İade ${formatTry(collected.refundCents)}' : ''}',
          ),
        ]),
        const SizedBox(height: 18),
        const _SectionLabel('Şu An'),
        const SizedBox(height: 8),
        _Grid(minTileWidth: 260, children: [
          _Live(
            icon: Icons.table_restaurant_outlined,
            label: 'Açık Masa',
            value: '${live.openTables} / 5',
            detail: live.openTables == 0
                ? 'Tüm masalar boş'
                : '${formatTry(live.openTableCents)} hesap',
            onTap: () => onNavigate('tables'),
          ),
          _Live(
            icon: Icons.shopping_bag_outlined,
            label: 'Bekleyen Gel-Al',
            value: '${live.openPickups}',
            detail: 'Kapanmamış paket siparişler',
            onTap: () => onNavigate('tables'),
          ),
          _Live(
            icon: Icons.delivery_dining_outlined,
            label: 'Online Aktif',
            value: '${live.onlineNew + live.onlinePreparing + live.onlineReady}',
            detail: 'Yeni ${live.onlineNew} · Hazırlanıyor '
                '${live.onlinePreparing} · Hazır ${live.onlineReady}',
            alert: live.onlineNew > 0,
            onTap: () => onNavigate('online'),
          ),
          _Live(
            icon: Icons.money_outlined,
            label: 'Bugün Nakit Tahsilat',
            value: formatTry(collected.cashCents),
            detail: 'Kart ${formatTry(collected.cardCents)} · iade düşülmüş',
            onTap: () => onNavigate('reports'),
          ),
          _Live(
            icon: Icons.pending_actions_outlined,
            label: 'Ödenmemiş',
            value: formatTry(live.unpaidCents),
            detail: live.cancelledToday == 0
                ? 'Açık masa ve Gel-Al bakiyesi'
                : 'Bugün ${live.cancelledToday} iptal',
            onTap: () => onNavigate('payments'),
          ),
          _Live(
            icon: Icons.menu_book_outlined,
            label: 'Açık Hesaplar',
            value: formatTry(accounts.fold<int>(0, (sum, a) => sum + a.dueCents)),
            detail: '${accounts.length} müşteri · Gel-Al veresiye',
            onTap: () => onNavigate('open-accounts'),
          ),
        ]),
        const SizedBox(height: 18),
        LayoutBuilder(builder: (context, box) {
          final side = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ChannelMix(sales: today),
              const SizedBox(height: 12),
              _TopProducts(rows: top, peak: peak),
            ],
          );
          final chart = DashboardSales(
            state: state,
            businessDay: businessDay,
            showSummary: false,
          );
          if (box.maxWidth < 1100) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [chart, const SizedBox(height: 12), side],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: chart),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: side),
            ],
          );
        }),
      ],
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.children, required this.minTileWidth});
  final List<Widget> children;
  final double minTileWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final n = children.length;
      final fit = ((box.maxWidth + 12) / (minTileWidth + 12)).floor().clamp(1, n);
      // Balance rows (5 tiles on 4 columns → 3 + 2, not 4 + 1).
      final rows = (n / fit).ceil();
      final columns = (n / rows).ceil();
      final width = (box.maxWidth - 12 * (columns - 1)) / columns;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [for (final c in children) SizedBox(width: width, child: c)],
      );
    },
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(text.toUpperCase(),
    style: const TextStyle(fontSize: 11.5, letterSpacing: 1.1,
      fontWeight: FontWeight.w800, color: NohutBrand.muted));
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0xffFFF6E0),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xffEED9A6)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: 18, color: Color(0xff8A6516)),
        const SizedBox(width: 10),
        Expanded(
          child: Text.rich(TextSpan(children: [
            const TextSpan(text: 'Online satış verileri eksik olabilir · ',
              style: TextStyle(fontWeight: FontWeight.w700)),
            TextSpan(text: text),
          ]), style: const TextStyle(color: Color(0xff6B4E10), fontSize: 13)),
        ),
      ],
    ),
  );
}

class _Delta extends StatelessWidget {
  const _Delta(this.label, this.change, {this.onDark = false});
  final String label;
  final double? change;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final muted = onDark ? const Color(0xffBFD6C8) : NohutBrand.muted;
    final value = change;
    if (value == null) {
      return Text('$label —', style: TextStyle(fontSize: 12, color: muted));
    }
    final flat = value.abs() < 0.5;
    final color = flat
        ? muted
        : value > 0
            ? (onDark ? const Color(0xff9FE0B5) : _up)
            : (onDark ? const Color(0xffFFB4A8) : _down);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: TextStyle(fontSize: 12, color: muted)),
        Icon(flat ? Icons.remove : value > 0
            ? Icons.arrow_upward : Icons.arrow_downward,
          size: 13, color: color),
        Text('%${value.abs().toStringAsFixed(0)}', style: TextStyle(
          fontSize: 12, fontWeight: FontWeight.w800, color: color)),
      ],
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({
    required this.icon,
    required this.label,
    required this.value,
    this.yesterday,
    this.lastWeek,
    this.detail,
    this.highlight = false,
  });
  final IconData icon;
  final String label, value;
  final String? detail;
  final double? yesterday, lastWeek;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final fg = highlight ? Colors.white : NohutBrand.ink;
    final muted = highlight ? const Color(0xffBFD6C8) : NohutBrand.muted;
    return Container(
      constraints: const BoxConstraints(minHeight: 128),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: highlight ? NohutBrand.green : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: highlight ? NohutBrand.green : _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 18, color: highlight ? NohutBrand.gold : NohutBrand.green),
            const SizedBox(width: 8),
            Expanded(child: Text(label, style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w700, color: muted))),
          ]),
          const SizedBox(height: 12),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: TextStyle(
              fontSize: 28, fontWeight: FontWeight.w900, color: fg)),
          ),
          const SizedBox(height: 6),
          if (detail != null)
            Text(detail!, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: muted))
          else
            Wrap(
              spacing: 12,
              children: [
                Tooltip(
                  message: 'Dün aynı saate kadar',
                  child: _Delta('Dün', yesterday, onDark: highlight),
                ),
                Tooltip(
                  message: 'Geçen hafta aynı gün, aynı saate kadar',
                  child: _Delta('Geçen hafta', lastWeek, onDark: highlight),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Live extends StatelessWidget {
  const _Live({
    required this.icon,
    required this.label,
    required this.value,
    required this.detail,
    required this.onTap,
    this.alert = false,
  });
  final IconData icon;
  final String label, value, detail;
  final VoidCallback onTap;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    const alertColor = Color(0xff325577);
    return Material(
      color: alert ? const Color(0xffEAF1F8) : Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: alert ? alertColor.withValues(alpha: 0.5) : _border),
          ),
          child: Row(
            children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: (alert ? alertColor : NohutBrand.green)
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 21,
                  color: alert ? alertColor : NohutBrand.green),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: const TextStyle(fontSize: 12,
                      color: NohutBrand.muted, fontWeight: FontWeight.w600)),
                    Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800,
                        color: alert ? alertColor : NohutBrand.ink)),
                    Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5,
                        color: NohutBrand.muted)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 18, color: Color(0xffA9B3AD)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: _border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(child: Text(title, style: const TextStyle(
            fontSize: 16, fontWeight: FontWeight.w800))),
          ?trailing,
        ]),
        const SizedBox(height: 12),
        child,
      ],
    ),
  );
}

class _ChannelMix extends StatelessWidget {
  const _ChannelMix({required this.sales});
  final DaySales sales;

  @override
  Widget build(BuildContext context) {
    final total = sales.revenueCents;
    final channels = [
      for (final c in overviewChannels)
        if ((sales.channelOrders[c] ?? 0) > 0) c,
    ];
    return _Panel(
      title: 'Kanal Dağılımı',
      trailing: Text(formatTry(total), style: const TextStyle(
        fontWeight: FontWeight.w800, color: NohutBrand.green)),
      child: total <= 0
          ? const Text('Bugün henüz satış yok.',
              style: TextStyle(color: NohutBrand.muted))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    height: 12,
                    child: Row(children: [
                      for (final c in channels)
                        Expanded(
                          flex: ((sales.channelCents[c]! * 1000) / total)
                              .round().clamp(1, 1000),
                          child: Container(color: _channelColors[c]),
                        ),
                    ]),
                  ),
                ),
                const SizedBox(height: 10),
                for (final c in channels)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Container(width: 10, height: 10,
                        decoration: BoxDecoration(
                          color: _channelColors[c],
                          borderRadius: BorderRadius.circular(3))),
                      const SizedBox(width: 8),
                      Expanded(child: Text(c, style: const TextStyle(
                        fontWeight: FontWeight.w600))),
                      Text('${sales.channelOrders[c]} sipariş',
                        style: const TextStyle(fontSize: 12,
                          color: NohutBrand.muted)),
                      SizedBox(
                        width: 48,
                        child: Text(
                          '%${(sales.channelCents[c]! * 100 / total).toStringAsFixed(0)}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 12,
                            color: NohutBrand.muted)),
                      ),
                      SizedBox(
                        width: 96,
                        child: Text(formatTry(sales.channelCents[c]!),
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ]),
                  ),
              ],
            ),
    );
  }
}

class _TopProducts extends StatelessWidget {
  const _TopProducts({required this.rows, required this.peak});
  final List<ProductSales> rows;
  final ({int hour, int orders})? peak;

  @override
  Widget build(BuildContext context) {
    final best = rows.isEmpty ? 1 : rows.first.quantity;
    final busiest = peak;
    return _Panel(
      title: 'En Çok Satanlar',
      trailing: busiest == null ? null : Tooltip(
        message: 'Bugün en çok siparişin geldiği saat',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xffF1F4F2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            'Yoğun saat ${busiest.hour.toString().padLeft(2, '0')}:00 · '
            '${busiest.orders} sipariş',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
              color: NohutBrand.green)),
        ),
      ),
      child: rows.isEmpty
          ? const Text('Bugün henüz ürün satılmadı.',
              style: TextStyle(color: NohutBrand.muted))
          : Column(
              children: [
                for (final (i, p) in rows.indexed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(children: [
                      SizedBox(width: 22, child: Text('${i + 1}',
                        style: const TextStyle(fontWeight: FontWeight.w800,
                          color: NohutBrand.gold))),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Expanded(child: Text(p.name,
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600))),
                              Text('${p.quantity} adet',
                                style: const TextStyle(fontSize: 12,
                                  color: NohutBrand.muted)),
                              const SizedBox(width: 10),
                              SizedBox(width: 86, child: Text(
                                formatTry(p.cents),
                                textAlign: TextAlign.right,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700))),
                            ]),
                            const SizedBox(height: 4),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: LinearProgressIndicator(
                                value: p.quantity / best,
                                minHeight: 5,
                                color: NohutBrand.green,
                                backgroundColor: const Color(0xffEEF2EF),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ]),
                  ),
                const SizedBox(height: 4),
                const Text('Masa ve Gel-Al satışları',
                  style: TextStyle(fontSize: 11.5, color: NohutBrand.muted)),
              ],
            ),
    );
  }
}
