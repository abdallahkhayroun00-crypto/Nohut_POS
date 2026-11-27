// §24.3 Personel Ana Sayfa: the signed-in employee's own week (actual hours,
// plan, pay) from the server session, today's floor at a glance and the
// quick actions. Nothing here selects or shows another employee.
import 'package:flutter/material.dart';

import 'pos_api.dart';
import 'style.dart';
import 'work_page.dart' show WorkFormat;

class PersonelDashboard extends StatefulWidget {
  const PersonelDashboard({
    super.key,
    required this.api,
    required this.name,
    required this.busyTables,
    required this.openPickups,
    required this.openOrders,
    required this.onTables,
    required this.onNewOrder,
    required this.onOrders,
    required this.onWork,
    required this.onLogin,
  });
  final NohutApi api;
  final String? name;
  final int busyTables, openPickups, openOrders;
  final VoidCallback onTables, onNewOrder, onOrders, onLogin;
  /// Opens Mesai ve Maaşım on a tab: 0 Mesai, 1 Vardiya, 2 Maaş.
  final ValueChanged<int> onWork;

  @override
  State<PersonelDashboard> createState() => _PersonelDashboardState();
}

class _PersonelDashboardState extends State<PersonelDashboard> {
  Json? week;
  String? today;
  String? error;
  bool loading = false;

  bool get _canWork => widget.api.signedIn && widget.api.sessionEmployeeId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_canWork) return;
    setState(() { loading = true; error = null; });
    try {
      final (status, body) = await widget.api.work('GET', 'week');
      if (!mounted) return;
      if (status == 200 && body['week'] is Map) {
        setState(() { week = Map<String, dynamic>.from(body['week'] as Map); today = '${body['today'] ?? ''}'; });
      } else {
        setState(() => error = 'Haftalık bilgiler alınamadı.');
      }
    } catch (_) {
      if (mounted) setState(() => error = 'Haftalık bilgiler için Windows bağlantısı gerekli.');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Json? get _nextPlan {
    final t = today ?? '';
    final plans = rows(week?['plans']).where((p) => p['dayOff'] != true && p['cancelled'] != true &&
        '${p['date']}'.compareTo(t) >= 0).toList()
      ..sort((a, b) => '${a['date']} ${a['start']}'.compareTo('${b['date']} ${b['start']}'));
    return plans.firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final nc = context.nohut;
    final st = week?['status'] is Map ? week!['status'] as Map : const {};
    final pay = week?['pay'] is Map ? week!['pay'] as Map : null;
    final next = _nextPlan;
    final emp = week?['employee'] is Map ? week!['employee'] as Map : const {};
    final name = emp['name'] is String ? '${emp['name']}' : widget.name;
    String m(Object? v) => v is int ? money(v) : '—';
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        Text(name == null ? 'Hoş geldiniz' : 'Merhaba, $name',
            style: Theme.of(context).textTheme.headlineSmall),
        Text(today == null ? 'Ana Sayfa' : WorkFormat.day(today!), style: TextStyle(color: nc.muted)),
        const SizedBox(height: 14),
        _actions(context),
        const NohutSection('Bu hafta'),
        if (!_canWork)
          Card(child: NohutEmpty(icon: Icons.badge_outlined,
              message: 'Mesai, vardiya ve maaşınızı görmek için kendi hesabınızla giriş yapın.',
              action: 'Giriş Yap', onAction: widget.onLogin))
        else if (loading && week == null)
          const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator())
        else if (error != null && week == null)
          Card(child: NohutEmpty(icon: Icons.cloud_off_outlined, message: error!, action: 'Tekrar dene', onAction: _load))
        else ...[
          NohutMetricGrid(minTileWidth: 140, children: [
            NohutMetric(label: 'Çalışılan', value: WorkFormat.hours(st['minutes']), icon: Icons.timer_outlined,
                caption: st['status'] is String ? '${st['status']}' : null),
            NohutMetric(label: 'Plan', value: WorkFormat.hours(week?['plannedMinutes']), icon: Icons.calendar_month_outlined),
            if (pay != null && pay['payrollEligible'] != false) ...[
              NohutMetric(label: 'Kazanılan', value: m(pay['earnedCents']), icon: Icons.trending_up),
              NohutMetric(label: 'Kalan', value: m(pay['remainingCents']), icon: Icons.account_balance_wallet_outlined,
                  caption: pay['financialStatus'] is String ? '${pay['financialStatus']}' : null),
            ],
          ]),
          const SizedBox(height: 10),
          Card(child: ListTile(
            leading: const Icon(Icons.event_outlined),
            title: Text(next == null ? 'Planlı vardiya yok' : '${WorkFormat.day('${next['date']}')} · ${next['start']}–${next['end']}',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text('Sıradaki vardiyanız'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => widget.onWork(1),
          )),
        ],
        const NohutSection('Restoran'),
        NohutMetricGrid(minTileWidth: 140, children: [
          NohutMetric(label: 'Dolu masa', value: '${widget.busyTables} / 5', icon: Icons.table_restaurant_outlined),
          NohutMetric(label: 'Açık sipariş', value: '${widget.openOrders}', icon: Icons.receipt_long_outlined,
              caption: 'Gel-Al: ${widget.openPickups}'),
        ]),
      ]),
    );
  }

  Widget _actions(BuildContext context) {
    final items = <(IconData, String, VoidCallback)>[
      (Icons.table_restaurant_outlined, 'Masalar', widget.onTables),
      (Icons.add_shopping_cart, 'Sipariş Al', widget.onNewOrder),
      (Icons.receipt_long_outlined, 'Siparişler', widget.onOrders),
      if (_canWork) ...[
        (Icons.more_time, 'Mesai Ekle', () => widget.onWork(0)),
        (Icons.edit_calendar_outlined, 'Vardiya Ekle', () => widget.onWork(1)),
        (Icons.payments_outlined, 'Maaş & Avans', () => widget.onWork(2)),
      ],
    ];
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth >= 600 ? 6 : 3;
      final w = (c.maxWidth - 10 * (cols - 1)) / cols;
      return Wrap(spacing: 10, runSpacing: 10, children: [
        for (final (icon, label, onTap) in items)
          SizedBox(width: w, child: Material(
            color: context.nohut.card,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: context.nohut.outline)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(onTap: onTap, child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
              child: Column(children: [
                CircleAvatar(radius: 20, backgroundColor: scheme.secondaryContainer,
                    foregroundColor: scheme.onSecondaryContainer, child: Icon(icon, size: 21)),
                const SizedBox(height: 8),
                Text(label, textAlign: TextAlign.center, maxLines: 2,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              ]),
            )),
          )),
      ]);
    });
  }
}
