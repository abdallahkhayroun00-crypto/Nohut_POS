// §24.6 Haftalık Maaş Ödemeleri in the native Yönetici app. The numbers come
// from Windows (`ownerPayroll`, the same lib/payroll.dart calculation as the
// LAN page); the phone only records payments made outside the POS
// (`managerWrite` `payroll_payment`). A payment is shown as saved only after
// Windows confirms it, and a retry after a lost connection reuses its request
// id, so Windows records it once.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pos_api.dart';
import 'style.dart';
import 'work_page.dart' show WorkFormat, WorkRequestIds;

typedef OwnerRequest = Future<Json> Function(Json payload);

/// "1.250,50" / "1250,5" / "800" → kuruş, with integer math only.
int? parseTl(String raw) {
  final s = raw.replaceAll('₺', '').replaceAll(' ', '').trim();
  final m = RegExp(r'^(\d{1,3}(?:\.\d{3})+|\d+)(?:,(\d{1,2}))?$').firstMatch(s);
  if (m == null) return null;
  final lira = int.parse(m.group(1)!.replaceAll('.', ''));
  final k = (m.group(2) ?? '').padRight(2, '0');
  return lira * 100 + int.parse(k);
}

class OwnerPayrollPage extends StatefulWidget {
  const OwnerPayrollPage({super.key, required this.request});
  final OwnerRequest request;

  @override
  State<OwnerPayrollPage> createState() => _OwnerPayrollPageState();
}

class _OwnerPayrollPageState extends State<OwnerPayrollPage> {
  final ids = WorkRequestIds();
  String? weekStart;
  Json? data;
  String? error;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  /// Loads a week from Windows; true when fresh numbers arrived.
  Future<bool> load([String? week]) async {
    setState(() { busy = true; error = null; });
    try {
      final r = await widget.request({'operation': 'ownerPayroll', if (week != null) 'weekStart': week});
      if (!mounted) return false;
      setState(() { data = r; weekStart = '${r['weekStart']}'; });
      return true;
    } on FormatException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = 'Windows bağlantısı yok. Maaş bilgileri yalnızca Windows açıkken gösterilir.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
    return false;
  }

  int? paidOf(Object? employeeId) =>
      people.where((r) => r['employeeId'] == employeeId).firstOrNull?['paidCents'] as int?;

  List<Json> get people => rows(data?['rows']);
  List<Json> get payments => rows(data?['payments']);
  String get today => '${data?['today'] ?? ''}';
  bool get isCurrentOrLater =>
      weekStart != null && today.length == 10 && WorkFormat.addDays(weekStart!, 7).compareTo(today) > 0;

  int? sum(String key) {
    var n = 0;
    // Someone with no work and no payments owes nothing; only a missing
    // rate for real hours makes the total unknown.
    for (final r in people.where((r) => r['financialStatus'] != 'Çalışma kaydı yok')) {
      final v = r[key];
      if (v is! int) return null;
      n += v;
    }
    return n;
  }

  String m(Object? v) => v is int ? money(v) : '—';

