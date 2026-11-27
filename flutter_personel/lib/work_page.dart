/// Native Mesai / Vardiya / Maaş screens for the signed-in employee
/// (spec §24.4–24.6). Same server rules as the browser Personel app:
/// manual entry only, no approval, the weekly submission never blocks a
/// correction, and the server alone decides whose week this is.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pos_api.dart';
import 'style.dart';

/// Pure formatting helpers (unit-tested).
class WorkFormat {
  static const _days = ['Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt', 'Paz'];
  static const _months = ['Oca', 'Şub', 'Mar', 'Nis', 'May', 'Haz', 'Tem', 'Ağu', 'Eyl', 'Eki', 'Kas', 'Ara'];

  static DateTime parse(String day) => DateTime.utc(
      int.parse(day.substring(0, 4)), int.parse(day.substring(5, 7)), int.parse(day.substring(8, 10)));
  static String iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  static String addDays(String day, int n) => iso(parse(day).add(Duration(days: n)));
  static String day(String day) {
    final d = parse(day);
    return '${_days[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';
  }
  static String hours(Object? minutes) {
    final m = minutes is int ? minutes : 0;
    return '${m ~/ 60} sa${m % 60 == 0 ? '' : ' ${m % 60} dk'}';
  }
  static String hm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  static TimeOfDay? parseHm(Object? v) {
    final m = RegExp(r'^(\d{2}):(\d{2})$').firstMatch('${v ?? ''}');
    return m == null ? null : TimeOfDay(hour: int.parse(m.group(1)!), minute: int.parse(m.group(2)!));
  }
}

/// Request ids: one per distinct write. A retry of the same payload after a
/// lost connection reuses its id, so the server applies it only once.
class WorkRequestIds {
  final _ids = <String, String>{};
  final _random = Random.secure();
  String forPayload(Json payload) => _ids.putIfAbsent(jsonEncode(payload), () =>
      'apk${List.generate(24, (_) => _random.nextInt(16).toRadixString(16)).join()}');
  void done(Json payload) => _ids.remove(jsonEncode(payload));
}

class WorkPage extends StatefulWidget {
  const WorkPage({super.key, required this.api, this.initialTab = 0});
  final NohutApi api;
  final int initialTab;

  @override
  State<WorkPage> createState() => _WorkPageState();
}

class _WorkPageState extends State<WorkPage> {
  final ids = WorkRequestIds();
  String? weekStart;
  Json? data;
  List<Json> shared = const [];
  String? error;
  bool loading = false;

