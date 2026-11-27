import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:nohut_core/nohut_core.dart';
import 'package:nohut_core/report_period.dart';

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
      final pending = await widget.store.managerQueue();
      if (mounted && generation == _generation) setState(() => queue = pending);
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
        const SnackBar(content: Text('PDF alınamadı. Windows bağlantısını kontrol edin. Büyük raporları Windows üzerinden alın.')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  List<Map<String, dynamic>> queue = [];
  static String _tl(Object? cents) => cents is int
    ? (cents / 100).toStringAsFixed(2) : '';
  static int _integer(String text) => int.tryParse(text.trim()) ??
    (throw const FormatException('Geçerli tam sayı girin.'));
  static int _zeroMoney(String text) => text.trim().isEmpty ||
    RegExp(r'^0([,.]0{1,2})?$').hasMatch(text.trim()) ? 0 : parseExpenseCents(text);

  Future<Map<String, String>?> _form(String title,
      Map<String, String> fields, {Map<String, List<String>> choices = const {}}) async {
    final controllers = {for (final e in fields.entries)
      e.key: TextEditingController(text: e.value)};
    final picked = {for (final e in choices.entries)
      e.key: e.value.contains(fields[e.key]) ? fields[e.key]! : e.value.first};
    try {
      return await showDialog<Map<String, String>>(context: context,
        builder: (ctx) => StatefulBuilder(builder: (ctx, update) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: SizedBox(width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final key in fields.keys)
                Padding(padding: const EdgeInsets.only(bottom: 10),
                  child: choices.containsKey(key)
                    ? DropdownButtonFormField<String>(
                      initialValue: picked[key], isExpanded: true,
                      decoration: InputDecoration(labelText: key),
                      items: [for (final v in choices[key]!)
                        DropdownMenuItem(value: v, child: Text(v))],
                      onChanged: (v) => update(() => picked[key] = v ?? picked[key]!))
                    : TextField(controller: controllers[key],
                      decoration: InputDecoration(labelText: key))),
            ]))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
            FilledButton(onPressed: () => Navigator.pop(ctx, {
              for (final key in fields.keys)
                key: (picked[key] ?? controllers[key]!.text).trim(),
            }), child: const Text('Kaydet')),
          ],
        )));
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      for (final c in controllers.values) { c.dispose(); }
    }
  }

  Future<void> _queue(String action, Map<String, dynamic> data) async {
    await widget.store.enqueueManager(action, data);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('İşlem telefona kaydedildi. Windows onayı bekleniyor.')));
    final pending = await widget.store.managerQueue();
    if (mounted) setState(() => queue = pending);
    await widget.store.sync(force: true);
    if (mounted) await _load();
  }

  Future<void> _edit(String type, [Map<String, dynamic>? row]) async {
    try {
      final selected = _day(_today()).startsWith(month) ? _today() : DateTime.parse(month + '-01');
      final monday = selected.subtract(Duration(days: selected.weekday - DateTime.monday));
      final version = row?['updatedAt'];
      if (type == 'payroll') {
        final employees = _rows(view?['employees']).where((e) =>
          e['payRateCents'] is int && e['payType'] is String).toList();
        if (employees.isEmpty) throw const FormatException('Windows üzerinde personel ücreti tanımlayın.');
        final labels = {for (final e in employees)
          '${e["id"]} · ${e["name"]}': e};
        final chosen = employees.where((e) => e['id'] == row?['employeeId']).firstOrNull;
        if (row != null && chosen == null) {
          throw const FormatException('Personel artık aktif değil. Windows üzerinden kontrol edin.');
        }
        final label = chosen == null ? labels.keys.first :
          '${chosen["id"]} · ${chosen["name"]}';
        final values = await _form('Haftalık Maaş', {
          'Personel': label,
          'Hafta başlangıcı (YYYY-MM-DD)': (row?['weekStart'] ?? _day(monday)).toString(),
          'Çalışma süresi (dakika)': (row?['workedMinutes'] ?? 0).toString(),
          'Prim (₺)': _tl(row?['bonusCents'] ?? 0),
          'Avans (₺)': _tl(row?['advanceCents'] ?? 0),
          'Durum': row?['paid'] == true ? 'Ödendi' : 'Ödenmedi',
        }, choices: {'Personel': row == null ? labels.keys.toList() : [label],
          'Durum': ['Ödenmedi', 'Ödendi']});
        if (values == null || !mounted) return;
        final employee = labels[values['Personel']]!;
        final week = values['Hafta başlangıcı (YYYY-MM-DD)']!;
        if (row != null && week != row['weekStart']) {
          throw const FormatException('Mevcut maaşın haftası değiştirilemez.');
        }
        await _queue('payroll_save', {
          'employeeId': employee['id'], 'weekStart': week,
          'expectedVersion': version, 'expectedRate': employee['payRateCents'],
          'expectedPayType': employee['payType'],
          'workedMinutes': _integer(values['Çalışma süresi (dakika)']!),
          'bonusCents': _zeroMoney(values['Prim (₺)']!),
          'advanceCents': _zeroMoney(values['Avans (₺)']!),
          'paid': values['Durum'] == 'Ödendi',
        });
      } else if (type == 'fixed') {
        const categories = ['Kira', 'Muhasebe', 'SGK', 'Elektrik / Su / Doğalgaz', 'İnternet', 'Diğer'];
        final v = await _form('Sabit Gider', {
          'Kategori': (row?['category'] ?? 'Kira').toString(),
          'Ad': (row?['name'] ?? '').toString(),
          'Aylık Tutar (₺)': _tl(row?['amountCents']),
          'Başlangıç (YYYY-MM)': (row?['startMonth'] ?? month).toString(),
          'Vade günü (1–28)': (row?['dueDay'] ?? 1).toString(),
          'Durum': 'Aktif',
        }, choices: {'Kategori': categories, 'Durum': ['Aktif', 'Pasif']});
        if (v == null || !mounted) return;
        await _queue('fixed_save', {'id': row?['id'], 'expectedVersion': version,
          'category': v['Kategori'], 'name': v['Ad'], 'amountCents': parseExpenseCents(v['Aylık Tutar (₺)']!),
          'startMonth': v['Başlangıç (YYYY-MM)'], 'dueDay': _integer(v['Vade günü (1–28)']!),
          'active': v['Durum'] == 'Aktif'});
      } else if (type == 'other') {
        final v = await _form('Diğer Gider Ekle', {
          'Tarih (YYYY-MM-DD)': _day(selected), 'Kategori': 'Diğer',
          'Ad': '', 'Tutar (₺)': '', 'Ödeme': 'Nakit',
        }, choices: {'Kategori': ['Yol / Nakliye', 'Temizlik', 'Bakım / Onarım',
          'Elektrik / Su / Doğalgaz', 'Diğer'], 'Ödeme': financeMethods});
        if (v == null || !mounted) return;
        await _queue('other_create', {'date': v['Tarih (YYYY-MM-DD)'], 'category': v['Kategori'],
          'name': v['Ad'], 'amountCents': parseExpenseCents(v['Tutar (₺)']!),
          'paymentMethod': v['Ödeme']});
      } else if (type == 'manual') {
        final v = await _form('Manuel Platform Geliri', {
          'Platform': (row?['source'] ?? 'Yemeksepeti').toString(),
          'Tür': (row?['kind'] ?? 'Net').toString(),
          'Tutar (₺)': _tl(row?['amountCents']), 'Not': (row?['note'] ?? '').toString(),
        }, choices: {'Platform': row == null ? ['Yemeksepeti', 'Migros Yemek'] :
          [row['source'].toString()], 'Tür': ['Brüt', 'Net']});
        if (v == null || !mounted) return;
        await _queue('manual_save', {'source': v['Platform'], 'month': month,
          'expectedVersion': version, 'kind': v['Tür'],
          'amountCents': parseExpenseCents(v['Tutar (₺)']!), 'note': v['Not']});
      } else if (type == 'quick') {
        // §24.8: the only way to add a new daily purchase.
        final v = await showDialog<Map<String, dynamic>>(context: context,
          builder: (_) => QuickExpenseDialog(previous: row,
            title: row == null ? 'Hızlı Gider Ekle' : 'Hızlı Gider Düzenle',
            saveLabel: 'Kaydet'));
        if (v == null || !mounted) return;
        await _queue('quick_save', {if (row != null) 'id': row['id'],
          'expectedVersion': version, 'date': v['date'],
          'storeBrand': v['storeBrand'], 'market': v['market'],
          'amountsCents': v['amountsCents'], 'paymentMethod': v['paymentMethod'],
          'note': v['note']});
      } else if (type == 'material') {
        final v = await _form('Detaylı Malzeme', {
          'Tarih (YYYY-MM-DD)': (row?['date'] ?? _day(selected)).toString(),
          'Ürün': (row?['title'] ?? '').toString(), 'Market': (row?['storeBrand'] ?? 'Diğer').toString(),
          'Market adı': (row?['market'] ?? '').toString(), 'Birim': (row?['unit'] ?? 'kg').toString(),
          'Miktar': row?['quantityMilli'] is int ? ((row!['quantityMilli'] as int) / 1000).toString() : '',
          'Birim Fiyat (₺)': _tl(row?['pricePerUnitCents']),
          'İndirim türü': (row?['discountType'] ?? 'Yok').toString(),
          'İndirim (₺ veya %)': _tl(row?['discountValue'] ?? 0),
          'Ödeme': (row?['paymentMethod'] ?? 'Nakit').toString(), 'Not': (row?['note'] ?? '').toString(),
        }, choices: {'Market': materialStores, 'Birim': ['kg', 'lt', 'adet', 'paket'],
          'İndirim türü': ['Yok', 'Tutar', 'Yüzde'], 'Ödeme': financeMethods});
        if (v == null || !mounted) return;
        final quantity = double.tryParse(v['Miktar']!.replaceAll(',', '.'));
        if (quantity == null || !quantity.isFinite || quantity <= 0 || quantity > 100000) {
          throw const FormatException('Miktar geçersiz.');
        }
        await _queue('material_save', {'id': row?['id'], 'expectedVersion': version,
          'date': v['Tarih (YYYY-MM-DD)'], 'title': v['Ürün'],
          'storeBrand': v['Market'], 'market': v['Market'] == 'Diğer' ? v['Market adı'] : v['Market'], 'unit': v['Birim'],
          'quantityMilli': (quantity * 1000).round(), 'pricePerUnitCents': parseExpenseCents(v['Birim Fiyat (₺)']!),
          'discountType': v['İndirim türü'], 'discountValue': v['İndirim türü'] == 'Yok' ? 0 :
            _zeroMoney(v['İndirim (₺ veya %)']!), 'paymentMethod': v['Ödeme'], 'note': v['Not']});
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is FormatException ? e.message : 'İşlem kaydedilemedi.')));
    }
  }

  Future<void> _confirm(String title, String action, Map<String, dynamic> data) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(title), content: const Text('İşlem Windows onayı alındığında uygulanır.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Onayla')),
      ]));
    if (ok != true || !mounted) return;
    try { await _queue(action, data); } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('İşlem kaydedilemedi.')));
    }
  }

  Widget _add(String title, String type) => Align(alignment: Alignment.centerLeft,
    child: OutlinedButton.icon(onPressed: busy ? null : () => _edit(type),
      icon: const Icon(Icons.add), label: Text(title)));

  Widget _section(String title, List<Widget> children) => Card(
    child: Padding(padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        if (children.isEmpty) const Text('Kayıt yok.'),
        ...children,
      ])));

  Widget _line(String title, Object? value, {String? subtitle, VoidCallback? onTap, VoidCallback? onAction}) =>
    ListTile(contentPadding: EdgeInsets.zero, title: Text(title), onTap: onTap,
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [Text(_money(value), style: const TextStyle(fontWeight: FontWeight.w700)), if (onAction != null) IconButton(tooltip: 'İşlem', onPressed: onAction, icon: const Icon(Icons.more_vert))]));

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
        if (queue.isNotEmpty) _section('Bekleyen Yönetici İşlemleri', [
          for (final item in queue)
            ListTile(title: Text((item['payload'] as Map)['action'].toString()),
              subtitle: Text((item['message'] ?? 'Windows onayı bekliyor').toString()),
              trailing: item['status'] == 'conflict'
                ? TextButton(onPressed: busy ? null : () async {
                    await widget.store.discardManagerConflict((item['payload'] as Map)['requestId'] as String);
                    if (mounted) await _load();
                  }, child: const Text('Vazgeç')) : const Icon(Icons.schedule)),
          OutlinedButton(onPressed: busy ? null : () async {
            await widget.store.sync(force: true);
            if (mounted) await _load();
          }, child: const Text('Bekleyenleri Gönder')),
        ]),
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
            _add('Manuel Brüt / Net Ekle', 'manual'),
            for (final p in _rows(data['manualPlatformSales']))
              _line(p['source'].toString() + ' · Manuel ' + p['kind'].toString(), p['amountCents'],
                onTap: busy ? null : () => _edit('manual', p),
                onAction: busy ? null : () => _confirm('Manuel gelir iptal edilsin mi?', 'manual_void', {'source': p['source'], 'month': month, 'expectedVersion': p['updatedAt']})),
            for (final p in _rows(data['platforms']))
              _line(p['source'].toString(), p['netCents'],
                subtitle: (p['origin'] ?? '').toString() +
                  ' · Brüt ' + _money(p['grossCents']) +
                  ' · Kesinti ' + _money(p['deductionCents'])),
          ]),
          _section('Giderler · Günlük Malzeme · ' + _money(summary['materialsCents']), [
            _add('Hızlı Gider Ekle', 'quick'),
            for (final p in _rows(data['materials']))
              _line((p['title'] ?? 'Malzeme').toString() +
                (p['voided'] == true ? ' · İPTAL' : ''), p['totalCents'],
                // Quick rows edit in the quick form; older itemized rows keep
                // their readable details and audited edit/void.
                onTap: busy || p['voided'] == true ? null :
                  () => _edit(p['recordType'] == 'quick' ? 'quick' : 'material', p),
                onAction: busy || p['voided'] == true ? null : () => _confirm(
                  'Gider iptal edilsin mi?',
                  p['recordType'] == 'quick' ? 'quick_void' : 'material_void',
                  {'id': p['id'], 'expectedVersion': p['updatedAt'], 'reason': 'Android yönetici iptali'}),
                subtitle: (p['date'] ?? '').toString() + ' · ' +
                  (p['market'] ?? '').toString() +
                  (p['recordType'] == 'quick' ? ' · Hızlı gider' : ' · Ürünlü kayıt')),
          ]),
          // Legacy weekly rows only: new pay is recorded in Haftalık Maaş
          // Ödemeleri (payment ledger). A new legacy row would block ledger
          // payments for that week, so none can be added here.
          if (_rows(data['weeklyPayroll']).isNotEmpty)
          _section('Eski Haftalık Maaş Kayıtları · ' + _money(summary['payrollCents']), [
            for (final p in _rows(data['weeklyPayroll']))
              _line((p['employeeName'] ?? 'Personel').toString(), p['grossCents'],
                onTap: busy || p['paid'] == true ? null : () => _edit('payroll', p),
                onAction: busy || p['paid'] == true ? null : () => _confirm('Maaş ödendi olarak işaretlensin mi?', 'payroll_paid', {'employeeId': p['employeeId'], 'weekStart': p['weekStart'], 'expectedVersion': p['updatedAt']}),
                subtitle: (p['weekStart'] ?? '').toString() + ' – ' +
                  (p['weekEnd'] ?? '').toString() + '\nAvans: ' +
                  _money(p['advanceCents']) + ' · Avans sonrası: ' +
                  _money(p['payableCents']) + ' · ' +
                  (p['paid'] == true ? 'Ödendi' : 'Ödenmedi')),
          ]),
          _section('Sabit Giderler · ' + _money(summary['fixedCents']), [
            _add('Sabit Gider Ekle', 'fixed'),
            for (final p in _rows(data['monthlyFixed']))
              _line((p['name'] ?? '').toString(), p['amountCents'],
                onTap: busy ? null : () => _edit('fixed', p),
                onAction: busy ? null : () => _confirm('Ödeme durumu değiştirilsin mi?', 'fixed_paid', {'id': p['id'], 'month': month, 'expectedVersion': p['updatedAt'], 'expectedPaidAt': fixedPayments.where((r) => r['templateId'] == p['id']).firstOrNull?['paidAt'], 'paid': !fixedPayments.any((r) => r['templateId'] == p['id'])}),
                subtitle: (p['category'] ?? '').toString() + ' · ' +
                  (fixedPayments.any((r) => r['templateId'] == p['id'])
                    ? 'Ödendi' : 'Bekliyor')),
          ]),
          _section('Diğer Giderler · ' + _money(summary['otherCents']), [
            _add('Diğer Gider Ekle', 'other'),
            for (final p in _rows(data['other']))
              _line((p['name'] ?? '').toString() +
                (p['voided'] == true ? ' · İPTAL' : ''), p['amountCents'],
                onAction: busy || p['voided'] == true ? null : () => _confirm('Gider iptal edilsin mi?', 'other_void', {'id': p['id'], 'expectedVersion': p['createdAt'], 'reason': 'Android yönetici iptali'}),
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
  String preset = 'Bu Ay';
  late ReportPeriod range = ReportPeriod.preset('Bu Ay');
  String? error;

  Future<void> _pick(bool start) async {
    final selected = await showDatePicker(context: context,
      initialDate: ReportPeriod.parse(start ? range.from : range.to),
      firstDate: DateTime(2000), lastDate: ReportPeriod.today());
    if (selected == null || !mounted) return;
    setState(() {
      preset = 'Özel Tarih';
      range = ReportPeriod(start ? ReportPeriod.day(selected) : range.from,
        start ? range.to : ReportPeriod.day(selected));
      error = null;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Tam Yönetim Raporu · Tek PDF'),
    content: SingleChildScrollView(child: SizedBox(width: 420,
      child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Finans, personel, masalar, siparişler, ürünler, '
            'online satışlar ve giderler tek PDF dosyasında.'),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('report-preset-' + preset),
            initialValue: preset, isExpanded: true,
            decoration: const InputDecoration(labelText: 'Rapor dönemi'),
            items: [for (final p in ReportPeriod.presets)
              DropdownMenuItem(value: p, child: Text(p))],
            onChanged: (v) => setState(() {
              preset = v ?? 'Bu Ay';
              if (preset != 'Özel Tarih') range = ReportPeriod.preset(preset);
              error = null;
            })),
          OutlinedButton.icon(onPressed: () => _pick(true),
            icon: const Icon(Icons.calendar_today_outlined),
            label: Text('Başlangıç: ' + range.from)),
          OutlinedButton.icon(onPressed: () => _pick(false),
            icon: const Icon(Icons.calendar_today_outlined),
            label: Text('Bitiş: ' + range.to)),
          const Text('Yöneticiye özel. Windows bağlantısı gereklidir. '
            'Kısmi aylardaki aylık giderler ayrı gösterilir.'),
          if (error != null) Text(error!, style: const TextStyle(color: Colors.red)),
        ]))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Vazgeç')),
      FilledButton(onPressed: () {
        try {
          range.validate();
          Navigator.pop(context, {
            'operation': 'report', 'from': range.from, 'to': range.to,
          });
        } on FormatException catch (e) {
          setState(() => error = e.message);
        }
      }, child: const Text('Tek PDF Oluştur')),
    ]);
}
