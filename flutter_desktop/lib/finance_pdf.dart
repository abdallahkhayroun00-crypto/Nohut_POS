import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'finance_logic.dart';
import 'market_prices.dart';
import 'operations.dart';
import 'order_reporting.dart';
import 'platform_net.dart';
import 'pos_logic.dart';

/// The report has the same three types as the print-ready Nohut designs.
/// Records come exclusively from the current local POS snapshot.
enum FinancePdfKind { monthly, materials, payroll }

class FinancePdfRequest {
  const FinancePdfRequest({
    required this.kind,
    required this.month,
    required this.day,
    required this.weekStart,
  });
  final FinancePdfKind kind;
  final String month, day, weekStart;

  String get title => switch (kind) {
    FinancePdfKind.monthly => 'Aylık Finans Özeti',
    FinancePdfKind.materials => 'Malzeme Alım Raporu',
    FinancePdfKind.payroll => 'Maaş & Sabit Giderler',
  };

  String get suggestedName {
    final date = switch (kind) {
      FinancePdfKind.monthly => month,
      FinancePdfKind.materials => day,
      FinancePdfKind.payroll => weekStart,
    };
    final prefix = switch (kind) {
      FinancePdfKind.monthly => 'Aylik_Finans',
      FinancePdfKind.materials => 'Gunluk_Malzeme',
      FinancePdfKind.payroll => 'Haftalik_Maas',
    };
    return 'Nohut_' + prefix + '_' + date + '.pdf';
  }

  void validate() {
    if (!validFinanceMonth(month) || !validBusinessDate(day) ||
        weekStartOf(weekStart) != weekStart) {
      throw const FormatException(
        'PDF rapor tarihi geçersiz. Ay, gün ve pazartesi tarihi girin.');
    }
  }
}

final _forest = PdfColor.fromInt(0xff173f33);
final _deep = PdfColor.fromInt(0xff14392e);
final _green = PdfColor.fromInt(0xff27714e);
final _pale = PdfColor.fromInt(0xffeff4ef);
final _paper = PdfColor.fromInt(0xfffaf9f5);
final _ink = PdfColor.fromInt(0xff253d33);
final _muted = PdfColor.fromInt(0xff637a70);
final _line = PdfColor.fromInt(0xffdce6dc);
final _coral = PdfColor.fromInt(0xffd9785f);

const _monthNames = <String>[
  '', 'Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran',
  'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık',
];

String _monthName(String month) {
  if (!validFinanceMonth(month)) return month;
  final parts = month.split('-');
  return _monthNames[int.parse(parts[1])] + ' ' + parts[0];
}

String _dayName(String day) {
  if (!validBusinessDate(day)) return day;
  final p = day.split('-');
  return p[2] + ' ' + _monthNames[int.parse(p[1])] + ' ' + p[0];
}

String _amount(int cents) {
  final abs = cents.abs();
  final whole = (abs ~/ 100).toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => '.');
  final decimals = (abs % 100).toString().padLeft(2, '0');
  return (cents < 0 ? '-' : '') + whole + ',' + decimals + ' ₺';
}

String _quantity(Object? count) {
  if (count is! int) return '—';
  var value = (count / 1000).toStringAsFixed(3);
  while (value.contains('.') && value.endsWith('0')) {
    value = value.substring(0, value.length - 1);
  }
  return value.endsWith('.') ? value.substring(0, value.length - 1) : value;
}

String _hours(Object? minutes) {
  if (minutes is! int) return '—';
  final count = minutes / 60;
  return count == count.roundToDouble()
    ? count.toStringAsFixed(0) + ' saat'
    : count.toStringAsFixed(2).replaceAll('.', ',') + ' saat';
}

int _cents(Json entry, String field) =>
  entry[field] is int ? entry[field] as int : 0;

bool _isInMonth(String stamp, String month) {
  final parsed = DateTime.tryParse(stamp);
  return parsed != null && istanbulDay(parsed).startsWith(month);
}