  Json get week => Map<String, dynamic>.from(data!['week'] as Map);
  String get today => '${data!['today']}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { loading = true; error = null; });
    try {
      final q = weekStart == null ? null : {'weekStart': weekStart!};
      final (st, b) = await widget.api.work('GET', 'week', query: q);
      if (st != 200) throw FormatException('${b['message'] ?? 'Mesai yüklenemedi.'}');
      final (st2, b2) = await widget.api.work('GET', 'schedule', query: {'weekStart': '${(b['week'] as Map)['weekStart']}'});
      if (!mounted) return;
      setState(() {
        data = b;
        weekStart = '${(b['week'] as Map)['weekStart']}';
        shared = st2 == 200 ? rows(b2['plans']) : const [];
      });
    } on FormatException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = 'Laptop bağlantısı kurulamadı. Restoran Wi-Fi ağında olduğunuzu kontrol edin.');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _toast(String text) => ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));

  /// Sends one write. Returns null on success, otherwise the message to show.
  Future<String?> _write(Json body) async {
    try {
      final rid = ids.forPayload(body);
      final (st, b) = await widget.api.work('POST', 'write', body: {'requestId': rid, ...body});
      if (st == 200) {
        ids.done(body);
        HapticFeedback.lightImpact();
        await _load();
        return null;
      }
      if (st == 409 && b['error'] == 'overlap' && mounted) {
        final go = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
          title: const Text('Çakışan kayıt'),
          content: Text('${b['message']}\n\nYine de kaydedilsin mi?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Vazgeç')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Kaydet')),
          ],
        ));
        return go == true ? await _write({...body, 'confirmOverlap': true}) : 'Kaydedilmedi.';
      }
      HapticFeedback.heavyImpact();
      if (st == 409) {
        ids.done(body);
        await _load();
      }
      return '${b['message'] ?? 'Kaydedilemedi.'}';
    } on FormatException catch (e) {
      return e.message;
    } catch (_) {
      // Unknown outcome: keep the request id, so pressing again is safe.
      return 'Bağlantı kesildi. Aynı bilgilerle tekrar deneyin; kayıt iki kez oluşmaz.';
    }
  }

  void _shiftWeek(int days) {
    if (weekStart == null) return;
    setState(() => weekStart = WorkFormat.addDays(weekStart!, days));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      initialIndex: widget.initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Mesai ve Maaşım', style: TextStyle(fontFamily: 'Bree')),
          actions: [
            IconButton(tooltip: 'Yenile', onPressed: loading ? null : _load, icon: const Icon(Icons.sync)),
          ],
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.schedule_outlined), text: 'Mesai'),
            Tab(icon: Icon(Icons.calendar_month_outlined), text: 'Vardiya'),
            Tab(icon: Icon(Icons.payments_outlined), text: 'Maaş'),
          ]),
        ),
        body: data == null
            ? Center(child: loading
                ? const CircularProgressIndicator()
                : _ErrorState(message: error ?? 'Yüklenemedi.', onRetry: _load))
            : Column(children: [
                _WeekHeader(weekStart: weekStart!, loading: loading,
                    onPrev: () => _shiftWeek(-7), onNext: () => _shiftWeek(7)),
                if (error != null)
                  MaterialBanner(
                    backgroundColor: const Color(0xffffe9c8),
                    content: Text(error!),
                    actions: [TextButton(onPressed: _load, child: const Text('Tekrar dene'))]),
                Expanded(child: TabBarView(children: [
                  _MesaiTab(state: this),
                  _VardiyaTab(state: this),
                  _MaasTab(state: this),
                ])),
              ]),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.cloud_off_outlined, size: 40, color: NohutStyle.muted),
      const SizedBox(height: 12),
      Text(message, textAlign: TextAlign.center),
      const SizedBox(height: 12),
      FilledButton.tonal(onPressed: onRetry, child: const Text('Tekrar dene')),
    ]),
  );
}

class _WeekHeader extends StatelessWidget {
  const _WeekHeader({required this.weekStart, required this.loading, required this.onPrev, required this.onNext});
  final String weekStart;
  final bool loading;
  final VoidCallback onPrev, onNext;
  @override
  Widget build(BuildContext context) => Material(
    color: NohutStyle.card,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(children: [
        IconButton(tooltip: 'Önceki hafta', onPressed: loading ? null : onPrev, icon: const Icon(Icons.chevron_left)),
        Expanded(child: Text('${WorkFormat.day(weekStart)} – ${WorkFormat.day(WorkFormat.addDays(weekStart, 6))}',
            textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600, color: NohutStyle.green))),
        IconButton(tooltip: 'Sonraki hafta', onPressed: loading ? null : onNext, icon: const Icon(Icons.chevron_right)),
      ]),
    ),
  );
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(color: NohutStyle.card, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NohutStyle.outline)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: const TextStyle(fontSize: 12, color: NohutStyle.muted)),
      const SizedBox(height: 2),
      Text(value, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: NohutStyle.green)),
    ]),
  );
}

class _StatusChip extends StatelessWidget {
  const _StatusChip(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (text) {
      'Gönderildi' || 'Ödendi' => (const Color(0xffdcefe2), NohutStyle.green),
      'Değişti' || 'Kısmen Ödendi' => (const Color(0xfffff0cf), const Color(0xff7a5200)),
      'Ödenmedi' => (const Color(0xfffde2dc), const Color(0xff8a2414)),
      _ => (const Color(0xffeceee6), NohutStyle.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 13)),
    );
  }
}

