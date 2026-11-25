import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'expense_drafts.dart';

/// Windows produces the official financial totals and PDFs. Android caches
/// the selected month, so the same confirmed figures can be read offline.
class ManagerFinancePage extends StatefulWidget {
  const ManagerFinancePage({super.key, required this.store});
  final ExpenseDraftStore store;

  @override
  State<ManagerFinancePage> createState() => _ManagerFinancePageState();
}

class _ManagerFinancePageState extends State<ManagerFinancePage> {
  late String month = _today().toIso8601String().substring(0, 7);
  Map<String, dynamic>? view;
  bool busy = false;
  bool offline = true;
  String? error;
  int _generation = 0;

  static DateTime _today() => DateTime.now().toUtc().add(const Duration(hours: 3));
  static String _day(DateTime date) => date.toIso8601String().substring(0, 10);
  static String _money(Object? cents) => cents is int
    ? (cents / 100).toStringAsFixed(2).replaceAll('.', ',') + ' ₺' : '—';
  static List<Map<String, dynamic>> _rows(Object? raw) => raw is List
    ? raw.whereType<Map>().map((r) => Map<String, dynamic>.from(r)).toList() : [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final selected = month;
    setState(() { busy = true; error = null; });
    try {
      final cached = await widget.store.cachedMonth(selected);
      if (!mounted || generation != _generation) return;
      setState(() { view = cached; offline = true; });
      final fresh = await widget.store.fetchMonth(selected);
      if (!mounted || generation != _generation) return;
      setState(() { view = fresh; offline = false; });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => error = 'Windows finans bağlantısı gerekli. '
          'Varsa son eşitlenen kayıtlar gösteriliyor.');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => busy = false);
    }
  }

  Future<void> _selectMonth() async {
    final selected = await showDatePicker(context: context,
      initialDate: DateTime.parse(month + '-01'), firstDate: DateTime(2000),
      lastDate: _today(), helpText: 'Rapor ayı için bir gün seçin');
    if (!mounted || selected == null) return;
    setState(() { month = _day(selected).substring(0, 7); view = null; });
    await _load();
  }

  Future<void> _pdf() async {
    if (busy) return;
    final today = _today();
    final initial = _day(today).startsWith(month)
      ? today : DateTime.parse(month + '-01');
    final request = await showDialog<Map<String, dynamic>>(
      context: context, builder: (_) => _ReportDialog(month: month, initial: initial));
    if (!mounted || request == null) return;
    setState(() => busy = true);
    try {
      final result = await widget.store.managerRequest(request);
      final bytes = base64Decode(result['pdf'] as String);
      if (bytes.length < 5 || ascii.decode(bytes.take(5).toList()) != '%PDF-') {
        throw const FormatException('PDF geçersiz.');
      }
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(bytes, mimeType: 'application/pdf')],
        fileNameOverrides: [result['name'] as String],
        sharePositionOrigin: box == null ? null :
          box.localToGlobal(Offset.zero) & box.size,
      ));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PDF alınamadı. Windows bağlantısını kontrol edin.')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _section(String title, List<Widget> children) => Card(
    child: Padding(padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        if (children.isEmpty) const Text('Kayıt yok.'),
        ...children,
      ])));

  Widget _line(String title, Object? value, {String? subtitle}) =>
    ListTile(contentPadding: EdgeInsets.zero, title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: Text(_money(value), style: const TextStyle(fontWeight: FontWeight.w700)));

  @override
  Widget build(BuildContext context) {
    final data = view;
    final summary = data?['summary'] as Map? ?? {};
    final fixedPayments = _rows(data?['fixedPayments']);
    return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1100),
      child: ListView(padding: const EdgeInsets.all(12), children: [
        Text('Finans · Yönetici', style: Theme.of(context).textTheme.headlineSmall),
        const Text('Özel finans bilgileri · Yalnızca yetkili cihaz'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(onPressed: busy ? null : _selectMonth,
            icon: const Icon(Icons.calendar_month), label: Text(month)),
          OutlinedButton.icon(onPressed: busy ? null : _load,
            icon: const Icon(Icons.refresh), label: const Text('Yenile')),
          FilledButton.icon(onPressed: busy ? null : _pdf,
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('PDF Raporu')),
        ]),
        if (busy) const LinearProgressIndicator(),
        if (error != null) Text(error!),
        if (data != null) ...[
          Text((offline ? 'Çevrimdışı kopya · ' : 'Windows kaydı · ') +
            (data['snapshotAt'] ?? '').toString()),
          _section('Genel Bakış', [
            _line('Yerel tahsilat', summary['localReceiptsCents']),
            _line('Online bilinen net', summary['onlineKnownNetCents']),
            _line('Kesintisi bilinmeyen brüt', summary['onlineUnpricedGrossCents']),
            _line('Toplam gider', summary['totalExpensesCents']),
            _line('Tahmini faaliyet farkı', summary['estimateCents'],
              subtitle: 'Vergi ve stok tüketimi dahil değildir.'),
          ]),
          _section('Online platformlar', [
            for (final p in _rows(data['platforms']))
              _line(p['source'].toString(), p['netCents'],
                subtitle: (p['origin'] ?? '').toString() +
                  ' · Brüt ' + _money(p['grossCents']) +
                  ' · Kesinti ' + _money(p['deductionCents'])),
          ]),
          _section('Günlük Malzeme · ' + _money(summary['materialsCents']), [
            for (final p in _rows(data['materials']))
              _line((p['title'] ?? 'Malzeme').toString() +
                (p['voided'] == true ? ' · İPTAL' : ''), p['totalCents'],
                subtitle: (p['date'] ?? '').toString() + ' · ' +
                  (p['market'] ?? '').toString() +
                  (p['recordType'] == 'quick' ? ' · Hızlı gider' : '')),
          ]),
          _section('Haftalık Maaşlar · ' + _money(summary['payrollCents']), [
            for (final p in _rows(data['weeklyPayroll']))
              _line((p['employeeName'] ?? 'Personel').toString(), p['grossCents'],
                subtitle: (p['weekStart'] ?? '').toString() + ' – ' +
                  (p['weekEnd'] ?? '').toString() + '\nAvans: ' +
                  _money(p['advanceCents']) + ' · Avans sonrası: ' +
                  _money(p['payableCents']) + ' · ' +
                  (p['paid'] == true ? 'Ödendi' : 'Ödenmedi')),
          ]),
          _section('Sabit Giderler · ' + _money(summary['fixedCents']), [
            for (final p in _rows(data['monthlyFixed']))
              _line((p['name'] ?? '').toString(), p['amountCents'],
                subtitle: (p['category'] ?? '').toString() + ' · ' +
                  (fixedPayments.any((r) => r['templateId'] == p['id'])
                    ? 'Ödendi' : 'Bekliyor')),
          ]),
          _section('Diğer Giderler · ' + _money(summary['otherCents']), [
            for (final p in _rows(data['other']))
              _line((p['name'] ?? '').toString() +
                (p['voided'] == true ? ' · İPTAL' : ''), p['amountCents'],
                subtitle: (p['date'] ?? '').toString() + ' · ' +
                  (p['category'] ?? '').toString()),
          ]),
          const Text('Bu ekrandaki tutarlar Windows tarafından onaylanan '
            'kayıtlardır. Bekleyen mobil giderler henüz dahil değildir. '
            'PDF üretimi için restoran bağlantısı gerekir.'),
        ],
      ])));
  }
}