pw.Text _text(String value, {double size = 9, bool bold = false,
    PdfColor? color, pw.TextAlign? align}) => pw.Text(
      value, textAlign: align,
      style: pw.TextStyle(fontSize: size,
        fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        color: color ?? _ink));

pw.Widget _header(String title, String section, String period) =>
  pw.Container(
    color: _forest,
    padding: const pw.EdgeInsets.fromLTRB(22, 17, 22, 18),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _text('NOHUT FALAFEL', size: 15,
                  color: PdfColors.white, bold: true),
                pw.SizedBox(height: 3),
                _text('FİNANS RAPORLARI', size: 7.5,
                  color: PdfColor.fromInt(0xffc0d4c9), bold: true),
              ],
            ),
            pw.Container(
              width: 31, height: 31,
              decoration: pw.BoxDecoration(
                shape: pw.BoxShape.circle,
                border: pw.Border.all(color: PdfColors.white, width: 1.7)),
              child: pw.Center(
                child: _text('N', size: 19,
                  color: PdfColors.white, bold: true)),
            ),
          ],
        ),
        pw.SizedBox(height: 13),
        _text(title, size: 20, color: PdfColors.white, bold: true),
        pw.SizedBox(height: 7),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            _text(section, size: 8.2,
              color: PdfColor.fromInt(0xffd0e1d6)),
            _text(period, size: 8.7,
              color: PdfColors.white, bold: true),
          ],
        ),
      ],
    ),
  );

pw.Widget _footer(pw.Context ctx, String descriptor) => pw.Column(
  children: [
    pw.Divider(color: _line),
    pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            _text('NOHUT FALAFEL', size: 7, bold: true, color: _forest),
            _text('Yönetim amaçlı POS raporu · Resmî mali belge değildir.',
              size: 6.3, color: _muted),
          ],
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            _text(descriptor, size: 7, color: _muted),
            _text(ctx.pageNumber.toString() + ' / ' +
              ctx.pagesCount.toString(), size: 7, color: _forest, bold: true),
          ],
        ),
      ],
    ),
  ],
);

pw.Widget _metric(String label, String amount, String detail,
    {PdfColor? accent}) =>
  pw.Expanded(
    child: pw.Container(
      padding: const pw.EdgeInsets.all(11),
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        border: pw.Border.all(color: _line),
        borderRadius: pw.BorderRadius.circular(10)),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Container(width: 22, height: 4,
            decoration: pw.BoxDecoration(
              color: accent ?? _forest,
              borderRadius: pw.BorderRadius.circular(4))),
          pw.SizedBox(height: 7),
          _text(label, size: 7, color: _muted),
          pw.SizedBox(height: 5),
          _text(amount, size: 13.2, bold: true, color: accent ?? _forest),
          pw.SizedBox(height: 4),
          _text(detail, size: 6.5, color: _muted),
        ],
      ),
    ),
  );

pw.Widget _section(String heading, {String? detail}) => pw.Padding(
  padding: const pw.EdgeInsets.only(top: 12, bottom: 8),
  child: pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: [
      _text(heading, size: 13.5, bold: true, color: _forest),
      if (detail != null) _text(detail, size: 7.2, color: _muted),
    ],
  ),
);

pw.Widget _notice(String text) => pw.Container(
  width: double.infinity,
  padding: const pw.EdgeInsets.all(11),
  margin: const pw.EdgeInsets.only(top: 10),
  decoration: pw.BoxDecoration(
    color: _pale,
    borderRadius: pw.BorderRadius.circular(9)),
  child: _text(text, size: 7.5, color: _forest),
);

pw.Widget _table(List<String> headers, List<List<String>> data,
    {Map<int, pw.TableColumnWidth>? widths}) {
  if (data.isEmpty) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(13),
      decoration: pw.BoxDecoration(
        color: _pale, borderRadius: pw.BorderRadius.circular(8)),
      child: _text('Seçilen dönem için kayıt bulunamadı.',
        size: 8, color: _muted),
    );
  }
  return pw.Table.fromTextArray(
    headers: headers,
    data: data,
    columnWidths: widths,
    border: pw.TableBorder(
      bottom: pw.BorderSide(color: _line, width: 0.6)),
    headerCount: 1,
    headerStyle: pw.TextStyle(
      color: PdfColors.white, fontSize: 7, fontWeight: pw.FontWeight.bold),
    headerDecoration: pw.BoxDecoration(color: _forest),
    cellStyle: pw.TextStyle(color: _ink, fontSize: 7.3),
    cellPadding: const pw.EdgeInsets.symmetric(
      horizontal: 7, vertical: 8),
    oddRowDecoration: pw.BoxDecoration(color: _pale),
    cellAlignment: pw.Alignment.centerLeft,
  );
}