// ------------------------------------------------------------------ Mesai

class _MesaiTab extends StatelessWidget {
  const _MesaiTab({required this.state});
  final _WorkPageState state;

  @override
  Widget build(BuildContext context) {
    final w = state.week, st = Map<String, dynamic>.from(w['status'] as Map);
    final work = rows(w['work']);
    final status = '${st['status']}';
    final sendable = status != 'Gönderildi' && status != 'Çalışma yok';
    final hasWork = work.any((x) => x['voided'] != true);
    final days = [for (var i = 0; i < 7; i++) WorkFormat.addDays('${w['weekStart']}', i)];
    return RefreshIndicator(
      onRefresh: state._load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 96), children: [
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          _StatusChip(status),
          if (st['submittedAt'] != null)
            Text('gönderim: ${_stamp('${st['submittedAt']}')}',
                style: const TextStyle(color: NohutStyle.muted, fontSize: 13)),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _Stat('Gerçek çalışma', WorkFormat.hours(st['minutes'])),
          _Stat('Çalışılan gün', '${st['daysWorked'] ?? 0}'),
          _Stat('Planlanan', WorkFormat.hours(w['plannedMinutes'])),
        ]),
        const SizedBox(height: 16),
        for (final d in days) ...[
          for (final x in work.where((x) => x['date'] == d)) _WorkTile(state: state, x: x),
          if (!work.any((x) => x['date'] == d))
            ListTile(dense: true, contentPadding: EdgeInsets.zero,
              title: Text(WorkFormat.day(d)),
              trailing: Text(d.compareTo(state.today) > 0 ? '' : 'Kayıt yok',
                  style: const TextStyle(color: NohutStyle.muted))),
        ],
        const SizedBox(height: 12),
        if (sendable && hasWork)
          FilledButton.icon(
            icon: const Icon(Icons.send_outlined),
            label: Text(status == 'Değişti' ? 'Değişiklikleri Gönder' : 'Haftalık Mesailerimi Gönder'),
            onPressed: () => _submit(context, noWork: false)),
        if (sendable && !hasWork)
          OutlinedButton(onPressed: () => _submit(context, noWork: true), child: const Text('Bu hafta çalışmadım')),
        const SizedBox(height: 8),
        const Text('Gönderim bilgilendirmedir, onay beklemez. Gönderdikten sonra da düzeltme yapabilirsiniz.',
            style: TextStyle(color: NohutStyle.muted, fontSize: 12)),
      ]),
    );
  }

  static String _stamp(String iso) {
    final t = DateTime.tryParse(iso)?.toUtc().add(const Duration(hours: 3));
    if (t == null) return '';
    return '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _submit(BuildContext context, {required bool noWork}) async {
    final go = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
      title: Text(noWork ? 'Çalışmadığınızı bildirin' : 'Haftalık mesai'),
      content: Text(noWork ? 'Bu hafta çalışmadığınız yöneticinize bildirilsin mi?'
          : 'Bu haftanın mesaileri yöneticinize gönderilsin mi?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Vazgeç')),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Gönder')),
      ],
    ));
    if (go != true) return;
    final err = await state._write({'action': 'week_submit', 'weekStart': state.weekStart, if (noWork) 'noWork': true});
    state._toast(err ?? (noWork ? '✓ Bildirildi.' : '✓ Haftalık mesai gönderildi.'));
  }
}

