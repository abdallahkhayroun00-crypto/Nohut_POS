// Ekip Performansı (W5, Yönetici): every person's orders, additions, sales
// and Mesai hours for today, this week or this month, from Windows
// `ownerTeamPerformance`. Same attribution as each person's Performansım.
import 'package:flutter/material.dart';

import 'pos_api.dart';
import 'style.dart';
import 'work_page.dart' show WorkFormat;

class TeamPerformancePage extends StatefulWidget {
  const TeamPerformancePage({super.key, required this.request, this.initialRange = 'day'});
  /// The paired owner channel (`OwnerApi.request`).
  final Future<Json> Function(Json payload) request;
  final String initialRange;
  @override
  State<TeamPerformancePage> createState() => _TeamPerformancePageState();
}

class _TeamPerformancePageState extends State<TeamPerformancePage> {
  late String range = widget.initialRange;
  Json? data;
  String? error;
  bool loading = true;
  int? open;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final asked = range;
    setState(() { loading = true; error = null; });
    try {
      final r = await widget.request({'operation': 'ownerTeamPerformance', 'range': asked});
      if (!mounted || asked != range) return;
      setState(() {
        if (r['team'] is Map) {
          data = Map<String, dynamic>.from(r['team'] as Map);
        } else {
          error = '${r['message'] ?? 'Ekip performansı alınamadı.'}';
        }
      });
    } on Object catch (e) {
      if (mounted) setState(() => error = e is FormatException ? e.message : 'Windows’a ulaşılamadı.');
    } finally {
      if (mounted && asked == range) setState(() => loading = false);
    }
  }

  static int _i(Object? v) => v is num ? v.toInt() : 0;

  Widget _person(BuildContext context, Map p, int topCents) {
    final nc = context.nohut;
    final id = _i(p['employeeId']);
    final idle = _i(p['orders']) + _i(p['additions']) + _i(p['workedMinutes']) == 0;
    final share = topCents <= 0 ? 0.0 : (_i(p['salesCents']) / topCents).clamp(0.0, 1.0);
    final expanded = open == id;
    return Card(
      key: ValueKey('team-person-$id'),
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: idle ? null : () => setState(() => open = expanded ? null : id),
        child: Padding(padding: const EdgeInsets.fromLTRB(14, 12, 14, 12), child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('${p['name']}${p['active'] == false ? ' · ayrıldı' : ''}',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5,
                color: idle ? nc.muted : null))),
            Text(idle ? '—' : money(_i(p['salesCents'])),
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
          ]),
          const SizedBox(height: 4),
          Text(idle ? 'Bu dönemde kayıt yok'
              : '${_i(p['orders'])} sipariş · ${_i(p['additions'])} ek · ${WorkFormat.hours(_i(p['workedMinutes']))}',
            style: TextStyle(color: nc.muted, fontSize: 13)),
          if (!idle) ...[
            const SizedBox(height: 8),
            ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(
              value: share, minHeight: 6,
              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest)),
          ],
          if (expanded) ...[
            const SizedBox(height: 12),
            NohutMetricGrid(minTileWidth: 130, children: [
              NohutMetric(label: 'Masa', value: '${_i(p['tables'])}', icon: Icons.table_restaurant_outlined),
              NohutMetric(label: 'Gel-Al', value: '${_i(p['pickups'])}', icon: Icons.takeout_dining_outlined),
              NohutMetric(label: 'Ortalama', value: p['averageCents'] == null ? '—' : money(_i(p['averageCents'])),
                icon: Icons.functions),
              NohutMetric(label: 'Açık', value: '${_i(p['openOrders'])}', icon: Icons.receipt_long_outlined),
              NohutMetric(label: 'İptal', value: '${_i(p['cancelled'])}', icon: Icons.block),
              NohutMetric(label: 'Çalıştığı gün', value: '${_i(p['activeDays'])}', icon: Icons.event_available_outlined),
            ]),
          ],
        ])),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    final nc = context.nohut;
    final people = [for (final p in (d?['people'] as List? ?? const [])) p as Map];
    final topCents = people.fold<int>(0, (n, p) => _i(p['salesCents']) > n ? _i(p['salesCents']) : n);
    final totals = (d?['totals'] as Map?) ?? const {};
    final unassigned = (d?['unassigned'] as Map?) ?? const {};
    return Scaffold(
      appBar: AppBar(title: const Text('Ekip Performansı')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          SegmentedButton<String>(
            key: const ValueKey('team-performance-range'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'day', label: Text('Bugün')),
              ButtonSegment(value: 'week', label: Text('Bu Hafta')),
              ButtonSegment(value: 'month', label: Text('Bu Ay')),
            ],
            selected: {range},
            onSelectionChanged: (s) { setState(() { range = s.first; open = null; }); _load(); },
          ),
          const SizedBox(height: 14),
          if (loading && d == null)
            const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
          else if (error != null && d == null)
            Card(child: NohutEmpty(icon: Icons.groups_outlined, message: error!,
              action: 'Tekrar dene', onAction: _load))
          else if (d != null) ...[
            if (d['from'] != null)
              Padding(padding: const EdgeInsets.only(bottom: 10),
                child: Text(d['from'] == d['to'] ? WorkFormat.day('${d['from']}')
                    : '${WorkFormat.day('${d['from']}')} – ${WorkFormat.day('${d['to']}')}',
                  style: TextStyle(color: nc.muted, fontWeight: FontWeight.w600))),
            NohutMetric(
              key: const ValueKey('team-performance-total'),
              emphasis: true,
              icon: Icons.groups_outlined,
              label: 'Ekibin aldığı siparişler',
              value: money(_i(totals['salesCents'])),
              caption: '${_i(totals['orders'])} sipariş · ${WorkFormat.hours(_i(totals['workedMinutes']))} mesai'),
            const SizedBox(height: 14),
            if (people.isEmpty)
              const Card(child: NohutEmpty(icon: Icons.groups_outlined, message: 'Personel kaydı yok.'))
            else
              for (final p in people) _person(context, p, topCents),
            if (_i(unassigned['orders']) > 0)
              Card(key: const ValueKey('team-unassigned'), child: ListTile(
                leading: const Icon(Icons.help_outline),
                title: const Text('Atanmamış', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${_i(unassigned['orders'])} eski sipariş, kimin aldığı kayıtlı değil'),
                trailing: Text(money(_i(unassigned['salesCents'])),
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)))),
            const SizedBox(height: 10),
            Text('${d['note'] ?? ''} Online platform siparişleri dahil değildir. '
                'Saatler yalnızca Mesai kayıtlarından gelir.',
              style: TextStyle(fontSize: 12.5, color: nc.muted, height: 1.35)),
          ],
        ]),
      ),
    );
  }
}
