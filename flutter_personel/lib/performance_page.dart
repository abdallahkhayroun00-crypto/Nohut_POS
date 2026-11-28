// Performansım (spec §24.3): the signed-in person's own orders, sales and
// hours for today, this week or this month, read from Windows
// `/api/work/performance`. The server decides whose numbers they are.
import 'package:flutter/material.dart';

import 'pos_api.dart';
import 'style.dart';
import 'work_page.dart' show WorkFormat;

class PerformancePage extends StatefulWidget {
  const PerformancePage({super.key, required this.api, this.initialRange = 'day'});
  final NohutApi api;
  final String initialRange;
  @override
  State<PerformancePage> createState() => _PerformancePageState();
}

class _PerformancePageState extends State<PerformancePage> {
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
    setState(() { loading = true; error = null; });
    try {
      final (status, body) = await widget.api.work('GET', 'performance', query: {'range': range});
      if (!mounted) return;
      setState(() {
        if (status == 200 && body['performance'] is Map) {
          data = Map<String, dynamic>.from(body['performance'] as Map);
        } else {
          error = '${body['message'] ?? 'Performans bilgisi alınamadı.'}';
        }
      });
    } on Object catch (e) {
      if (mounted) setState(() => error = e is FormatException ? e.message : 'Windows’a ulaşılamadı.');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  static int _i(Object? v) => v is num ? v.toInt() : 0;

  @override
  Widget build(BuildContext context) {
    final d = data;
    final nc = context.nohut;
    return Scaffold(
      appBar: AppBar(title: const Text('Performansım')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          SegmentedButton<String>(
            key: const ValueKey('performance-range'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'day', label: Text('Bugün')),
              ButtonSegment(value: 'week', label: Text('Bu Hafta')),
              ButtonSegment(value: 'month', label: Text('Bu Ay')),
            ],
            selected: {range},
            onSelectionChanged: (s) { setState(() => range = s.first); _load(); },
          ),
          const SizedBox(height: 14),
          if (loading && d == null)
            const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
          else if (error != null && d == null)
            Card(child: NohutEmpty(icon: Icons.insights_outlined, message: error!,
              action: 'Tekrar dene', onAction: _load))
          else if (d != null) ...[
            if (d['from'] != null)
              Padding(padding: const EdgeInsets.only(bottom: 10),
                child: Text(d['from'] == d['to'] ? WorkFormat.day('${d['from']}')
                    : '${WorkFormat.day('${d['from']}')} – ${WorkFormat.day('${d['to']}')}',
                  style: TextStyle(color: nc.muted, fontWeight: FontWeight.w600))),
            NohutMetric(
              key: const ValueKey('performance-sales'),
              emphasis: true,
              icon: Icons.point_of_sale_outlined,
              label: 'Aldığım siparişlerin tutarı',
              value: money(_i(d['salesCents'])),
              caption: _i(d['orders']) == 0 ? 'Bu dönemde sipariş yok'
                  : 'Ortalama ${money(_i(d['averageCents']))} · ${_i(d['orders'])} sipariş'),
            const SizedBox(height: 10),
            NohutMetricGrid(minTileWidth: 150, children: [
              NohutMetric(label: 'Masa siparişi', value: '${_i(d['tables'])}', icon: Icons.table_restaurant_outlined),
              NohutMetric(label: 'Gel-Al', value: '${_i(d['pickups'])}', icon: Icons.takeout_dining_outlined),
              NohutMetric(label: 'Ek sipariş', value: '${_i(d['additions'])}', icon: Icons.add_circle_outline,
                caption: 'Başkasının masasına eklenenler dahil'),
              NohutMetric(label: 'Çalışılan süre', value: WorkFormat.hours(_i(d['workedMinutes'])),
                icon: Icons.timer_outlined, caption: 'Mesai kayıtlarınızdan'),
              NohutMetric(label: 'Açık sipariş', value: '${_i(d['openOrders'])}', icon: Icons.receipt_long_outlined),
              NohutMetric(label: 'İptal edilen', value: '${_i(d['cancelled'])}', icon: Icons.block),
            ]),
            const SizedBox(height: 12),
            Text('${d['note'] ?? ''} Online platform siparişleri bu sayılara dahil değildir.',
              style: TextStyle(fontSize: 12.5, color: nc.muted, height: 1.35)),
          ],
        ]),
      ),
    );
  }
}