pw.Widget _bar(String label, int amount, int maximum) {
  final ratio = maximum > 0 ? (amount / maximum).clamp(0, 1).toDouble() : 0.0;
  return pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 8),
    child: pw.Row(
      children: [
        pw.SizedBox(width: 127, child: _text(label, size: 8)),
        pw.SizedBox(width: 8),
        pw.Expanded(child: pw.Row(children: [
          pw.Container(width: ratio * 165, height: 6,
            color: _forest),
          pw.Container(width: (1 - ratio) * 165, height: 6,
            color: _line),
        ])),
        pw.SizedBox(width: 10),
        pw.SizedBox(width: 87,
          child: _text(_amount(amount), size: 7.5,
            color: _forest, bold: true, align: pw.TextAlign.right)),
      ],
    ),
  );
}

void _addPages(pw.Document pdf, pw.ThemeData theme, {
  required String title,
  required String descriptor,
  required String period,
  required String footer,
  required List<pw.Widget> body,
}) {
  pdf.addPage(pw.MultiPage(
    theme: theme,
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.fromLTRB(27, 22, 27, 25),
    maxPages: 150,
    header: (_) => _header(title, descriptor, period),
    footer: (ctx) => _footer(ctx, footer),
    build: (_) => [
      pw.SizedBox(height: 12),
      ...body,
    ],
  ));
}