class _ReportDialog extends StatefulWidget {
  const _ReportDialog({required this.month, required this.initial});
  final String month;
  final DateTime initial;
  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  String kind = 'all';
  late DateTime day = widget.initial;
  late DateTime week = day.subtract(Duration(days: day.weekday - DateTime.monday));
  static String date(DateTime d) => d.toIso8601String().substring(0, 10);

  Future<void> _pick(bool weekly) async {
    final selected = await showDatePicker(context: context,
      initialDate: weekly ? week : day, firstDate: DateTime(1999),
      lastDate: _ManagerFinancePageState._today());
    if (selected == null || !mounted) return;
    setState(() {
      if (weekly) {
        week = selected.subtract(Duration(days: selected.weekday - DateTime.monday));
      } else {
        day = selected;
      }
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('PDF Raporu'),
    content: SingleChildScrollView(child: SizedBox(width: 420,
      child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DropdownButtonFormField<String>(initialValue: kind, isExpanded: true,
            items: const [
              DropdownMenuItem(value: 'all', child: Text('Tüm Raporlar · Tek PDF')),
              DropdownMenuItem(value: 'monthly', child: Text('Aylık Finans Özeti')),
              DropdownMenuItem(value: 'materials', child: Text('Günlük Malzeme')),
              DropdownMenuItem(value: 'payroll', child: Text('Haftalık Maaşlar')),
            ],
            onChanged: (v) => setState(() => kind = v ?? 'all')),
          if (kind == 'all' || kind == 'monthly') Text('Finans ayı: ' + widget.month),
          if (kind == 'all' || kind == 'materials')
            TextButton(onPressed: () => _pick(false), child: Text('Alış günü: ' + date(day))),
          if (kind == 'all' || kind == 'payroll')
            TextButton(onPressed: () => _pick(true), child: Text('Hafta: ' + date(week))),
          if (kind == 'all' || kind == 'payroll')
            const Text('Özel maaş bilgileri içerir. Yalnızca yetkili kişilerle paylaşın.'),
        ]))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Vazgeç')),
      FilledButton(onPressed: () => Navigator.pop(context, {
        'operation': 'report', 'kind': kind, 'month': widget.month,
        'day': date(day), 'weekStart': date(week),
      }), child: const Text('Oluştur ve Paylaş')),
    ]);
}