class _WorkTile extends StatelessWidget {
  const _WorkTile({required this.state, required this.x});
  final _WorkPageState state;
  final Json x;
  @override
  Widget build(BuildContext context) {
    final voided = x['voided'] == true;
    final details = [
      if ((x['breakMinutes'] ?? 0) != 0) 'Mola ${x['breakMinutes']} dk',
      WorkFormat.hours(x['minutes']),
      if ('${x['note'] ?? ''}'.isNotEmpty) '${x['note']}',
      if (voided) 'iptal: ${x['voidReason']}',
      if (rows(x['corrections']).isNotEmpty) '${rows(x['corrections']).length} değişiklik',
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text('${WorkFormat.day('${x['date']}')} · ${x['from']}–${x['to'] ?? '…'}',
          style: TextStyle(decoration: voided ? TextDecoration.lineThrough : null, fontWeight: FontWeight.w600)),
        subtitle: Text(details),
        trailing: x['editable'] == true ? PopupMenuButton<String>(
          tooltip: 'İşlemler',
          onSelected: (v) => v == 'edit' ? WorkForm.open(context, state, existing: x) : _void(context),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('Düzenle')),
            PopupMenuItem(value: 'void', child: Text('İptal et')),
          ]) : null,
        onTap: x['editable'] == true ? () => WorkForm.open(context, state, existing: x) : null,
      ),
    );
  }

  Future<void> _void(BuildContext context) async {
    final reason = TextEditingController();
    final go = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
      title: const Text('Mesai kaydını iptal et'),
      content: TextField(controller: reason, autofocus: true, maxLength: 200,
          decoration: const InputDecoration(labelText: 'İptal nedeni')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Vazgeç')),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('İptal et')),
      ],
    ));
    final why = reason.text.trim();
    reason.dispose();
    if (go != true) return;
    if (why.isEmpty) return state._toast('İptal nedeni gerekli.');
    final err = await state._write({'action': 'work_void', 'id': x['id'], 'expectedUpdatedAt': x['updatedAt'], 'reason': why});
    state._toast(err ?? '✓ Kayıt iptal edildi.');
  }
}

/// Add or edit one actual-hours record (past or today only).
class WorkForm {
  static Future<void> open(BuildContext context, _WorkPageState state, {Json? existing}) async {
    final today = state.today, ws = state.weekStart!;
    final lastDay = WorkFormat.addDays(ws, 6);
    var date = '${existing?['date'] ?? (today.compareTo(lastDay) > 0 ? lastDay : today.compareTo(ws) < 0 ? ws : today)}';
    var start = WorkFormat.parseHm(existing?['from']);
    var end = WorkFormat.parseHm(existing?['to']);
    final brk = TextEditingController(text: '${existing?['breakMinutes'] ?? 0}');
    final note = TextEditingController(text: '${existing?['note'] ?? ''}');
    String? error;
    var busy = false;
    await showModalBottomSheet<void>(
      context: context, isScrollControlled: true, showDragHandle: true,
      builder: (sheet) => StatefulBuilder(builder: (sheet, set) {
        Future<void> pickTime(bool isStart) async {
          final t = await showTimePicker(context: sheet, initialTime: (isStart ? start : end) ?? const TimeOfDay(hour: 10, minute: 0),
              builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true), child: child!));
          if (t != null) set(() => isStart ? start = t : end = t);
        }
        return Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(sheet).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(existing == null ? 'Mesai Ekle' : 'Mesaiyi Düzenle', style: Theme.of(sheet).textTheme.headlineSmall),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.event_outlined), label: Text(WorkFormat.day(date)),
              onPressed: () async {
                final d = await showDatePicker(context: sheet, initialDate: WorkFormat.parse(date),
                    firstDate: WorkFormat.parse(today).subtract(const Duration(days: 62)), lastDate: WorkFormat.parse(today));
                if (d != null) set(() => date = WorkFormat.iso(d));
              }),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: () => pickTime(true),
                  child: Text(start == null ? 'Başlangıç' : 'Başlangıç ${WorkFormat.hm(start!)}'))),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton(onPressed: () => pickTime(false),
                  child: Text(end == null ? 'Bitiş' : 'Bitiş ${WorkFormat.hm(end!)}'))),
            ]),
            const SizedBox(height: 12),
            TextField(controller: brk, keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
                decoration: const InputDecoration(labelText: 'Mola (dakika)')),
            const SizedBox(height: 12),
            TextField(controller: note, maxLength: 200, decoration: const InputDecoration(labelText: 'Not (isteğe bağlı)')),
            if (error != null) Text(error!, style: TextStyle(color: Theme.of(sheet).colorScheme.error)),
            const SizedBox(height: 8),
            FilledButton(onPressed: busy ? null : () async {
              if (start == null || end == null) return set(() => error = 'Başlangıç ve bitiş saatini seçin.');
              set(() { busy = true; error = null; });
              final err = await state._write({
                'action': 'work_save',
                if (existing != null) ...{'id': existing['id'], 'expectedUpdatedAt': existing['updatedAt']},
                'date': date, 'start': WorkFormat.hm(start!), 'end': WorkFormat.hm(end!),
                'breakMinutes': int.tryParse(brk.text) ?? 0, 'note': note.text.trim(),
              });
              if (err == null) {
                if (sheet.mounted) Navigator.pop(sheet);
                state._toast('✓ Mesai kaydedildi.');
              } else {
                set(() { busy = false; error = err; });
              }
            }, child: busy ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Kaydet')),
          ]),
        );
      }),
    );
    brk.dispose();
    note.dispose();
  }
}