List<pw.Widget> _monthly(Json state, String month) {
  final summary = financeMonthSummary(state, month);
  final locals = <String, int>{'Masa': 0, 'Gel-Al': 0};
  for (final entry in ledger(state)) {
    if (locals.containsKey(entry.source) &&
        _isInMonth(entry.stamp, month)) {
      locals[entry.source] = locals[entry.source]! + entry.amount;
    }
  }
  final online = deliveryNetEstimates(state, (stamp) =>
    _isInMonth(stamp, month));
  final onlineGross = online.fold<int>(
    0, (sum, entry) => sum + entry.grossCents);
  final fees = online.fold<int>(
    0, (sum, entry) => sum + (entry.deductionCents ?? 0));
  final channelRows = <List<String>>[
    for (final source in ['Masa', 'Gel-Al'])
      [source, _amount(locals[source]!),
        '—', _amount(locals[source]!)],
    for (final entry in online)
      [entry.source, _amount(entry.grossCents),
        entry.deductionCents == null && entry.grossCents > 0
          ? 'Bilinmiyor' : _amount(entry.deductionCents ?? 0),
        entry.grossCents > 0 && entry.estimatedNetCents == null
          ? '—' : _amount(entry.estimatedNetCents ?? 0)],
  ];
  final fixedByCategory = <String, int>{};
  for (final row in financeRows(state, 'monthlyFixed')) {
    final since = (row['startMonth'] ?? '').toString();
    if (row['active'] != true || since.compareTo(month) > 0) continue;
    final name = (row['category'] ?? 'Diğer').toString();
    fixedByCategory.update(name, (v) => v + _cents(row, 'amountCents'),
      ifAbsent: () => _cents(row, 'amountCents'));
  }
  final breakdown = <String, int>{
    'Gıda / Malzeme': summary.materialsCents,
    'Çalışan Maaşları': summary.payrollCents,
    ...fixedByCategory,
    'Diğer günlük gider': summary.otherCents,
  };
  final breakdownMax = breakdown.values.fold<int>(
    0, (max, value) => value > max ? value : max);
  return [
    pw.Row(children: [
      _metric('YEREL TAHSİLAT + ONLINE BRÜT',
        _amount(summary.localReceiptsCents + onlineGross),
        'İade sonrası yerel tahsilat + kayıtlı online sipariş'),
      pw.SizedBox(width: 10),
      _metric('NET GELİR (TAHMİNİ)',
        summary.missingOnlineRate
          ? '—' : _amount(summary.knownIncomeCents),
        'Platform kesintilerinden sonra', accent: _green),
    ]),
    pw.SizedBox(height: 9),
    pw.Row(children: [
      _metric('TOPLAM GİDER', _amount(summary.totalExpensesCents),
        'Malzeme, maaş, sabit ve diğer giderler', accent: _coral),
      pw.SizedBox(width: 10),
      _metric('TAHMİNİ FAALİYET FARKI',
        summary.estimateCents == null ? '—' :
          _amount(summary.estimateCents!),
        'Vergi ve stok tüketimi dahil değildir'),
    ]),
    _section('Satış kanalları',
      detail: 'Platform neti: sözleşmeye göre tahmin'),
    _table(['KANAL', 'KAYITLI BRÜT / TAHSİLAT',
      'KESİNTİ', 'TAHMİNİ NET'], channelRows,
      widths: {
        0: const pw.FlexColumnWidth(2.1),
        1: const pw.FlexColumnWidth(2.7),
        2: const pw.FlexColumnWidth(1.8),
        3: const pw.FlexColumnWidth(1.8),
      }),
    _section('Gider dağılımı',
      detail: 'Kayıtlı tahakkuk ve alışlar'),
    ...[
      for (final item in breakdown.entries)
        _bar(item.key, item.value, breakdownMax)
    ],
    _notice('Online platform kesintileri: ' + _amount(fees) +
      '. Kesintisi bilinmeyen kayıtlı online brüt: ' +
      _amount(summary.onlineUnpricedGrossCents) + '. ' +
      'Oran eksikse tahmini net ve faaliyet farkı gösterilmez.'),
    _notice('Yönetim amaçlı yaklaşık hesap. Satın alınan malzeme tüketim '
      'maliyeti (COGS) değildir. Banka mutabakatı, stopaj, '
      'vergiler, stok değişimleri ve entegrasyon eksikleri '
      'ayrıca kontrol edilmelidir.'),
  ];
}

