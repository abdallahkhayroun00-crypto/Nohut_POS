import 'package:flutter/material.dart';

import 'brand.dart';
import 'finance_logic.dart';
import 'market_prices.dart';
import 'operations_ui.dart' show askFields, EditState;
import 'order_reporting.dart';
import 'pos_logic.dart';

/// Owner-facing operational finance UI. This is a local management estimate,
/// not a fiscal invoice, bank transfer, inventory/COGS, or tax calculation.
class FinancePanel extends StatefulWidget {
  const FinancePanel({
    super.key, required this.state, required this.edit, this.onlineWarning,
  });
  final Json state;
  final EditState edit;
  final String? onlineWarning;

  @override
  State<FinancePanel> createState() => _FinancePanelState();
}

class _FinancePanelState extends State<FinancePanel> {
  String tab = 'Genel Bakış';
  String month = _today().substring(0, 7);
  String day = _today();
  String week = weekStartOf(_today());

  static String _today() => istanbulDay(DateTime.now().toUtc());
  static String _try(double value) => value.toStringAsFixed(2);
  static String _tl(int cents) => (cents / 100).toStringAsFixed(2);
  static String _quantity(int milli) {
    var text = (milli / 1000).toStringAsFixed(3);
    while (text.contains('.') && text.endsWith('0')) {
      text = text.substring(0, text.length - 1);
    }
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
    return text;
  }

  static double _decimal(String value, {bool allowZero = false}) {
    final n = double.tryParse(value.trim().replaceAll(',', '.'));
    if (n == null || !n.isFinite || n < (allowZero ? 0 : 0.001) ||
        n > 100000000) {
      throw const FormatException('Miktar veya fiyat geçersiz.');
    }
    return n;
  }
  static int _price(String text, {bool allowZero = false}) {
    final v = _decimal(text, allowZero: allowZero);
    final cents = (v * 100).round();
    if (cents == 0 && !allowZero) {
      throw const FormatException('Fiyat en az 0,01 ₺ olmalı.');
    }
    return cents;
  }
  static int _qty(String text) {
    final milli = (_decimal(text) * 1000).round();
    if (milli < 1) throw const FormatException('Miktar 0 olamaz.');
    return milli;
  }

  void _shiftMonth(int delta) {
    final d = DateTime.parse(month + '-01');
    final next = DateTime(d.year, d.month + delta);
    setState(() {
      month = next.toIso8601String().substring(0, 7);
    });
  }

  void _shiftDay(int delta) {
    final d = DateTime.parse(day).add(Duration(days: delta));
    setState(() => day = d.toIso8601String().substring(0, 10));
  }

  void _shiftWeek(int delta) {
    final d = DateTime.parse(week).add(Duration(days: delta * 7));
    setState(() => week = d.toIso8601String().substring(0, 10));
  }