// ---------------------------------------------------------------- Vardiya

class _VardiyaTab extends StatelessWidget {
  const _VardiyaTab({required this.state});
  final _WorkPageState state;
  @override
  Widget build(BuildContext context) {
    final w = state.week, ws = '${w['weekStart']}';
    final plans = rows(w['plans']);
    final days = [for (var i = 0; i < 7; i++) WorkFormat.addDays(ws, i)];
    final canPlan = WorkFormat.addDays(ws, 6).compareTo(state.today) >= 0;
    String label(Json p) => p['dayOff'] == true ? 'İzinli'
        : '${p['start']}–${p['end']}${p['endsNextDay'] == true ? ' (+1)' : ''}';
    return RefreshIndicator(
      onRefresh: state._load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 96), children: [
        Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, children: [
          const Text('Vardiyalarım', style: TextStyle(fontFamily: 'Bree', fontSize: 20, color: NohutStyle.green)),
          if (canPlan) TextButton.icon(icon: const Icon(Icons.copy_all_outlined), label: const Text('Geçen haftayı kopyala'),
              onPressed: () => _copy(context)),
        ]),
        if (plans.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Bu hafta vardiya planınız yok.', style: TextStyle(color: NohutStyle.muted))),
        for (final p in plans)
          Card(margin: const EdgeInsets.only(bottom: 8), child: ListTile(
            title: Text('${WorkFormat.day('${p['date']}')} · ${label(p)}', style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: '${p['note'] ?? ''}'.isEmpty ? null : Text('${p['note']}'),
            trailing: '${p['date']}'.compareTo(state.today) >= 0 ? PopupMenuButton<String>(
              tooltip: 'İşlemler',
              onSelected: (v) => v == 'edit' ? PlanForm.open(context, state, existing: p) : _cancel(context, p),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Düzenle')),
                PopupMenuItem(value: 'cancel', child: Text('Sil')),
              ]) : null,
          )),
        const SizedBox(height: 16),
        const Text('Ekip programı', style: TextStyle(fontFamily: 'Bree', fontSize: 20, color: NohutStyle.green)),
        const SizedBox(height: 4),
        if (state.shared.isEmpty) const Text('Bu hafta plan yok.', style: TextStyle(color: NohutStyle.muted)),
        for (final d in days)
          if (state.shared.any((p) => p['date'] == d))
            ListTile(contentPadding: EdgeInsets.zero, dense: true,
              title: Text(WorkFormat.day(d), style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text([for (final p in state.shared.where((p) => p['date'] == d))
                '${p['employeeName']} ${p['dayOff'] == true ? 'izinli' : '${p['start']}–${p['end']}'}'].join('\n'))),
      ]),
    );
  }

  Future<void> _copy(BuildContext context) async {
    final err = await state._write({'action': 'plan_copy_week',
      'fromWeekStart': WorkFormat.addDays(state.weekStart!, -7), 'toWeekStart': state.weekStart});
    state._toast(err ?? '✓ Geçen haftanın vardiyaları kopyalandı.');
  }

  Future<void> _cancel(BuildContext context, Json p) async {
    final go = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
      title: const Text('Vardiyayı sil'),
      content: Text('${WorkFormat.day('${p['date']}')} vardiyası silinsin mi?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Vazgeç')),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Sil')),
      ],
    ));
    if (go != true) return;
    final err = await state._write({'action': 'plan_cancel', 'id': p['id'], 'expectedUpdatedAt': p['updatedAt']});
    state._toast(err ?? '✓ Vardiya silindi.');
  }
}

