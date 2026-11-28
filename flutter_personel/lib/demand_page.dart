// Yoğunluk (Yönetici): weekday × hour order counts from Windows
// `ownerDemand`, the same numbers as Windows Raporlar › Yoğunluk.
import 'package:flutter/material.dart';

import 'pos_api.dart';
import 'style.dart';
import 'work_page.dart' show WorkFormat;

const _days = ['Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt', 'Paz'];
const _dayNames = ['Pazartesi', 'Salı', 'Çarşamba', 'Perşembe', 'Cuma', 'Cumartesi', 'Pazar'];

class DemandPage extends StatefulWidget {
  const DemandPage({super.key, required this.request, this.initialRange = 'last4'});
  final Future<Json> Function(Json payload) request;
  final String initialRange;
  @override
  State<DemandPage> createState() => _DemandPageState();
}

class _DemandPageState extends State<DemandPage> {
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
      final r = await widget.request({'operation': 'ownerDemand', 'range': asked});
      if (!mounted || asked != range) return;
      setState(() {
        if (r['demand'] is Map) {
          data = Map<String, dynamic>.from(r['demand'] as Map);
        } else {
          error = '${r['message'] ?? 'Yoğunluk bilgisi alınamadı.'}';
        }
      });
    } on Object catch (e) {
      if (mounted) setState(() => error = e is FormatException ? e.message : 'Windows’a ulaşılamadı.');
    } finally {
      if (mounted && asked == range) setState(() => loading = false);
    }
  }

  static int _i(Object? v) => v is num ? v.toInt() : 0;

  /// Hours that ever have orders in the period, padded to a tidy span.
  static (int, int) _span(List<List<int>> heat) {
    var first = 24, last = -1;
    for (final row in heat) {
      for (var h = 0; h < 24; h++) {
        if (row[h] > 0) {
          if (h < first) first = h;
          if (h > last) last = h;
        }
      }
    }
    if (last < 0) return (10, 22);
    return (first, last);
  }

  Widget _heatmap(BuildContext context, List<List<int>> heat) {
    final nc = context.nohut;
    final scheme = Theme.of(context).colorScheme;
    final max = heat.expand((r) => r).fold<int>(1, (m, v) => v > m ? v : m);
    final (from, to) = _span(heat);
    final hours = [for (var h = from; h <= to; h++) h];
    Color cell(int v) => v == 0 ? scheme.surfaceContainerHighest.withValues(alpha: 0.55)
        : Color.lerp(nc.heading.withValues(alpha: 0.18), nc.heading, v / max)!;
    return LayoutBuilder(builder: (context, box) {
      const label = 34.0, gap = 3.0;
      final size = ((box.maxWidth - label) / hours.length - gap).clamp(10.0, 28.0);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final (d, row) in heat.indexed)
          Padding(padding: const EdgeInsets.only(bottom: gap), child: Row(children: [
            SizedBox(width: label, child: Text(_days[d],
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: nc.muted))),
            for (final h in hours)
              Padding(padding: const EdgeInsets.only(right: gap), child: Tooltip(
                message: '${_dayNames[d]} ${h.toString().padLeft(2, '0')}:00 · ${row[h]} sipariş',
                child: Container(width: size, height: size,
                  key: ValueKey('heat-$d-$h'),
                  decoration: BoxDecoration(color: cell(row[h]), borderRadius: BorderRadius.circular(4))))),
          ])),
        const SizedBox(height: 4),
        Row(children: [
          const SizedBox(width: label),
          for (final h in hours)
            SizedBox(width: size + gap, child: h % 3 == 0
                ? Text('$h', style: TextStyle(fontSize: 10.5, color: nc.muted)) : null),
        ]),
      ]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    final nc = context.nohut;
    final heat = [for (final row in (d?['heatmap'] as List? ?? const [])) [for (final v in row as List) _i(v)]];
    final peak = d?['peak'] as Map?;
    final busiest = d?['busiestWeekday'];
    return Scaffold(
      appBar: AppBar(title: const Text('Yoğunluk')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          SegmentedButton<String>(
            key: const ValueKey('demand-range'),
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
            Card(child: NohutEmpty(icon: Icons.grid_on_outlined, message: error!,
              action: 'Tekrar dene', onAction: _load))
          else if (d != null) ...[
            Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(
              '${WorkFormat.day('${d['from']}')} – ${WorkFormat.day('${d['to']}')}',
              style: TextStyle(color: nc.muted, fontWeight: FontWeight.w600))),
            NohutMetric(key: const ValueKey('demand-orders'), emphasis: true, icon: Icons.receipt_long_outlined,
              label: 'Bu dönemdeki siparişler', value: '${_i(d['orders'])}'),
            const SizedBox(height: 10),
            NohutMetricGrid(minTileWidth: 140, children: [
              NohutMetric(icon: Icons.local_fire_department_outlined, label: 'En yoğun saat',
                value: peak == null ? '—' : '${_days[_i(peak['weekday'])]} ${_i(peak['hour']).toString().padLeft(2, '0')}:00',
                caption: peak == null ? 'Bu dönemde sipariş yok' : '${_i(peak['orders'])} sipariş'),
              NohutMetric(icon: Icons.calendar_view_week_outlined, label: 'En yoğun gün',
                value: busiest is num ? _dayNames[busiest.toInt()] : '—'),
            ]),
            const SizedBox(height: 12),
            Card(child: Padding(padding: const EdgeInsets.fromLTRB(14, 14, 14, 12), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Gün ve saate göre', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
              const SizedBox(height: 10),
              if (_i(d['orders']) == 0)
                Text('Bu dönemde sipariş yok.', style: TextStyle(color: nc.muted))
              else
                _heatmap(context, heat),
            ]))),
            const SizedBox(height: 10),
            Text('${d['note'] ?? ''} Koyu kare daha çok sipariş demektir; dokunup basılı tutunca sayı görünür.',
              style: TextStyle(fontSize: 12.5, color: nc.muted, height: 1.35)),
          ],
        ]),
      ),
    );
  }
}