List<pw.Widget> _materials(Json state, String day) {
  final items = financeRows(state, 'materials')
    .where((p) => p['voided'] != true &&
      (p['date'] ?? '').toString() == day)
    .toList()
    ..sort((a, b) =>
      (a['id'] as int? ?? 0).compareTo(b['id'] as int? ?? 0));
  int sum(String field) => items.fold<int>(
    0, (n, row) => n + _cents(row, field));
  final subtotal = items.fold<int>(0, (n, row) =>
    n + (row['subtotalCents'] is int
      ? row['subtotalCents'] as int : _cents(row, 'totalCents')));
  final discount = sum('discountCents');
  final total = sum('totalCents');
  final stores = <String, int>{
    for (final store in materialStores) store: 0,
  };
  for (final row in items) {
    final key = materialPurchaseStore(row);
    stores[key] = (stores[key] ?? 0) + _cents(row, 'totalCents');
  }
  return [
    pw.Row(children: [
      _metric('ARA TOPLAM', _amount(subtotal),
        'İndirim öncesi'),
      pw.SizedBox(width: 9),
      _metric('TOPLAM İNDİRİM', _amount(discount),
        'Kayıtlı fiş indirimleri', accent: _coral),
      pw.SizedBox(width: 9),
      _metric('ÖDENEN / KAYITLI TUTAR', _amount(total),
        items.length.toString() + ' kayıt', accent: _green),
    ]),
    _section('Marketlere göre alış', detail: _dayName(day)),
    pw.Row(children: [
      for (final store in materialStores) ...[
        pw.Expanded(child: pw.Container(
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(
            color: PdfColors.white,
            border: pw.Border.all(color: _line),
            borderRadius: pw.BorderRadius.circular(8)),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _text(store, size: 9, color: switch (store) {
                'BİM' => PdfColor.fromInt(0xffca283c),
                'A101' => PdfColor.fromInt(0xff1686b5),
                'Hakmar' => PdfColor.fromInt(0xff268052),
                _ => _muted,
              }, bold: true),
              pw.SizedBox(height: 5),
              _text(_amount(stores[store] ?? 0),
                size: 8, color: _forest, bold: true),
            ],
          ),
        )),
        if (store != materialStores.last) pw.SizedBox(width: 7),
      ],
    ]),
    _section('Alış listesi',
      detail: 'Gerçek satın alma fiyatları'),
    _table([
      'ÜRÜN / MARKET', 'MİKTAR', 'BİRİM FİYAT',
      'İNDİRİM', 'NET'
    ], [
      for (final p in items)
        [
          (p['title'] ?? '').toString() + '\n' +
            materialPurchaseStore(p) +
            (materialPurchaseStore(p) == 'Diğer'
              ? ' · ' + (p['market'] ?? 'Diğer').toString() : ''),
          _quantity(p['quantityMilli']) + ' ' +
            (p['unit'] ?? '').toString(),
          _amount(_cents(p, 'pricePerUnitCents')),
          _cents(p, 'discountCents') == 0 ? '—'
            : _amount(_cents(p, 'discountCents')),
          _amount(_cents(p, 'totalCents')),
        ],
    ], widths: {
      0: const pw.FlexColumnWidth(2.9),
      1: const pw.FlexColumnWidth(1.2),
      2: const pw.FlexColumnWidth(1.6),
      3: const pw.FlexColumnWidth(1.3),
      4: const pw.FlexColumnWidth(1.7),
    }),
    _notice('Market Fiyat Takibi fiyatı yalnızca referanstır. '
      'Bu tabloda fişte girilen birim fiyat, miktar ve varsa '
      'manuel indirim kullanılır. Fiyat takibi kaydı değiştirilmez.'),
  ];
}

