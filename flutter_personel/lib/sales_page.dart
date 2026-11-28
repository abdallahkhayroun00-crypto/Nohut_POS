// Satış Analizi (Yönetici): daily collections, best sellers and online
// totals from Windows `ownerSales`, the same rows as Windows Raporlar.
import 'package:flutter/material.dart';

import 'pos_api.dart';
import 'style.dart';
import 'work_page.dart' show WorkFormat;

class SalesPage extends StatefulWidget {
  const SalesPage({super.key, required this.request, this.initialRange = 'week'});
  final Future<Json> Function(Json payload) request;
  final String initialRange;
  @override
  State<SalesPage> createState() => _SalesPageState();
}

class _SalesPageState extends State<SalesPage> {
  late String range = widget.initialRange;
  Json? data;
  String? error;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final asked = range;
    setState(() { loading = true; error = null; });
    try {
      final r = await widget.request({'operation': 'ownerSales', 'range': asked});
      if (!mounted || asked != range) return;
      setState(() {
        if (r['sales'] is Map) {
          data = Map<String, dynamic>.from(r['sales'] as Map);
        } else {
          error = '${r['message'] ?? 'Satış bilgisi alınamadı.'}';
        }
      });
    } on Object catch (e) {
      if (mounted) setState(() => error = e is FormatException ? e.message : 'Windows’a ulaşılamadı.');
    } finally {
      if (mounted && asked == range) setState(() => loading = false);
    }
  }

  static int _i(Object? v) => v is num ? v.toInt() : 0;

  Widget _bars(BuildContext context, List<Map> daily) {
    final nc = context.nohut;
    final max = daily.fold<int>(1, (m, d) => _i(d['netCents']) > m ? _i(d['netCents']) : m);
    final many = daily.length > 10;
    return SizedBox(height: 150, child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      for (final (i, d) in daily.indexed)
        Expanded(child: Tooltip(
          message: '${WorkFormat.day('${d['day']}')} · ${money(_i(d['netCents']))} · ${_i(d['orderCount'])} sipariş',
          child: Padding(padding: EdgeInsets.symmetric(horizontal: many ? 1.5 : 4), child: Column(
            mainAxisAlignment: MainAxisAlignment.end, children: [
            Container(
              key: ValueKey('sales-bar-${d['day']}'),
              height: 4 + 110 * (_i(d['netCents']).clamp(0, max) / max),
              decoration: BoxDecoration(
                color: i == daily.length - 1 ? nc.heading : nc.heading.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(4))),
            const SizedBox(height: 6),
            SizedBox(height: 16, child: (!many || i % 7 == 0 || i == daily.length - 1)
                ? FittedBox(child: Text(WorkFormat.day('${d['day']}').split(' ').take(2).join(' '),
                    style: TextStyle(fontSize: 11, color: nc.muted)))
                : null),
          ]))),
        ),
    ]));
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    final nc = context.nohut;
    final totals = (d?['totals'] as Map?) ?? const {};
    final daily = [for (final r in (d?['daily'] as List? ?? const [])) r as Map];
    final top = [for (final r in (d?['topProducts'] as List? ?? const [])) r as Map];
    final online = (d?['online'] as Map?) ?? const {};
    final topMax = top.fold<int>(1, (m, p) => _i(p['grossCents']) > m ? _i(p['grossCents']) : m);
    return Scaffold(
      appBar: AppBar(title: const Text('Satış Analizi')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          SegmentedButton<String>(
            key: const ValueKey('sales-range'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'week', label: Text('Bu Hafta')),
              ButtonSegment(value: 'last4', label: Text('Son 4 Hafta')),
              ButtonSegment(value: 'month', label: Text('Bu Ay')),
            ],
            selected: {range},
            onSelectionChanged: (s) { setState(() => range = s.first); _load(); },
          ),
          const SizedBox(height: 14),
          if (loading && d == null)
            const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
          else if (error != null && d == null)
            Card(child: NohutEmpty(icon: Icons.bar_chart_outlined, message: error!,
              action: 'Tekrar dene', onAction: _load))
          else if (d != null) ...[
            Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(
              '${WorkFormat.day('${d['from']}')} – ${WorkFormat.day('${d['to']}')}',
              style: TextStyle(color: nc.muted, fontWeight: FontWeight.w600))),
            NohutMetric(key: const ValueKey('sales-net'), emphasis: true, icon: Icons.account_balance_wallet_outlined,
              label: 'Net tahsilat (Masa + Gel-Al)', value: money(_i(totals['netCents'])),
              caption: '${_i(totals['orderCount'])} sipariş'
                  '${totals['averageCents'] == null ? '' : ' · ortalama ${money(_i(totals['averageCents']))}'}'),
            const SizedBox(height: 10),
            NohutMetricGrid(minTileWidth: 140, children: [
              NohutMetric(label: 'Nakit', value: money(_i(totals['cashCents'])), icon: Icons.payments_outlined),
              NohutMetric(label: 'Kart', value: money(_i(totals['cardCents'])), icon: Icons.credit_card),
              NohutMetric(label: 'İade', value: money(_i(totals['refundCents'])), icon: Icons.undo),
              NohutMetric(label: 'Online', value: money(_i(online['grossCents'])), icon: Icons.delivery_dining_outlined,
                caption: '${_i(online['orders'])} teslim edilen'),
            ]),
            const SizedBox(height: 12),
            Card(child: Padding(padding: const EdgeInsets.fromLTRB(14, 14, 14, 12), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Günlük net tahsilat', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
              const SizedBox(height: 12),
              if (daily.isEmpty) Text('Gün yok.', style: TextStyle(color: nc.muted)) else _bars(context, daily),
            ]))),
            const SizedBox(height: 4),
            const NohutSection('En çok satanlar'),
            if (top.isEmpty)
              const Card(child: NohutEmpty(icon: Icons.restaurant_menu_outlined, message: 'Bu dönemde satış yok.'))
            else
              Card(child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Column(children: [
                for (final (i, p) in top.indexed)
                  Padding(key: ValueKey('top-product-$i'),
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 8), child: Column(children: [
                    Row(children: [
                      SizedBox(width: 22, child: Text('${i + 1}', style: TextStyle(color: nc.muted, fontWeight: FontWeight.w700))),
                      Expanded(child: Text('${p['name']}', overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700))),
                      Text('${_i(p['qty'])} adet', style: TextStyle(color: nc.muted, fontSize: 13)),
                      const SizedBox(width: 10),
                      Text(money(_i(p['grossCents'])), style: const TextStyle(fontWeight: FontWeight.w800)),
                    ]),
                    const SizedBox(height: 6),
                    Padding(padding: const EdgeInsets.only(left: 22), child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(value: _i(p['grossCents']) / topMax, minHeight: 5,
                        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest))),
                  ])),
              ]))),
            const SizedBox(height: 10),
            Text('${d['note'] ?? ''} Ürün tutarları satılan satırlardan; iptal edilen siparişler hariç.',
              style: TextStyle(fontSize: 12.5, color: nc.muted, height: 1.35)),
          ],
        ]),
      ),
    );
  }
}