  Future<void> pay(Json row) async {
    final input = await PaymentSheet.open(context, row: row, today: today);
    if (input == null || !mounted) return;
    final payload = <String, dynamic>{
      'employeeId': row['employeeId'], 'weekStart': weekStart, ...input,
      'expectedPaidCents': row['paidCents'],
    };
    final requestId = ids.forPayload(payload);
    final before = row['paidCents'];
    final amount = (input['cashCents'] as int) + (input['bankCents'] as int);
    setState(() => busy = true);
    String message;
    var unknown = false;
    try {
      await widget.request({'operation': 'managerWrite', 'requestId': requestId,
        'action': 'payroll_payment', 'data': payload});
      ids.done(payload);
      message = 'Ödeme Windows’a kaydedildi.';
      HapticFeedback.mediumImpact();
    } on FormatException catch (e) {
      ids.done(payload);
      message = e.message;
    } catch (_) {
      unknown = true;
      message = '';
    }
    if (!mounted) return;
    setState(() => busy = false);
    final fresh = await load(weekStart);
    if (!mounted) return;
    if (unknown) {
      // The reply was lost. Ask Windows what happened before saying anything:
      // if the payment is there it was saved; otherwise the same request id
      // is kept, so an identical retry cannot record it twice.
      final now = paidOf(row['employeeId']);
      if (fresh && before is int && now == before + amount) {
        ids.done(payload);
        message = 'Ödeme Windows’a kaydedildi (bağlantı geri geldi).';
      } else if (fresh && now == before) {
        message = 'Ödeme kaydedilmedi. Tekrar deneyebilirsiniz.';
      } else {
        message = 'Bağlantı kesildi; ödeme doğrulanmadı. Aynı ödemeyi tekrar deneyin, kayıt iki kez oluşmaz.';
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final nc = context.nohut;
    final w = weekStart;
    return Scaffold(
      appBar: AppBar(title: const Text('Haftalık Maaş Ödemeleri'), actions: [
        IconButton(tooltip: 'Yenile', onPressed: busy ? null : () => load(w), icon: const Icon(Icons.refresh)),
      ]),
      body: RefreshIndicator(onRefresh: () => load(w), child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Card(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2), child: Row(children: [
            IconButton(tooltip: 'Önceki hafta', onPressed: busy || w == null ? null : () => load(WorkFormat.addDays(w, -7)),
                icon: const Icon(Icons.chevron_left)),
            Expanded(child: Text(w == null ? 'Hafta' : '${WorkFormat.day(w)} – ${WorkFormat.day(WorkFormat.addDays(w, 6))}',
                textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
            IconButton(tooltip: 'Sonraki hafta', onPressed: busy || w == null || isCurrentOrLater ? null
                : () => load(WorkFormat.addDays(w, 7)), icon: const Icon(Icons.chevron_right)),
          ]))),
          if (busy) const Padding(padding: EdgeInsets.only(top: 6), child: LinearProgressIndicator()),
          if (error != null) Card(child: NohutEmpty(icon: Icons.cloud_off_outlined, message: error!,
              action: 'Tekrar dene', onAction: () => load(w))),
          if (data != null) ...[
            const SizedBox(height: 10),
            NohutMetric(label: 'Kalan ödeme', emphasis: true, icon: Icons.account_balance_wallet_outlined,
                value: m(sum('remainingCents')), caption: 'Bu haftanın hak edişi, kaydedilen ödemeler düşülerek'),
            const SizedBox(height: 10),
            NohutMetricGrid(children: [
              NohutMetric(label: 'Hak ediş', value: m(sum('earnedCents')), icon: Icons.work_history_outlined),
              NohutMetric(label: 'Ödenen', value: m(sum('paidCents')), icon: Icons.payments_outlined),
            ]),
            if (sum('earnedCents') == null)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text(
                  'Ücreti tanımlı olmayan personel var; toplamlar bu yüzden gösterilmiyor.',
                  style: TextStyle(color: nc.muted, fontSize: 13))),
            const NohutSection('Personel', subtitle: 'Ödemeler POS dışında yapılır; burada yalnızca kaydedilir. Gönderilen mesai onay değildir.'),
            if (people.isEmpty) const Card(child: NohutEmpty(icon: Icons.groups_outlined,
                message: 'Bu hafta bordroya dahil personel yok.')),
            for (final r in people) _PersonCard(row: r, onPay: busy ? null : () => pay(r)),
            const NohutSection('Bu haftanın ödemeleri'),
            if (payments.isEmpty) const Card(child: NohutEmpty(icon: Icons.receipt_long_outlined, message: 'Kayıtlı ödeme yok.')),
            for (final p in payments) Card(child: ListTile(
              leading: Icon(p['reverses'] != null || p['kind'] == 'Düzeltme' ? Icons.undo : Icons.payments_outlined, color: nc.muted),
              title: Text(_name(p), style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text([WorkFormat.day('${p['paidOn']}'), '${p['kind'] ?? 'Ödeme'}', '${p['method'] ?? ''}',
                if ('${p['note'] ?? ''}'.isNotEmpty) '${p['note']}'].join(' · ')),
              trailing: Text(m(p['amountCents']), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            )),
            Padding(padding: const EdgeInsets.only(top: 10), child: Text(
              'Düzeltme (ters kayıt), ücret değişikliği ve "Ödenmedi" bildirimi Windows veya Yönetici web sayfasından yapılır.',
              style: TextStyle(color: nc.muted, fontSize: 13))),
          ],
        ],
      )),
    );
  }

  String _name(Json p) {
    final r = people.where((x) => x['employeeId'] == p['employeeId']).firstOrNull;
    return '${r?['name'] ?? p['employeeName'] ?? 'Personel'}';
  }
}

class _PersonCard extends StatelessWidget {
  const _PersonCard({required this.row, required this.onPay});
  final Json row;
  final VoidCallback? onPay;