  Widget _heading(String text, {Widget? action}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      children: [
        Expanded(child: Text(text,
          style: Theme.of(context).textTheme.titleLarge)),
        if (action != null) action,
      ],
    ),
  );

  Widget _metric(String name, String value, IconData icon, {
    bool important = false,
  }) => SizedBox(
    width: 205,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: NohutBrand.green, size: 21),
            const SizedBox(height: 10),
            Text(name, style: const TextStyle(
              color: NohutBrand.muted, fontSize: 12)),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value,
                style: TextStyle(fontSize: important ? 25 : 20,
                  color: NohutBrand.green,
                  fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _notice(String message) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xfffff5e4),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(message, style: const TextStyle(
      color: Color(0xff795832), fontSize: 12)),
  );

  void _error(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _materialForm([Json? existing]) async {
    final tracked = trackedMarketProducts(widget.state);
    final byKey = <String, Json>{
      for (final p in tracked)
        if ((p['key'] ?? '').toString().isNotEmpty)
          p['key'].toString(): p,
    };
    String chosen = existing?['marketKey'] is String &&
      byKey.containsKey(existing!['marketKey']) ?
      existing['marketKey'] as String : '__manual__';
    String unit = (existing?['unit'] ?? 'kg').toString();
    String method = (existing?['paymentMethod'] ?? 'Nakit').toString();
    final date = TextEditingController(text: (existing?['date'] ?? day).toString());
    final name = TextEditingController(text: (existing?['title'] ?? '').toString());
    final quantity = TextEditingController(text: existing == null ?
      '1' : _quantity(existing['quantityMilli'] as int));
    final price = TextEditingController(text: existing == null ?
      '' : _tl(existing['pricePerUnitCents'] as int));
    final notes = TextEditingController(text: (existing?['note'] ?? '').toString());
    String? error;
    // The market quote is per package, but the input price is per selected
    // base unit (e.g. 100 GR -> kg), preventing 100x purchase errors.
    void selectQuote(String key) {
      chosen = key;
      final trackedItem = byKey[key];
      if (trackedItem == null) return;
      final quote = marketUnitQuote(trackedItem);
      name.text = (trackedItem['title'] ?? '').toString();
      if (quote != null) {
        unit = quote.unit;
        price.text = _tl(quote.priceCents);
      }
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, changeDialog) {
          int? total;
          try {
            total = materialTotalCents(_qty(quantity.text),
              _price(price.text));
          } on FormatException { /* show blank total while typing */ }
          final market = byKey[chosen];
          return AlertDialog(
            title: Text(existing == null ?
              'Günlük Malzeme Alımı' : 'Malzeme Kaydını Düzenle'),
            content: SizedBox(
              width: 530,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DropdownButtonFormField<String>(
                      key: ValueKey('market-choice-' + chosen),
                      initialValue: chosen,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Market Fiyat Takibinden Seç'),
                      items: [
                        const DropdownMenuItem(
                          value: '__manual__', child: Text('Manuel Ürün Ekle')),
                        for (final entry in tracked)
                          if (byKey.containsKey((entry['key'] ?? '').toString()))
                            DropdownMenuItem(
                              value: entry['key'].toString(),
                              child: Text((entry['title'] ?? '').toString(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            ),
                      ],
                      onChanged: (v) => changeDialog(() {
                        selectQuote(v ?? '__manual__');
                      }),
                    ),
                    if (market != null) ...[
                      const SizedBox(height: 7),
                      Text(
                        (market['market'] ?? '').toString() + ' · ' +
                        (market['depotName'] ?? '').toString() +
                        ' · Market fiyatı: ' +
                        (market['priceCents'] is int ?
                          formatTry(market['priceCents'] as int) : '—') +
                        ' / ' + (market['unit'] ?? '').toString(),
                        style: const TextStyle(
                          color: NohutBrand.muted, fontSize: 12)),
                    ],
                    const SizedBox(height: 12),
                    TextField(controller: date,
                      decoration: const InputDecoration(
                        labelText: 'Alım Tarihi (YYYY-MM-DD)')),
                    const SizedBox(height: 10),
                    TextField(controller: name,
                      decoration: const InputDecoration(
                        labelText: 'Ürün / Malzeme Adı')),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      key: ValueKey('purchase-unit-' + unit),
                      initialValue: unit,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Miktar Birimi'),
                      items: [
                        for (final u in financeUnits)
                          DropdownMenuItem(value: u, child: Text(u)),
                      ],
                      onChanged: (v) => changeDialog(() {
                        if (v == null || v == unit) return;
                        // Changing unit removes a stale price to prevent
                        // treating a kg price as a per-piece price.
                        unit = v;
                        price.clear();
                      }),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: quantity,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                      onChanged: (_) => changeDialog(() {}),
                      decoration: InputDecoration(
                        labelText: 'Kaç ' + unit + '? (ör. 2,5)')),
                    const SizedBox(height: 10),
                    TextField(
                      controller: price,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                      onChanged: (_) => changeDialog(() {}),
                      decoration: InputDecoration(
                        labelText: 'Gerçek alış fiyatı (₺ / ' + unit + ')',
                        helperText: 'Hatalı market fiyatını burada düzeltin. '
                          'Market Fiyat Takibi değişmez.')),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: method,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Ödeme'),
                      items: [
                        for (final value in financeMethods)
                          DropdownMenuItem(value: value, child: Text(value)),
                      ],
                      onChanged: (v) => changeDialog(() {
                        method = v ?? method;
                      }),
                    ),
                    const SizedBox(height: 10),
                    TextField(controller: notes, maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Not (isteğe bağlı)')),
                    const SizedBox(height: 10),
                    Text('Toplam: ' + (total == null ? '—' : formatTry(total)),
                      style: const TextStyle(fontWeight: FontWeight.w800,
                        color: NohutBrand.green, fontSize: 19)),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(error!,
                          style: const TextStyle(color: Colors.red)),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Vazgeç')),
              FilledButton(
                key: const ValueKey('finance-material-save'),
                onPressed: () {
                  try {
                    final marketQuote = byKey[chosen];
                    final ok = widget.edit((state) => saveMaterialPurchase(
                      state,
                      id: existing?['id'] as int?,
                      date: date.text.trim(),
                      title: name.text.trim(),
                      unit: unit,
                      quantityMilli: _qty(quantity.text),
                      pricePerUnitCents: _price(price.text),
                      marketKey: marketQuote == null ? '' : chosen,
                      market: marketQuote == null ? '' :
                        (marketQuote['market'] ?? '').toString() + ' · ' +
                        (marketQuote['depotName'] ?? '').toString(),
                      marketUnit: (marketQuote?['unit'] ?? '').toString(),
                      referencePriceCents: marketQuote?['priceCents'] as int?,
                      paymentMethod: method,
                      note: notes.text,
                    ));
                    if (ok) Navigator.pop(dialogContext);
                  } on FormatException catch (e) {
                    changeDialog(() => error = e.message);
                  }
                },
                child: const Text('Kaydet'),
              ),
            ],
          );
        },
      ),
    );
    // Match the repo's existing dialog controller disposal timing.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    for (final c in [date, name, quantity, price, notes]) {
      c.dispose();
    }
  }

  Future<void> _voidMaterial(Json item) async {
    final answer = await askFields(context, 'Malzeme İptal',
      [('İptal nedeni', '')], validate: (v) =>
        v[0].trim().isEmpty ? 'İptal nedeni gerekli' : null);
    if (answer == null) return;
    widget.edit((s) =>
      voidMaterialPurchase(s, item['id'] as int, answer.first));
  }

  Widget _materials() {
    final list = financeRows(widget.state, 'materials')
      .where((p) => p['date'] == day)
      .toList()..sort((a, b) => (b['id'] as int).compareTo(a['id'] as int));
    final sum = list.where((p) => p['voided'] != true)
      .fold<int>(0, (v, p) => v + (p['totalCents'] as int));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Günlük Malzeme Alımı',
          action: FilledButton.icon(
            key: const ValueKey('finance-new-material'),
            onPressed: () => _materialForm(),
            icon: const Icon(Icons.add),
            label: const Text('Malzeme Ekle'))),
        _notice('Market Fiyat Takibi fiyatları referanstır. '
          'Gerçek satın alma tutarı ve miktarı kaydedilir; '
          'takip edilen fiyatlar değişmez.'),
        const SizedBox(height: 10),
        Row(
          children: [
            IconButton(
              tooltip: 'Önceki gün', onPressed: () => _shiftDay(-1),
              icon: const Icon(Icons.chevron_left)),
            Text(day, style: const TextStyle(fontWeight: FontWeight.w700)),
            IconButton(
              tooltip: 'Sonraki gün', onPressed: () => _shiftDay(1),
              icon: const Icon(Icons.chevron_right)),
            const Spacer(),
            Text('Günlük toplam: ' + formatTry(sum),
              style: const TextStyle(fontWeight: FontWeight.w800,
                color: NohutBrand.green)),
          ],
        ),
        if (list.isEmpty)
          const Card(child: Padding(padding: EdgeInsets.all(20),
            child: Text('Bu gün malzeme alımı kaydedilmedi.'))),
        for (final p in list)
          Card(child: ListTile(
            title: Text((p['title'] ?? '').toString() +
              (p['voided'] == true ? ' · İPTAL' : '')),
            subtitle: Text(
              _quantity(p['quantityMilli'] as int) + ' ' +
              p['unit'].toString() + ' × ' +
              formatTry(p['pricePerUnitCents'] as int) +
              (p['market'] == '' ? '' : '\n' + p['market'].toString()) +
              '\n' + (p['paymentMethod'] ?? '').toString()),
            isThreeLine: true,
            trailing: Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(formatTry(p['totalCents'] as int),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
                if (p['voided'] != true)
                  PopupMenuButton<String>(
                    tooltip: 'Malzeme işlemleri',
                    onSelected: (action) =>
                      action == 'edit' ? _materialForm(p) : _voidMaterial(p),
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'edit', child: Text('Düzenle')),
                      PopupMenuItem(value: 'void', child: Text('İptal Et')),
                    ],
                  ),
              ],
            ),
          )),
      ],
    );
  }

  Future<void> _payrollForm([Json? current]) async {
    final people = asMaps(widget.state['employees']);
    if (people.isEmpty) {
      _error('Ayarlar → Personel üzerinden çalışan ekleyin.');
      return;
    }
    int selected = current?['employeeId'] is int ?
      current!['employeeId'] as int : people.first['id'] as int;
    final hours = TextEditingController(text: current == null ?
      '0' : _try((current['workedMinutes'] as int) / 60));
    final bonus = TextEditingController(text: current == null ?
      '0' : _tl(current['bonusCents'] as int));
    final advance = TextEditingController(text: current == null ?
      '0' : _tl(current['advanceCents'] as int));
    bool paid = current?['paid'] == true;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, changeDialog) {
          final employee = people.where((p) => p['id'] == selected).first;
          final payType = (employee['payType'] ?? '').toString();
          final rate = employee['payRateCents'];
          final configured = rate is int && rate > 0 &&
            ['Saatlik', 'Haftalık Sabit'].contains(payType);
          final hourly = payType == 'Saatlik';
          return AlertDialog(
            title: Text('Haftalık Maaş · ' + week),
            content: SizedBox(
              width: 470,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DropdownButtonFormField<int>(
                      initialValue: selected,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Personel (Ayarlar bağlantısı)'),
                      items: [
                        for (final p in people)
                          DropdownMenuItem(
                            value: p['id'] as int,
                            child: Text((p['name'] ?? '').toString())),
                      ],
                      onChanged: current != null ? null : (v) =>
                        changeDialog(() => selected = v ?? selected),
                    ),
                    const SizedBox(height: 12),
                    Text(configured ?
                      payType + ' · ' + formatTry(rate) :
                      'Önce Ayarlar → Personel → Düzenle: Ücret girin.',
                      style: TextStyle(
                        color: configured ? NohutBrand.green : Colors.red,
                        fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),
                    if (hourly) ...[
                      TextField(controller: hours,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Haftalık çalışma saati')),
                      const SizedBox(height: 10),
                    ],
                    TextField(controller: bonus,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Prim / Ek ödeme (₺)')),
                    const SizedBox(height: 10),
                    TextField(controller: advance,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Önceden verilen avans (₺)',
                        helperText: 'Avans giderden tekrar düşülmez; '
                          'yalnızca kalan ödeme tutarını azaltır.')),
                    const SizedBox(height: 10),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: paid,
                      title: const Text('Maaş ödendi'),
                      subtitle: const Text(
                        'Yalnızca kayıt; banka/kasadan para çekmez.'),
                      onChanged: current?['paid'] == true ? null : (v) =>
                        changeDialog(() => paid = v ?? false),
                    ),
                    if (error != null)
                      Text(error!, style: const TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Vazgeç')),
              FilledButton(
                key: const ValueKey('finance-payroll-save'),
                onPressed: !configured ? null : () {
                  try {
                    final minutes = hourly ?
                      (_decimal(hours.text, allowZero: true) * 60).round() : 0;
                    final ok = widget.edit((state) => saveWeeklyPayroll(state,
                      employeeId: selected,
                      weekStart: week,
                      workedMinutes: minutes,
                      bonusCents: _price(bonus.text, allowZero: true),
                      advanceCents: _price(advance.text, allowZero: true),
                      paid: paid));
                    if (ok) Navigator.pop(dialogContext);
                  } on FormatException catch (e) {
                    changeDialog(() => error = e.message);
                  }
                },
                child: const Text('Kaydet'),
              ),
            ],
          );
        },
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    hours.dispose(); bonus.dispose(); advance.dispose();
  }

  Widget _payroll() {
    final list = financeRows(widget.state, 'weeklyPayroll')
      .where((p) => p['weekStart'] == week)
      .toList();
    final total = list.fold<int>(0, (v, p) => v + (p['grossCents'] as int));
    final end = weekEndOf(week);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Haftalık Personel Maaşları',
          action: FilledButton.icon(
            key: const ValueKey('finance-new-payroll'),
            onPressed: () => _payrollForm(),
            icon: const Icon(Icons.add),
            label: const Text('Haftalık Maaş Ekle'))),
        _notice('Maaş oranları Ayarlar → Personel kaydından gelir. '
          'Saatler otomatik tahmin edilmez. Haftalık gider, '
          'haftanın bittiği ayda bir kez sayılır. SGK ayrı aylık giderdir.'),
        const SizedBox(height: 10),
        Row(children: [
          IconButton(tooltip: 'Önceki hafta', icon: const Icon(Icons.chevron_left),
            onPressed: () => _shiftWeek(-1)),
          Expanded(child: Text(week + ' → ' + end,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700))),
          IconButton(tooltip: 'Sonraki hafta', icon: const Icon(Icons.chevron_right),
            onPressed: () => _shiftWeek(1)),
        ]),
        _metric('Haftalık hak ediş', formatTry(total),
          Icons.groups_outlined),
        if (list.isEmpty)
          const Card(child: Padding(padding: EdgeInsets.all(20),
            child: Text('Bu hafta için maaş kaydı yok.'))),
        for (final p in list)
          Card(child: ListTile(
            title: Text((p['employeeName'] ?? '').toString()),
            subtitle: Text(
              (p['payType'] ?? '').toString() +
              ' · ' + formatTry(p['rateCents'] as int) +
              (p['payType'] == 'Saatlik' ?
                ' × ' + _quantity((p['workedMinutes'] as int) * 1000 ~/ 60) +
                  ' saat' : '') +
              '\nPrim: ' + formatTry(p['bonusCents'] as int) +
              ' · Avans: ' + formatTry(p['advanceCents'] as int) +
              '\nKalan ödeme: ' + formatTry(p['payableCents'] as int) +
              (p['paid'] == true ? ' · Ödendi' : ' · Ödenmedi')),
            isThreeLine: true,
            trailing: Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(formatTry(p['grossCents'] as int),
                  style: const TextStyle(fontWeight: FontWeight.w800)),
                if (p['paid'] != true)
                  PopupMenuButton<String>(
                    tooltip: 'Maaş işlemleri',
                    onSelected: (action) {
                      if (action == 'edit') {
                        _payrollForm(p);
                      } else {
                        widget.edit((s) => markWeeklyPayrollPaid(
                          s, p['employeeId'] as int, week));
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'edit', child: Text('Düzenle')),
                      PopupMenuItem(value: 'paid',
                        child: Text('Ödendi Olarak İşaretle')),
                    ],
                  ),
              ],
            ),
          )),
      ],
    );
  }

  Future<void> _fixedForm([Json? old]) async {
    final answers = await askFields(context,
      old == null ? 'Aylık Sabit Gider Ekle' : 'Sabit Gider Düzenle',
      [
        ('Kategori', (old?['category'] ?? 'Kira').toString()),
        ('Gider Adı', (old?['name'] ?? '').toString()),
        ('Aylık Tutar (₺)', old == null ? '' :
          _tl(old['amountCents'] as int)),
        ('Başlangıç Ayı (YYYY-MM)',
          (old?['startMonth'] ?? month).toString()),
        ('Ödeme Günü (1–28)', (old?['dueDay'] ?? 1).toString()),
        ('Aktif', old?['active'] == false ? 'Hayır' : 'Evet'),
      ],
      choices: {
        0: financeFixedCategories,
        5: ['Evet', 'Hayır'],
      },
      validate: (values) {
        if (values[1].trim().isEmpty ||
            !validFinanceMonth(values[3]) ||
            (int.tryParse(values[4]) ?? 0) < 1 ||
            (int.tryParse(values[4]) ?? 29) > 28) {
          return 'Ad, ay veya ödeme günü geçersiz.';
        }
        try { _price(values[2]); } on FormatException catch (e) {
          return e.message;
        }
        return null;
      },
    );
    if (answers == null) return;
    widget.edit((state) => saveMonthlyFixed(state,
      id: old?['id'] as int?,
      category: answers[0],
      name: answers[1],
      amountCents: _price(answers[2]),
      startMonth: answers[3],
      dueDay: int.parse(answers[4]),
      active: answers[5] == 'Evet',
    ));
  }

  Widget _fixed() {
    final fixed = financeRows(widget.state, 'monthlyFixed');
    final payments = financeRows(widget.state, 'fixedPayments');
    final due = fixed.where((f) =>
      f['active'] == true &&
      (f['startMonth'] as String).compareTo(month) <= 0).toList();
    final total = due.fold<int>(0, (v, f) => v + (f['amountCents'] as int));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Aylık Sabit Giderler',
          action: FilledButton.icon(
            onPressed: () => _fixedForm(),
            icon: const Icon(Icons.add),
            label: const Text('Sabit Gider Ekle'))),
        _notice('Kira, SGK, Muhasebe gibi aylık tutarlar otomatik '
          'tahakkuk eder. Ödendi işareti sadece takip içindir; '
          'kasa bakiyesine işlem göndermez.'),
        const SizedBox(height: 10),
        _metric('Bu ay tahakkuk eden', formatTry(total),
          Icons.calendar_month_outlined),
        for (final f in fixed)
          Card(child: ListTile(
            title: Text((f['name'] ?? '').toString()),
            subtitle: Text(
              f['category'].toString() + ' · ' +
              'Her ayın ' + f['dueDay'].toString() + '. günü' +
              ' · Başlangıç: ' + f['startMonth'].toString() +
              (f['active'] == false ? ' · Pasif' : '')),
            trailing: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(formatTry(f['amountCents'] as int),
                  style: const TextStyle(fontWeight: FontWeight.w800)),
                if (f['active'] == true &&
                    (f['startMonth'] as String).compareTo(month) <= 0)
                  TextButton(
                    onPressed: () {
                      final paid = payments.any((r) =>
                        r['templateId'] == f['id'] && r['month'] == month);
                      widget.edit((s) => markMonthlyFixedPaid(
                        s, f['id'] as int, month, !paid));
                    },
                    child: Text(payments.any((r) =>
                      r['templateId'] == f['id'] && r['month'] == month) ?
                      'Ödendi ✓' : 'Ödendi İşaretle'),
                  ),
                IconButton(
                  tooltip: 'Sabit gider düzenle',
                  onPressed: () => _fixedForm(f),
                  icon: const Icon(Icons.edit_outlined)),
              ],
            ),
          )),
      ],
    );
  }

  Future<void> _otherForm() async {
    final answers = await askFields(context, 'Diğer Gider Ekle', [
      ('Kategori', 'Yol / Nakliye'),
      ('Gider Adı', ''),
      ('Tarih (YYYY-MM-DD)', day),
      ('Tutar (₺)', ''),
      ('Ödeme', 'Nakit'),
    ],
      choices: {0: financeOtherCategories, 4: financeMethods},
      validate: (v) {
        if (v[1].trim().isEmpty || !validBusinessDate(v[2])) {
          return 'Ad veya tarih geçersiz.';
        }
        try { _price(v[3]); } on FormatException catch (e) {
          return e.message;
        }
        return null;
      },
    );
    if (answers == null) return;
    widget.edit((s) => saveOtherExpense(s,
      category: answers[0], name: answers[1], day: answers[2],
      amountCents: _price(answers[3]), paymentMethod: answers[4]));
  }

  Widget _other() {
    final items = financeRows(widget.state, 'other')
      .where((r) => (r['date'] as String? ?? '').startsWith(month))
      .toList()..sort((a, b) =>
        (b['date'] as String).compareTo(a['date'] as String));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Diğer Günlük Giderler',
          action: FilledButton.icon(
            onPressed: _otherForm, icon: const Icon(Icons.add),
            label: const Text('Gider Ekle'))),
        for (final p in items)
          Card(child: ListTile(
            title: Text(p['name'].toString() +
              (p['voided'] == true ? ' · İPTAL' : '')),
            subtitle: Text(p['date'].toString() + ' · ' +
              p['category'].toString() + ' · ' +
              p['paymentMethod'].toString()),
            trailing: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              children: [
                Text(formatTry(p['amountCents'] as int)),
                if (p['voided'] != true)
                  IconButton(
                    icon: const Icon(Icons.cancel_outlined),
                    tooltip: 'Gider iptal et',
                    onPressed: () async {
                      final answer = await askFields(context, 'Gider İptal',
                        [('İptal nedeni', '')],
                        validate: (v) => v.first.isEmpty ?
                          'İptal nedeni gerekli' : null);
                      if (answer != null) {
                        widget.edit((s) => voidOtherExpense(
                          s, p['id'] as int, answer.first));
                      }
                    },
                  ),
              ],
            ),
          )),
        if (items.isEmpty) const Card(
          child: Padding(padding: EdgeInsets.all(20),
            child: Text('Bu ay diğer gider kaydı yok.'))),
      ],
    );
  }

  Widget _overview() {
    final report = financeMonthSummary(widget.state, month);
    final breakdown = <(String, int)>[
      ('Günlük Malzeme', report.materialsCents),
      ('Haftalık Maaşlar', report.payrollCents),
      ('Aylık Sabit Giderler', report.fixedCents),
      ('Diğer Giderler', report.otherCents),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Aylık Gelir · Gider'),
        if (widget.onlineWarning != null)
          _notice(widget.onlineWarning!),
        const SizedBox(height: 8),
        Wrap(
          spacing: 4, runSpacing: 4,
          children: [
            _metric('Yerel Tahsilat (Masa / Gel-Al)',
              formatTry(report.localReceiptsCents), Icons.payments_outlined),
            _metric('Online Tahmini Net',
              formatTry(report.onlineKnownNetCents),
              Icons.delivery_dining_outlined),
            _metric('Toplam Gider',
              formatTry(report.totalExpensesCents),
              Icons.trending_down_outlined),
            _metric('Tahmini Faaliyet Farkı',
              report.estimateCents == null ? '—' :
                formatTry(report.estimateCents!),
              Icons.account_balance_wallet_outlined,
              important: true),
          ],
        ),
        const SizedBox(height: 12),
        if (report.missingOnlineRate)
          _notice('Bazı online siparişlerin komisyon oranı bilinmiyor: ' +
            formatTry(report.onlineUnpricedGrossCents) +
            ' brüt. Tahmini faaliyet farkı bilinçli olarak gizlendi. '
            'Raporlar → Genel Bakış üzerinden oranları girin.'),
        const SizedBox(height: 10),
        _notice('Yönetim amaçlı yaklaşık hesap: yerel gerçek tahsilat + '
          'kaydedilmiş online siparişlerin tahmini neti − kaydedilen '
          'malzeme alımları, haftalık maaş tahakkuku ve sabit giderler. '
          'Stok tüketimi, vergi, gerçek banka mutabakatı ve eksik '
          'entegrasyonlar hesaplanmadı; yasal kâr değildir.'),
        const SizedBox(height: 12),
        Card(child: Padding(
          padding: const EdgeInsets.all(17),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Gider Dağılımı',
                style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 10),
              for (final item in breakdown) ...[
                Row(children: [
                  Expanded(child: Text(item.$1)),
                  Text(formatTry(item.$2),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
                const SizedBox(height: 5),
                LinearProgressIndicator(
                  value: report.totalExpensesCents > 0 ?
                    item.$2 / report.totalExpensesCents : 0,
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(9),
                  backgroundColor: const Color(0xffEDF1EC),
                  color: NohutBrand.green,
                ),
                const SizedBox(height: 13),
              ],
            ],
          ),
        )),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Finans', style: Theme.of(context).textTheme.headlineSmall),
      const Text('Günlük alımlar · Haftalık maaşlar · Aylık giderler',
        style: TextStyle(color: NohutBrand.muted)),
      const SizedBox(height: 14),
      Card(child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          IconButton(icon: const Icon(Icons.chevron_left),
            tooltip: 'Önceki ay',
            onPressed: () => _shiftMonth(-1)),
          Expanded(child: Text(month,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 19,
              color: NohutBrand.green, fontWeight: FontWeight.w800))),
          IconButton(icon: const Icon(Icons.chevron_right),
            tooltip: 'Sonraki ay',
            onPressed: () => _shiftMonth(1)),
        ]),
      )),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8, runSpacing: 8,
        children: [
          for (final name in const [
            'Genel Bakış', 'Günlük Malzeme',
            'Haftalık Maaşlar', 'Sabit Giderler', 'Diğer Giderler',
          ])
            ChoiceChip(label: Text(name), selected: tab == name,
              onSelected: (_) => setState(() => tab = name)),
        ],
      ),
      const SizedBox(height: 12),
      if (tab == 'Genel Bakış') _overview(),
      if (tab == 'Günlük Malzeme') _materials(),
      if (tab == 'Haftalık Maaşlar') _payroll(),
      if (tab == 'Sabit Giderler') _fixed(),
      if (tab == 'Diğer Giderler') _other(),
    ],
  );
}