List<pw.Widget> _payroll(Json state, String week) {
  final end = weekEndOf(week);
  final month = end.substring(0, 7);
  final payroll = financeRows(state, 'weeklyPayroll')
    .where((p) => (p['weekStart'] ?? '').toString() == week)
    .toList()
    ..sort((a, b) => (a['employeeName'] ?? '').toString()
      .compareTo((b['employeeName'] ?? '').toString()));
  final gross = payroll.fold<int>(0, (n, p) =>
    n + _cents(p, 'grossCents'));
  final advance = payroll.fold<int>(0, (n, p) =>
    n + _cents(p, 'advanceCents'));
  final payable = payroll.fold<int>(0, (n, p) =>
    n + _cents(p, 'payableCents'));
  final fixed = financeRows(state, 'monthlyFixed')
    .where((p) => p['active'] == true &&
      (p['startMonth'] ?? '').toString().compareTo(month) <= 0)
    .toList();
  final payments = financeRows(state, 'fixedPayments');
  final fixedTotal = fixed.fold<int>(0, (n, p) =>
    n + _cents(p, 'amountCents'));
  return [
    pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.symmetric(
        horizontal: 11, vertical: 8),
      color: PdfColor.fromInt(0xfff7eee7),
      child: _text('YÖNETİCİYE ÖZEL · Personel ücret bilgileri içerir.',
        size: 8, color: _coral, bold: true),
    ),
    pw.SizedBox(height: 8),
    pw.Row(children: [
      _metric('HAFTALIK HAK EDİŞ', _amount(gross),
        payroll.length.toString() + ' personel'),
      pw.SizedBox(width: 9),
      _metric('VERİLEN AVANS', _amount(advance),
        'Hak edişten ikinci kez düşülmez', accent: _coral),
      pw.SizedBox(width: 9),
      _metric('KALAN ÖDEME', _amount(payable),
        'Ödeme onayı ayrıca kontrol edilir', accent: _green),
    ]),
    _section('Haftalık personel maaşları',
      detail: _dayName(week) + ' – ' + _dayName(end)),
    _table([
      'PERSONEL', 'ÇALIŞMA', 'HAK EDİŞ', 'AVANS', 'KALAN'
    ], [
      for (final p in payroll)
        [
          (p['employeeName'] ?? 'Personel').toString() + '\n' +
            (p['paid'] == true ? 'Ödendi' : 'Ödenmedi'),
          (p['payType'] ?? '').toString() == 'Saatlik'
            ? _hours(p['workedMinutes']) + ' × ' +
                _amount(_cents(p, 'rateCents'))
            : 'Haftalık sabit',
          _amount(_cents(p, 'grossCents')),
          _cents(p, 'advanceCents') == 0 ? '—'
            : _amount(_cents(p, 'advanceCents')),
          _amount(_cents(p, 'payableCents')),
        ],
    ], widths: {
      0: const pw.FlexColumnWidth(2.0),
      1: const pw.FlexColumnWidth(2.2),
      2: const pw.FlexColumnWidth(1.6),
      3: const pw.FlexColumnWidth(1.4),
      4: const pw.FlexColumnWidth(1.7),
    }),
    _section('Aylık sabit giderler', detail: _monthName(month)),
    _table(['GİDER', 'DURUM', 'AYLIK TUTAR'], [
      for (final p in fixed)
        [
          (p['name'] ?? p['category'] ?? 'Sabit Gider').toString(),
          payments.any((x) =>
            x['templateId'] == p['id'] && x['month'] == month)
            ? 'Ödendi' : 'Bekliyor',
          _amount(_cents(p, 'amountCents')),
        ],
    ], widths: {
      0: const pw.FlexColumnWidth(3),
      1: const pw.FlexColumnWidth(1.4),
      2: const pw.FlexColumnWidth(1.8),
    }),
    pw.SizedBox(height: 9),
    pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        _text('AYLIK SABİT TOPLAM',
          size: 8, color: _muted, bold: true),
        _text(_amount(fixedTotal), size: 12,
          color: _forest, bold: true),
      ],
    ),
    _notice('Önemli: Avans maaş giderine ikinci kez eklenmez. '
      'Ödendi durumu banka/kasadan otomatik para çıkışı değildir. '
      'Bu raporda kişisel ücret bilgileri vardır; '
      'yalnızca yetkili yöneticiyle paylaşın.'),
  ];
}

/// Creates a real, print-ready A4 PDF from the supplied POS data. No made-up
/// amounts are inserted. Turkish-supporting Barlow fonts are bundled assets.
Future<Uint8List> generateFinancePdf(
    Json state, FinancePdfRequest request) async {
  request.validate();
  final normalData = await rootBundle.load(
    'assets/brand/fonts/Barlow-Regular.ttf');
  final boldData = await rootBundle.load(
    'assets/brand/fonts/Barlow-Bold.ttf');
  final normal = pw.Font.ttf(normalData.buffer.asByteData(
    normalData.offsetInBytes, normalData.lengthInBytes));
  final bold = pw.Font.ttf(boldData.buffer.asByteData(
    boldData.offsetInBytes, boldData.lengthInBytes));
  final theme = pw.ThemeData.withFont(base: normal, bold: bold);
  final pdf = pw.Document();
  switch (request.kind) {
    case FinancePdfKind.monthly:
      _addPages(pdf, theme, title: request.title,
        descriptor: 'Gelir, komisyon ve giderlerin özeti',
        period: _monthName(request.month),
        footer: 'Aylık finans · Tahmini',
        body: _monthly(state, request.month));
    case FinancePdfKind.materials:
      _addPages(pdf, theme, title: request.title,
        descriptor: 'Market bazlı · Miktar · İndirim',
        period: _dayName(request.day),
        footer: 'Günlük malzeme · Market bazlı',
        body: _materials(state, request.day));
    case FinancePdfKind.payroll:
      _addPages(pdf, theme, title: request.title,
        descriptor: 'Personel hak edişi · Aylık sabit giderler',
        period: _dayName(request.weekStart) + ' – ' +
          _dayName(weekEndOf(request.weekStart)),
        footer: 'Maaş ve sabit giderler · Özel',
        body: _payroll(state, request.weekStart));
  }
  return pdf.save();
}