  @override
  Widget build(BuildContext context) {
    final nc = context.nohut;
    String m(Object? v) => v is int ? money(v) : '—';
    final status = '${row['financialStatus'] ?? ''}';
    final rate = row['rate'] is Map ? row['rate'] as Map : null;
    final canPay = row['legacy'] != true && row['remainingCents'] is int && (row['remainingCents'] as int) > 0;
    Widget cell(String label, String value) => Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(color: nc.muted, fontSize: 12.5)),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
    ]));
    return Card(child: Padding(padding: const EdgeInsets.fromLTRB(14, 12, 14, 12), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('${row['name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
          NohutPill(status, tone: NohutPill.toneFor(status)),
          if (row['overdue'] == true) const NohutPill('Gecikti', tone: NohutTone.danger, icon: Icons.schedule),
        ]),
        const SizedBox(height: 4),
        Text([WorkFormat.hours(row['minutes']),
          if (rate != null) '${rate['payType']} ${m(rate['rateCents'])}' else 'Ücret belirlenmedi',
          if (row['legacy'] == true) 'Eski bordro kaydı'].join(' · '),
          style: TextStyle(color: nc.muted, fontSize: 13.5)),
        const SizedBox(height: 10),
        Row(children: [cell('Hak ediş', m(row['earnedCents'])), cell('Ödenen', m(row['paidCents'])),
          cell('Kalan', m(row['remainingCents']))]),
        if (canPay) ...[
          const SizedBox(height: 10),
          Align(alignment: Alignment.centerRight, child: FilledButton.icon(onPressed: onPay,
              icon: const Icon(Icons.add_card), label: const Text('Ödeme Kaydet'))),
        ],
      ])));
  }
}

/// Native payment form. Returns the payment fields, or null when cancelled.
class PaymentSheet extends StatefulWidget {
  const PaymentSheet({super.key, required this.row, required this.today});
  final Json row;
  final String today;

  static Future<Json?> open(BuildContext context, {required Json row, required String today}) =>
      showModalBottomSheet<Json>(context: context, isScrollControlled: true, showDragHandle: true,
          builder: (_) => PaymentSheet(row: row, today: today));