class PlanForm {
  static Future<void> open(BuildContext context, _WorkPageState state, {Json? existing}) async {
    final today = state.today, ws = state.weekStart!;
    var date = '${existing?['date'] ?? (today.compareTo(ws) > 0 ? today : ws)}';
    var start = WorkFormat.parseHm(existing?['start']);
    var end = WorkFormat.parseHm(existing?['end']);
    var dayOff = existing?['dayOff'] == true;
    var repeat = 0;
    final brk = TextEditingController(text: '${existing?['breakMinutes'] ?? 0}');
    final note = TextEditingController(text: '${existing?['note'] ?? ''}');
    String? error;
    var busy = false;
    await showModalBottomSheet<void>(
      context: context, isScrollControlled: true, showDragHandle: true,
      builder: (sheet) => StatefulBuilder(builder: (sheet, set) {
        Future<void> pickTime(bool isStart) async {
          final t = await showTimePicker(context: sheet, initialTime: (isStart ? start : end) ?? const TimeOfDay(hour: 10, minute: 0),
              builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true), child: child!));
          if (t != null) set(() => isStart ? start = t : end = t);
        }
        return Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(sheet).bottom),
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(existing == null ? 'Vardiya Ekle' : 'Vardiyayı Düzenle', style: Theme.of(sheet).textTheme.headlineSmall),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.event_outlined), label: Text(WorkFormat.day(date)),
              onPressed: () async {
                final d = await showDatePicker(context: sheet, initialDate: WorkFormat.parse(date),
                    firstDate: WorkFormat.parse(today), lastDate: WorkFormat.parse(today).add(const Duration(days: 120)));
                if (d != null) set(() => date = WorkFormat.iso(d));
              }),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('İzinli'), value: dayOff,
                onChanged: (v) => set(() => dayOff = v)),
            if (!dayOff) Row(children: [
              Expanded(child: OutlinedButton(onPressed: () => pickTime(true),
                  child: Text(start == null ? 'Başlangıç' : 'Başlangıç ${WorkFormat.hm(start!)}'))),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton(onPressed: () => pickTime(false),
                  child: Text(end == null ? 'Bitiş' : 'Bitiş ${WorkFormat.hm(end!)}'))),
            ]),
            if (!dayOff) ...[
              const SizedBox(height: 12),
              TextField(controller: brk, keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
                  decoration: const InputDecoration(labelText: 'Mola (dakika)')),
            ],
            if (existing == null) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: repeat,
                decoration: const InputDecoration(labelText: 'Tekrarla'),
                items: [for (var i = 0; i <= 8; i++)
                  DropdownMenuItem(value: i, child: Text(i == 0 ? 'Tekrarlama' : '$i hafta daha'))],
                onChanged: (v) => set(() => repeat = v ?? 0)),
            ],
            const SizedBox(height: 12),
            TextField(controller: note, maxLength: 200, decoration: const InputDecoration(labelText: 'Not (isteğe bağlı)')),
            if (error != null) Text(error!, style: TextStyle(color: Theme.of(sheet).colorScheme.error)),
            const SizedBox(height: 8),
            FilledButton(onPressed: busy ? null : () async {
              if (!dayOff && (start == null || end == null)) return set(() => error = 'Başlangıç ve bitiş saatini seçin.');
              set(() { busy = true; error = null; });
              final err = await state._write({
                'action': 'plan_save',
                if (existing != null) ...{'id': existing['id'], 'expectedUpdatedAt': existing['updatedAt']}
                else 'repeatWeeks': repeat,
                'date': date, 'dayOff': dayOff,
                'start': dayOff ? '' : WorkFormat.hm(start!), 'end': dayOff ? '' : WorkFormat.hm(end!),
                'breakMinutes': dayOff ? 0 : int.tryParse(brk.text) ?? 0, 'note': note.text.trim(),
              });
              if (err == null) {
                if (sheet.mounted) Navigator.pop(sheet);
                state._toast('✓ Vardiya kaydedildi.');
              } else {
                set(() { busy = false; error = err; });
              }
            }, child: busy ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Kaydet')),
          ])),
        );
      }),
    );
    brk.dispose();
    note.dispose();
  }
}

