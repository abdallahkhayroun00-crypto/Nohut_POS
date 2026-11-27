/// Windows › Ayarlar › Bildirimler › Gün Sonu Raporu (spec §24.7): when the
/// daily "Gün Sonu Raporunuz Hazır" notification is created. It never closes
/// the register, orders or the day.
library;

import 'package:flutter/material.dart';

import 'daily_report.dart';
import 'pos_logic.dart';

const _weekdayNames = ['Pazartesi', 'Salı', 'Çarşamba', 'Perşembe', 'Cuma', 'Cumartesi', 'Pazar'];

class DailyReportSettings extends StatelessWidget {
  const DailyReportSettings({super.key, required this.state, required this.edit});
  final Json state;
  final bool Function(void Function(Json)) edit;

  void _save(DailyReportSchedule next) => edit((s) => saveDailyReportSchedule(s, next));

  static String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<String?> _pickTime(BuildContext context, String current) async {
    final t = await showTimePicker(context: context,
        initialTime: TimeOfDay(hour: int.parse(current.substring(0, 2)), minute: int.parse(current.substring(3))),
        helpText: 'Kapanış saati');
    return t == null ? null : _fmt(t);
  }

  /// Returns 'HH:MM', 'closed', '' (= use default) or null (cancelled).
  Future<String?> _dayChoice(BuildContext context, String title, String? current, String fallback) async {
    final choice = await showDialog<String>(context: context, builder: (ctx) => SimpleDialog(
      title: Text(title),
      children: [
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, ''), child: Text('Varsayılan ($fallback)')),
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'time'), child: const Text('Farklı saat seç…')),
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'closed'), child: const Text('Kapalı (rapor bildirimi yok)')),
      ],
    ));
    if (choice != 'time' || !context.mounted) return choice;
    return _pickTime(context, current != null && current != 'closed' ? current : fallback);
  }

  @override
  Widget build(BuildContext context) {
    final s = DailyReportSchedule.of(state);
    DailyReportSchedule copy({bool? enabled, String? time, Map<String, String>? weekdays, Map<String, String>? dates}) =>
        DailyReportSchedule(enabled: enabled ?? s.enabled, time: time ?? s.time,
            weekdays: weekdays ?? s.weekdays, dates: dates ?? s.dates);
    String label(String? v) => v == null ? s.time : v == 'closed' ? 'Kapalı' : v;
    final dates = s.dates.keys.toList()..sort();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SwitchListTile.adaptive(
        key: const ValueKey('daily-report-enabled'),
        title: const Text('Gün sonu raporu bildirimi'),
        subtitle: const Text('Kapanış saatinde yetkili yöneticilere tek bildirim: '
            '“Gün Sonu Raporunuz Hazır”. Kilit ekranında tutar veya isim gösterilmez. '
            'Kasa, sipariş veya gün otomatik kapatılmaz.'),
        value: s.enabled,
        onChanged: (v) => _save(copy(enabled: v)),
      ),
      ListTile(
        key: const ValueKey('daily-report-time'),
        leading: const Icon(Icons.schedule_outlined),
        title: const Text('Varsayılan kapanış saati'),
        trailing: Text(s.time, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
        enabled: s.enabled,
        onTap: () async {
          final t = await _pickTime(context, s.time);
          if (t != null) _save(copy(time: t));
        },
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Wrap(spacing: 6, runSpacing: 6, children: [
          for (var d = 1; d <= 7; d++)
            ActionChip(
              key: ValueKey('daily-report-weekday-$d'),
              label: Text('${_weekdayNames[d - 1]} · ${label(s.weekdays['$d'])}'),
              onPressed: !s.enabled ? null : () async {
                final v = await _dayChoice(context, _weekdayNames[d - 1], s.weekdays['$d'], s.time);
                if (v == null) return;
                final next = Map<String, String>.of(s.weekdays);
                v.isEmpty ? next.remove('$d') : next['$d'] = v;
                _save(copy(weekdays: next));
              },
            ),
        ]),
      ),
      ListTile(
        leading: const Icon(Icons.event_outlined),
        title: const Text('Özel gün / tatil'),
        subtitle: Text(dates.isEmpty ? 'Tanımlı özel gün yok.' :
            dates.map((d) => '$d · ${label(s.dates[d])}').join('\n')),
        isThreeLine: dates.length > 1,
        trailing: Wrap(spacing: 4, children: [
          if (dates.isNotEmpty)
            IconButton(tooltip: 'Özel günü kaldır', icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final pick = await showDialog<String>(context: context, builder: (ctx) => SimpleDialog(
                  title: const Text('Kaldırılacak gün'),
                  children: [for (final d in dates)
                    SimpleDialogOption(onPressed: () => Navigator.pop(ctx, d), child: Text(d))],
                ));
                if (pick == null) return;
                _save(copy(dates: Map.of(s.dates)..remove(pick)));
              }),
          IconButton(tooltip: 'Özel gün ekle', icon: const Icon(Icons.add),
            onPressed: !s.enabled ? null : () async {
              final now = DateTime.now();
              final day = await showDatePicker(context: context, initialDate: now,
                  firstDate: now.subtract(const Duration(days: 1)), lastDate: now.add(const Duration(days: 400)),
                  helpText: 'Özel gün');
              if (day == null || !context.mounted) return;
              final key = day.toIso8601String().substring(0, 10);
              final v = await _dayChoice(context, key, s.dates[key], s.time);
              if (v == null) return;
              final next = Map<String, String>.of(s.dates);
              v.isEmpty ? next.remove(key) : next[key] = v;
              _save(copy(dates: next));
            }),
        ]),
      ),
    ]);
  }
}