  @override
  State<PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<PaymentSheet> {
  String method = 'Nakit', kind = 'Ödeme';
  late String paidOn = widget.today;
  late final cash = TextEditingController(text: _plain(widget.row['remainingCents']));
  final bank = TextEditingController(), note = TextEditingController();
  String? error;

  static String _plain(Object? cents) {
    if (cents is! int || cents <= 0) return '';
    final k = cents % 100;
    return '${cents ~/ 100}${k == 0 ? '' : ',${k.toString().padLeft(2, '0')}'}';
  }

  @override
  void dispose() { cash.dispose(); bank.dispose(); note.dispose(); super.dispose(); }

  Future<void> pickDay() async {
    final last = WorkFormat.parse(widget.today);
    final d = await showDatePicker(context: context, initialDate: WorkFormat.parse(paidOn),
        firstDate: last.subtract(const Duration(days: 120)), lastDate: last);
    if (d != null) setState(() => paidOn = WorkFormat.iso(d));
  }

  Future<void> save() async {
    final c = method == 'Havale/EFT' ? 0 : parseTl(cash.text);
    final b = method == 'Nakit' ? 0 : parseTl(bank.text);
    if (c == null || b == null || c + b <= 0) {
      setState(() => error = 'Tutarı girin (ör. 1.250,00).');
      return;
    }
    if (method == 'Karma' && (c == 0 || b == 0)) {
      setState(() => error = 'Karma ödemede nakit ve havale tutarını girin.');
      return;
    }
    final total = c + b;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Ödeme kaydedilsin mi?'),
      content: Text('${widget.row['name']} · ${money(total)} · $method · $kind\n'
          'Bu işlem para göndermez; yalnızca POS dışında yapılan ödemeyi kaydeder.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Kaydet')),
      ]));
    if (ok != true || !mounted) return;
    Navigator.pop(context, <String, dynamic>{'paidOn': paidOn, 'method': method, 'kind': kind,
      'cashCents': c, 'bankCents': b, if (note.text.trim().isNotEmpty) 'note': note.text.trim()});
  }

  @override
  Widget build(BuildContext context) {
    final nc = context.nohut;
    InputDecoration field(String label) => InputDecoration(labelText: label, suffixText: '₺');
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text('Ödeme Kaydet · ${widget.row['name']}', style: Theme.of(context).textTheme.titleLarge),
        Text('Kalan ${widget.row['remainingCents'] is int ? money(widget.row['remainingCents'] as int) : '—'}',
            style: TextStyle(color: nc.muted)),
        const SizedBox(height: 14),
        SegmentedButton<String>(segments: const [
          ButtonSegment(value: 'Nakit', label: Text('Nakit')),
          ButtonSegment(value: 'Havale/EFT', label: Text('Havale')),
          ButtonSegment(value: 'Karma', label: Text('Karma')),
        ], selected: {method}, onSelectionChanged: (s) => setState(() {
          method = s.first;
          if (method == 'Havale/EFT' && bank.text.isEmpty) { bank.text = cash.text; }
          if (method == 'Nakit' && cash.text.isEmpty) { cash.text = bank.text; }
        })),
        const SizedBox(height: 12),
        if (method != 'Havale/EFT') TextField(key: const ValueKey('pay-cash'), controller: cash,
            keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: field('Nakit tutar')),
        if (method == 'Karma') const SizedBox(height: 10),
        if (method != 'Nakit') TextField(key: const ValueKey('pay-bank'), controller: bank,
            keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: field('Havale/EFT tutar')),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          ChoiceChip(label: const Text('Ödeme'), selected: kind == 'Ödeme', onSelected: (_) => setState(() => kind = 'Ödeme')),
          ChoiceChip(label: const Text('Avans'), selected: kind == 'Avans', onSelected: (_) => setState(() => kind = 'Avans')),
          ActionChip(avatar: const Icon(Icons.event, size: 17), label: Text(WorkFormat.day(paidOn)), onPressed: pickDay),
        ]),
        const SizedBox(height: 12),
        TextField(controller: note, maxLength: 200, decoration: const InputDecoration(labelText: 'Not (isteğe bağlı)')),
        if (error != null) Padding(padding: const EdgeInsets.only(bottom: 8),
            child: Text(error!, style: TextStyle(color: nc.danger, fontWeight: FontWeight.w600))),
        FilledButton(onPressed: save, child: const Text('Kaydet')),
      ])),
    );
  }
}