// ------------------------------------------------------------------- Maaş

class _MaasTab extends StatelessWidget {
  const _MaasTab({required this.state});
  final _WorkPageState state;
  @override
  Widget build(BuildContext context) {
    final w = state.week;
    final emp = Map<String, dynamic>.from(w['employee'] as Map);
    final pay = w['pay'] is Map ? Map<String, dynamic>.from(w['pay'] as Map) : null;
    final payments = rows(w['payments']);
    if (pay == null) {
      return const Center(child: Text('Maaş bilgisi gösterilemiyor.', style: TextStyle(color: NohutStyle.muted)));
    }
    if (pay['payrollEligible'] == false) {
      return const Padding(padding: EdgeInsets.all(24), child: Text(
          'Haftalık maaş bordrosuna dahil değilsiniz. Mesai kayıtlarınız yine de tutulur.',
          textAlign: TextAlign.center, style: TextStyle(color: NohutStyle.muted)));
    }
    String m(Object? c) => c is int ? money(c) : '—';
    final rate = emp['payRateCents'];
    return RefreshIndicator(
      onRefresh: state._load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          _StatusChip('${pay['financialStatus'] ?? '—'}'),
          if (pay['lastPaidOn'] != null)
            Text('son ödeme: ${WorkFormat.day('${pay['lastPaidOn']}')}', style: const TextStyle(color: NohutStyle.muted)),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _Stat(emp['payType'] == 'Haftalık Sabit' ? 'Haftalık ücret' : 'Saatlik ücret',
              rate is int ? money(rate) : 'Henüz belirlenmedi'),
          _Stat('Kazanılan', m(pay['earnedCents'])),
          _Stat('Ödenen', money(pay['paidCents'] is int ? pay['paidCents'] as int : 0)),
          _Stat('Kalan', m(pay['remainingCents'])),
        ]),
        if (pay['overdue'] == true) const Padding(padding: EdgeInsets.only(top: 10),
            child: Text('Ödeme günü geçti.', style: TextStyle(color: Color(0xff8a2414)))),
        const SizedBox(height: 20),
        const Text('Ödeme geçmişim', style: TextStyle(fontFamily: 'Bree', fontSize: 20, color: NohutStyle.green)),
        if (payments.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Bu hafta için ödeme kaydı yok.', style: TextStyle(color: NohutStyle.muted))),
        for (final p in payments)
          ListTile(contentPadding: EdgeInsets.zero,
            leading: Icon(p['reverses'] != null ? Icons.undo : Icons.payments_outlined, color: NohutStyle.green),
            title: Text('${p['kind']} · ${p['method']}'),
            subtitle: Text(WorkFormat.day('${p['paidOn']}')),
            trailing: Text(p['amountCents'] is int ? money(p['amountCents'] as int) : '—',
                style: const TextStyle(fontWeight: FontWeight.w700))),
        const SizedBox(height: 12),
        const Text('Yalnızca kendi ücret ve ödemelerinizi görürsünüz.',
            style: TextStyle(color: NohutStyle.muted, fontSize: 12)),
      ]),
    );
  }
}
