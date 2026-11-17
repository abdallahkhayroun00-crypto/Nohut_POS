import 'package:flutter/material.dart';
import 'operations.dart';
import 'order_reporting.dart';
import 'pos_logic.dart';

String elapsedService(Json o) {
  final start = DateTime.tryParse('${o['createdAt']}'),
      ready = DateTime.tryParse('${o['readyAt']}'),
      end = DateTime.tryParse('${o['deliveredAt']}');
  String span(DateTime? a, DateTime? b) => a == null || b == null
      ? '—'
      : '${b.difference(a).inMinutes.clamp(0, 99999)} dk';
  return 'Hazırlık: ${span(DateTime.tryParse('${o['serviceStartedAt']}') ?? start, ready ?? (o['serviceStatus'] == 'Hazırlanıyor' ? DateTime.now() : null))} · Teslim: ${span(ready, end ?? (o['serviceStatus'] == 'Hazır' ? DateTime.now() : null))} · Toplam: ${span(start, end ?? DateTime.now())}';
}

class StaffMetrics extends StatelessWidget {
  const StaffMetrics({super.key, required this.state, required this.day});
  final Json state;
  final String day;
  @override
  Widget build(BuildContext context) {
    final groups = <String, List<Json>>{};
    for (final o in asMaps(state['orders']).where(
      (o) =>
          !isPlatform(o) &&
          o['cancelled'] != true &&
          onIstanbulDay(o['createdAt'], day),
    )) {
      final first = asMaps(o['batches']).firstOrNull;
      final name = '${first?['staff'] ?? 'Kasa (PC)'}';
      groups.putIfAbsent(name, () => []).add(o);
    }
    final additions = <String, int>{};
    for (final order in asMaps(state['orders'])) {
      if (isPlatform(order) || order['cancelled'] == true) continue;
      for (final batch in asMaps(order['batches']).skip(1)) {
        if (!onIstanbulDay(batch['createdAt'], day) ||
            !asMaps(batch['lines']).any(
              (line) => line['correction'] != true && line['voided'] != true,
            )) {
          continue;
        }
        final name = '${batch['staff'] ?? 'Kasa (PC)'}';
        additions.update(name, (count) => count + 1, ifAbsent: () => 1);
        groups.putIfAbsent(name, () => []);
      }
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Personel · Bugünün siparişleri',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const Text(
              'Sipariş ilk alan personele sayılır; ek siparişler tekrar sayılmaz. Tutar satış değeridir.',
            ),
            if (groups.isEmpty) const Text('Henüz sipariş yok.'),
            for (final e in groups.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  '${e.key} · ${e.value.length} sipariş · Ek ${additions[e.key] ?? 0} · Masa ${e.value.where((o) => o['source'] == 'Masa').length} · Paket / Gel-Al ${e.value.where((o) => o['source'] == 'Gel-Al').length} · ${formatTry(e.value.fold<int>(0, (n, o) => n + orderTotalCents(o)))}',
                ),
              ),
          ],
        ),
      ),
    );
  }
}
