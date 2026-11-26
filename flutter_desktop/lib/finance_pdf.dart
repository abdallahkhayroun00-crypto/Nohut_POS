import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:nohut_core/report_period.dart';
import 'package:pdf/widgets.dart' as pw;

import 'finance_logic.dart';
import 'market_prices.dart';
import 'platform_net.dart';
import 'operations.dart';
import 'order_reporting.dart';
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
final _green = PdfColor.fromInt(0xff27714e);
final _pale = PdfColor.fromInt(0xffeff4ef);
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
    maxPages: 3000,
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
  final online = financePlatformFigures(state, month);
  final onlineGross = online.fold<int>(
    0, (sum, entry) => sum + (entry.grossCents ?? 0));
  final fees = online.fold<int>(
    0, (sum, entry) => sum + (entry.deductionCents ?? 0));
  final channelRows = <List<String>>[
    for (final source in ['Masa', 'Gel-Al'])
      [source, _amount(locals[source]!),
        '—', _amount(locals[source]!)],
    for (final entry in online)
      [
        entry.source + (entry.isManual
          ? ' (Manuel ' + (entry.inputKind ?? '') + ')' : ''),
        entry.grossCents == null ? '—' : _amount(entry.grossCents!),
        entry.isManual && entry.inputKind == 'Net'
          ? 'Net girildi'
          : entry.deductionCents == null && entry.unknownGrossCents > 0
            ? 'Bilinmiyor'
            : _amount(entry.deductionCents ?? 0),
        entry.netCents == null ? '—' : _amount(entry.netCents!),
      ],
  ];
  final fixedByCategory = <String, int>{};
  for (final (row, amount) in fixedDueRows(state, month)) {
    final name = (row['category'] ?? 'Diğer').toString();
    fixedByCategory.update(name, (v) => v + amount, ifAbsent: () => amount);
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
      _metric('YEREL + BİLİNEN ONLINE BRÜT',
        _amount(summary.localReceiptsCents + onlineGross),
        'Manuel Net girişlerinin brütü bilinmez'),
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
    _notice('Hesaba katılan online kesintiler: ' + _amount(fees) +
      '. Kesintisi bilinmeyen kayıtlı online brüt: ' +
      _amount(summary.onlineUnpricedGrossCents) + '. ' +
      'Oran eksikse tahmini net ve faaliyet farkı gösterilmez.'),
    _notice('Manuel Net kayıtlarda tutar zaten komisyon sonrası kabul '
      'edilir ve ikinci kez kesinti uygulanmaz. Otomatik teslim edilmiş '
      'siparişler aynı ayın manuel özetinin yerine geçer.'),
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
              ? ' · ' + (p['market'] ?? 'Diğer').toString() : '') +
            (isQuickMaterial(p) ? '\n' +
              (p['amountsCents'] as List).whereType<int>().length.toString() +
                ' tutar · ürün detayı yok' : ''),
          isQuickMaterial(p) ? '—' :
            _quantity(p['quantityMilli']) + ' ' +
              (p['unit'] ?? '').toString(),
          isQuickMaterial(p) ? '—' :
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
      'manuel indirim kullanılır. Hızlı giderlerde yalnızca girilen net '
      'tutarların toplamı vardır; ürün, miktar veya stok bilgisi yoktur. '
      'Fiyat takibi kaydı değiştirilmez.'),
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
  final fixedRows = fixedDueRows(state, month);
  final fixed = [
    for (final (row, amount) in fixedRows) {...row, 'amountCents': amount},
  ];
  final payments = financeRows(state, 'fixedPayments');
  final fixedTotal = fixedRows.fold<int>(0, (n, r) => n + r.$2);
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
    Json state, FinancePdfRequest request, {bool combined = false}) async {
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
  if (combined) {
    _addPages(pdf, theme, title: 'Aylık Finans Özeti',
      descriptor: 'Gelir, komisyon ve giderlerin özeti',
      period: _monthName(request.month),
      footer: 'Birleşik rapor · Finans',
      body: _monthly(state, request.month));
    _addPages(pdf, theme, title: 'Malzeme Alım Raporu',
      descriptor: 'Market bazlı · Miktar · İndirim',
      period: _dayName(request.day),
      footer: 'Birleşik rapor · Seçilen gün',
      body: _materials(state, request.day));
    _addPages(pdf, theme, title: 'Maaş & Sabit Giderler',
      descriptor: 'Personel hak edişi · Aylık sabit giderler',
      period: _dayName(request.weekStart) + ' – ' +
        _dayName(weekEndOf(request.weekStart)),
      footer: 'Birleşik rapor · Seçilen hafta · Özel',
      body: _payroll(state, request.weekStart));
    return pdf.save();
  }
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


/// Distinguish table visits (orders opened) from distinct table numbers and
/// additional batches. Ownership follows the existing POS rule, not guesses.
Json managementReportFacts(Json state, ReportPeriod period) {
  period.validate();
  final local = asMaps(state['orders']).where((o) =>
    ['Masa', 'Gel-Al'].contains(o['source'])).toList();
  final orders = local.where((o) => period.includesStamp(o['createdAt'])).toList();
  final valid = orders.where((o) => o['cancelled'] != true).toList();
  final staff = <String, Json>{};
  Json person(String name) => staff.putIfAbsent(name, () => {
    'name': name, 'tableOrders': 0, 'pickupOrders': 0, 'tables': <String>{},
    'ownedCents': 0, 'batches': 0, 'extraBatches': 0,
    'items': 0, 'lineCents': 0, 'cancelled': 0,
  });
  void plus(Json p, String key, int n) { p[key] = (p[key] as int) + n; }
  for (final e in asMaps(state['employees'])) {
    final name = (e['name'] ?? '').toString().trim();
    if (name.isNotEmpty) person(name);
  }
  for (final o in orders) {
    final p = person(orderOwnerName(o));
    if (o['cancelled'] == true) {
      plus(p, 'cancelled', 1);
      continue;
    }
    if (o['source'] == 'Masa') {
      plus(p, 'tableOrders', 1);
      if (o['table'] != null) (p['tables'] as Set<String>).add(o['table'].toString());
    } else {
      plus(p, 'pickupOrders', 1);
    }
    plus(p, 'ownedCents', orderTotalCents(o));
  }
  final lines = <Json>[];
  final products = <String, Json>{};
  for (final o in local) {
    final batches = asMaps(o['batches']);
    for (var i = 0; i < batches.length; i++) {
      final b = batches[i];
      if (!period.includesStamp(b['createdAt'] ?? o['createdAt'])) continue;
      final raw = (b['staff'] ?? '').toString().trim();
      final name = raw.isEmpty ? 'Atanmamış' : raw;
      final p = person(name);
      if (o['cancelled'] != true) {
        plus(p, 'batches', 1);
        if (i > 0) plus(p, 'extraBatches', 1);
      }
      for (final l in asMaps(b['lines'])) {
        final qty = (l['qty'] as num?)?.toInt() ?? 0;
        final amount = cents(l['price']) * qty;
        final excluded = o['cancelled'] == true || l['voided'] == true || l['correction'] == true;
        final product = (l['name'] ?? l['productKey'] ?? 'Bilinmiyor').toString();
        lines.add({
          'order': displayOrderNumber(o), 'orderId': o['id'],
          'source': o['source'], 'table': o['table'], 'batch': b['id'],
          'stamp': b['createdAt'] ?? o['createdAt'], 'staff': name,
          'product': product, 'qty': qty, 'unitCents': cents(l['price']),
          'amount': amount, 'status': o['cancelled'] == true ? 'Sipariş iptal' :
            l['voided'] == true ? 'İptal' : l['correction'] == true ? 'Düzeltme' : 'Aktif',
        });
        if (excluded) continue;
        plus(p, 'items', qty);
        plus(p, 'lineCents', amount);
        final item = products.putIfAbsent(product, () => {'qty': 0, 'amount': 0});
        plus(item, 'qty', qty);
        plus(item, 'amount', amount);
      }
    }
  }
  final payments = ledger(state).where((e) => period.includesStamp(e.stamp)).toList();
  return {'orders': orders, 'valid': valid, 'staff': staff.values.toList(),
    'lines': lines, 'products': products, 'payments': payments};
}

/// A single management report. A calendar-month-only manual platform total
/// and a monthly fixed-cost template are never prorated into a partial month.
Future<Uint8List> generateManagementPdf(Json state, ReportPeriod period) async {
  period.validate();
  final facts = managementReportFacts(state, period);
  final orders = facts['orders'] as List<Json>;
  final valid = facts['valid'] as List<Json>;
  final staff = facts['staff'] as List<Json>;
  final products = facts['products'] as Map<String, Json>;
  final payments = (facts['payments'] as List<LedgerEntry>)
    .where((p) => ['Masa', 'Gel-Al'].contains(p.source)).toList();
  final materials = financeRows(state, 'materials').where((r) =>
    period.includes((r['date'] ?? '').toString()) && r['voided'] != true).toList();
  final payroll = financeRows(state, 'weeklyPayroll').where((r) =>
    period.includes((r['weekEnd'] ?? '').toString())).toList();
  final other = financeRows(state, 'other').where((r) =>
    period.includes((r['date'] ?? '').toString()) && r['voided'] != true).toList();
  int sum(Iterable<Json> rows, String key) =>
    rows.fold<int>(0, (n, r) => n + _cents(r, key));
  String field(Json r, String k) => (r[k] ?? '—').toString();
  String short(String value, [int max = 29]) => value.length <= max
    ? value : value.substring(0, max - 1) + '…';
  final local = payments.fold<int>(0, (n, p) => n + p.amount);
  final materialTotal = sum(materials, 'totalCents');
  final payrollTotal = sum(payroll, 'grossCents');
  final otherTotal = sum(other, 'amountCents');
  final fixedByCategory = <String,int>{};
  var fixedTotal = 0, excludedFixed = 0, onlineNet = 0;
  var excludedManualGross = 0, excludedManualNet = 0;
  final online = <String,Json>{for (final source in deliverySources)
    source: {'orders': 0, 'gross': 0, 'grossKnown': false,
      'net': 0, 'netKnown': false, 'fee': 0, 'feeKnown': false,
      'missing': false, 'manual': false}};
  bool incomplete = false;
  void add(Json row, String key, int value) => row[key] = (row[key] as int) + value;
  for (final month in period.months) {
    final full = period.fullMonth(month);
    if (!full) incomplete = true;
    for (final (r, amount) in fixedDueRows(state, month)) {
      if (full) {
        fixedTotal += amount;
        final name = field(r,'category');
        fixedByCategory[name] = (fixedByCategory[name] ?? 0) + amount;
      } else {
        excludedFixed += amount;
      }
    }
    final estimates = deliveryNetEstimates(state, (stamp) {
      final d = DateTime.tryParse(stamp);
      return d != null && istanbulDay(d).startsWith(month) && period.includesStamp(stamp);
    });
    for (final p in financePlatformFigures(state, month)) {
      final a = estimates.firstWhere((e) => e.source == p.source);
      final row = online[p.source]!;
      add(row, 'orders', a.orderCount);
      final hasData = full ? p.origin != 'Yok' : a.orderCount > 0;
      final gross = full ? p.grossCents : a.orderCount > 0 ? a.grossCents : null;
      final fee = full ? p.deductionCents : a.orderCount > 0 ? a.deductionCents : null;
      final net = full && hasData ? p.netCents : a.orderCount > 0 ? a.estimatedNetCents : null;
      if (hasData && gross != null) { add(row,'gross',gross); row['grossKnown'] = true; }
      if (hasData && fee != null) { add(row,'fee',fee); row['feeKnown'] = true; }
      if (net != null) { add(row,'net',net); row['netKnown'] = true; onlineNet += net; }
      if (!hasData || net == null) { row['missing'] = true; incomplete = true; }
      if (full && p.isManual) row['manual'] = true;
    }
    if (!full) {
      for (final r in financeRows(state,'manualPlatformSales')) {
        if (r['month'] == month && r['voided'] != true &&
            !platformHasAutomaticSales(state,field(r,'source'),month)) {
          if (r['kind'] == 'Brüt') {
            excludedManualGross += _cents(r,'amountCents');
          } else if (r['kind'] == 'Net') {
            excludedManualNet += _cents(r,'amountCents');
          }
        }
      }
    }
  }
  final expense = materialTotal + payrollTotal + fixedTotal + otherTotal;
  final netCash = payments.where((p) => p.method == 'Nakit').fold<int>(0,(n,p)=>n+p.amount);
  final netCard = payments.where((p) => p.method == 'Kart').fold<int>(0,(n,p)=>n+p.amount);
  final refunds = payments.where((p) => p.kind == 'İade').fold<int>(0,(n,p)=>n-p.amount);
  final tableOrders = valid.where((o) => o['source'] == 'Masa').length;
  final pickupOrders = valid.where((o) => o['source'] == 'Gel-Al').length;
  final cancelled = orders.length - valid.length;
  final open = valid.where((o)=>o['closed'] != true).length;
  final outstanding = valid.fold<int>(0,(n,o)=>n+orderDueCents(o));
  final hourly = hourlyOrderCounts(valid,from:period.from,to:period.to);
  final maxHour = hourly.fold<int>(1,(a,b)=>a>b?a:b);
  final dates = <String>[];
  for (var d = ReportPeriod.parse(period.from); !d.isAfter(ReportPeriod.parse(period.to));
      d = d.add(const Duration(days:1))) {
    dates.add(ReportPeriod.day(d));
  }
  final step = (dates.length / 12).ceil();
  final trend = <MapEntry<String,int>>[];
  for (var i = 0; i < dates.length; i += step) {
    final end = i+step < dates.length ? i+step-1 : dates.length-1;
    final range = ReportPeriod(dates[i],dates[end]);
    final amount = payments.where((p)=>range.includesStamp(p.stamp)).fold<int>(0,(n,p)=>n+p.amount);
    trend.add(MapEntry(dates[i].substring(5) + (i==end?'':' / '+dates[end].substring(5)),amount));
  }
  final productRows = products.entries.toList()
    ..sort((a,b)=>(b.value['qty'] as int).compareTo(a.value['qty'] as int));
  final visibleStaff = [...staff]..sort((a,b)=>_cents(b,'tableOrders').compareTo(_cents(a,'tableOrders')));
  final staffHead = visibleStaff.take(9).toList();
  final staffTail = visibleStaff.skip(9).toList();
  final payByStaff = <String,Json>{};
  for (final p in payroll) {
    final name = field(p,'employeeName');
    final row = payByStaff.putIfAbsent(name,()=>{'minutes':0,'gross':0,'bonus':0,'advance':0,'due':0});
    add(row,'minutes',_cents(p,'workedMinutes')); add(row,'gross',_cents(p,'grossCents'));
    add(row,'bonus',_cents(p,'bonusCents')); add(row,'advance',_cents(p,'advanceCents'));
    if (p['paid'] != true) add(row,'due',_cents(p,'payableCents'));
  }
  final payRows = payByStaff.entries.toList()
    ..sort((a,b)=>_cents(b.value,'gross').compareTo(_cents(a.value,'gross')));
  final categories = <String,int>{};
  for (final r in other) {
    final name = field(r,'category');
    categories[name] = (categories[name] ?? 0) + _cents(r,'amountCents');
  }
  List<List<String>> aggregateRows(Map<String,int> values,int limit) {
    final rows = values.entries.toList()..sort((a,b)=>b.value.compareTo(a.value));
    return [
      for (final e in rows.take(limit)) [short(e.key),_amount(e.value)],
      if (rows.length>limit) ['Diğer ('+(rows.length-limit).toString()+')',
        _amount(rows.skip(limit).fold<int>(0,(n,e)=>n+e.value))],
    ];
  }
  final cash = state['cashBook'] is Map ? state['cashBook'] as Map : {};
  final movements = asMaps(cash['movements']).where((r)=>period.includesStamp(r['at'])).toList();
  final cashIn = movements.where((r)=>_cents(r,'cents')>0).fold<int>(0,(n,r)=>n+_cents(r,'cents'));
  final cashOut = movements.where((r)=>_cents(r,'cents')<0).fold<int>(0,(n,r)=>n-_cents(r,'cents'));
  final closedSessions = asMaps(cash['sessions']).where((r)=>period.includesStamp(r['closedAt'])).toList();
  final cashDiff = sum(closedSessions,'differenceCents');
  final normalData = await rootBundle.load('assets/brand/fonts/Barlow-Regular.ttf');
  final boldData = await rootBundle.load('assets/brand/fonts/Barlow-Bold.ttf');
  final theme = pw.ThemeData.withFont(base: pw.Font.ttf(normalData),bold:pw.Font.ttf(boldData));
  final pdf = pw.Document();
  final label = period.from+' / '+period.to;
  pw.Widget heading(String title)=>pw.Padding(padding:const pw.EdgeInsets.only(top:9,bottom:4),
    child:_text(title,size:12,bold:true,color:_forest));
  pw.Widget note(String text)=>pw.Padding(padding:const pw.EdgeInsets.only(top:6),
    child:_text(text,size:7.4,color:_muted));
  pw.Widget compact(List<String> headers,List<List<String>> rows)=> rows.isEmpty
    ? note('Kayıt yok.')
    : pw.Table.fromTextArray(headers:headers,data:rows,headerCount:1,
      headerStyle:pw.TextStyle(fontSize:7.5,color:PdfColors.white,fontWeight:pw.FontWeight.bold),
      headerDecoration:pw.BoxDecoration(color:_forest),
      cellStyle:pw.TextStyle(fontSize:8,color:_ink),
      cellPadding:const pw.EdgeInsets.symmetric(horizontal:5,vertical:4),
      oddRowDecoration:pw.BoxDecoration(color:_pale));
  pw.Widget bars(List<MapEntry<String,int>> rows,{bool monetary=true}) {
    final max = rows.fold<int>(1,(a,e)=>e.value.abs()>a?e.value.abs():a);
    return pw.Column(children:[
      for(final r in rows) pw.Padding(padding:const pw.EdgeInsets.symmetric(vertical:2),
        child:pw.Row(children:[
          pw.SizedBox(width:124,child:_text(short(r.key,25),size:8)),
          pw.Container(width:210*r.value.abs()/max,height:7,color:r.value<0?_coral:_green),
          pw.SizedBox(width:8),
          _text(monetary?_amount(r.value):r.value.toString(),size:8),
        ])),
    ]);
  }
  pw.Widget pair(pw.Widget left,pw.Widget right)=>pw.Row(crossAxisAlignment:pw.CrossAxisAlignment.start,
    children:[pw.Expanded(child:left),pw.SizedBox(width:12),pw.Expanded(child:right)]);
  void page(String title,List<pw.Widget> body) {
    pdf.addPage(pw.Page(pageFormat:PdfPageFormat.a4,theme:theme,
      margin:const pw.EdgeInsets.all(28),build:(ctx)=>pw.Column(
        crossAxisAlignment:pw.CrossAxisAlignment.stretch,children:[
          pw.Container(color:_forest,padding:const pw.EdgeInsets.all(13),
            child:pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[
              _text('NOHUT FALAFEL · YÖNETİCİ RAPORU',size:9,bold:true,color:PdfColors.white),
              pw.SizedBox(height:5),
              _text(title,size:20,bold:true,color:PdfColors.white),
              _text(label,size:9,color:PdfColors.white),
            ])),
          ...body,
          pw.Spacer(),
          _footer(ctx,'Özet · Yöneticiye özel'),
        ])));
  }
  page('01 · Finans ve Platformlar',[
    pw.SizedBox(height:10),
    pw.Row(children:[
      _metric('BİLİNEN GELİR',_amount(local+onlineNet),'Yerel + online net'),
      pw.SizedBox(width:7),
      _metric('BİLİNEN GİDER',_amount(expense),'Kayıtlı giderler',accent:_coral),
      pw.SizedBox(width:7),
      _metric('BİLİNEN FARK',_amount(local+onlineNet-expense),'Kesin kâr değildir'),
    ]),
    heading('Gelir ve gider dağılımı'),
    bars([MapEntry('Yerel tahsilat',local),MapEntry('Online net',onlineNet),
      MapEntry('Malzeme',materialTotal),MapEntry('Maaş',payrollTotal),
      MapEntry('Sabit gider',fixedTotal),MapEntry('Diğer gider',otherTotal)]),
    heading('Tahsilat ve iade'),
    compact(['NAKİT NET','KART NET','İADE','AÇIK BAKİYE'],[
      [_amount(netCash),_amount(netCard),_amount(refunds),_amount(outstanding)],
    ]),
    heading('Online platform özeti'),
    compact(['PLATFORM','TESLİM','BRÜT*','KESİNTİ*','NET*','VERİ'],[
      for(final p in online.entries) [
        p.key,field(p.value,'orders'),
        p.value['grossKnown']==true?_amount(_cents(p.value,'gross')):'—',
        p.value['feeKnown']==true?_amount(_cents(p.value,'fee')):'—',
        p.value['netKnown']==true?_amount(_cents(p.value,'net')):'—',
        p.value['missing']==true?'Eksik':p.value['manual']==true?'Manuel / oto.':'Otomatik',
      ],
    ]),
    note('* Bilinen tutarlar. Online net tahmini olup banka mutabakatı değildir. '
      'Eksik kaynaklar sıfır kabul edilmez.'),
    heading('Kasa hareketleri'),
    compact(['GİRİŞ','ÇIKIŞ','KAPANAN KASA','SAYIM FARKI'],[
      [_amount(cashIn),_amount(cashOut),closedSessions.length.toString(),_amount(cashDiff)],
    ]),
    heading('Aylık olup döneme dahil edilmeyen kayıtlar'),
    compact(['KALEM','TUTAR'],[
      ['Kısmi aya ait sabit gider',_amount(excludedFixed)],
      ['Kısmi aya ait manuel online brüt',_amount(excludedManualGross)],
      ['Kısmi aya ait manuel online net',_amount(excludedManualNet)],
    ]),
    note((incomplete?'Eksik veya kısmi dönem verisi var. ':'')+
      'Aylık kayıtlar yalnızca tam ayda toplama girer. Maaş Pazar gününe göre hesaplanır. '
      'Vergi ve stok tüketimi dahil değildir.'),
  ]);
  page('02 · Personel ve Masalar',[
    heading('Sipariş özeti'),
    compact(['MASA','GEL-AL','İPTAL','AÇIK'],[
      [tableOrders.toString(),pickupOrders.toString(),cancelled.toString(),open.toString()],
    ]),
    heading('Personel performansı · hesap sahibi'),
    compact(['PERSONEL','MASA','FARKLI','GEL-AL','HESAP ₺','İPTAL'],[
      for(final p in staffHead) [short(field(p,'name'),21),field(p,'tableOrders'),
        (p['tables'] as Set<String>).length.toString(),field(p,'pickupOrders'),
        _amount(_cents(p,'ownedCents')),field(p,'cancelled')],
      if(staffTail.isNotEmpty) ['Diğer ('+staffTail.length.toString()+')',
        sum(staffTail,'tableOrders').toString(),'—',sum(staffTail,'pickupOrders').toString(),
        _amount(sum(staffTail,'ownedCents')),sum(staffTail,'cancelled').toString()],
    ]),
    heading('Personel · ek sipariş ve ürün girişleri'),
    compact(['PERSONEL','PARTİ','EK SİPARİŞ','ÜRÜN','SATIR TUTARI'],[
      for(final p in staffHead) [short(field(p,'name'),21),field(p,'batches'),
        field(p,'extraBatches'),field(p,'items'),_amount(_cents(p,'lineCents'))],
      if(staffTail.isNotEmpty) ['Diğer',sum(staffTail,'batches').toString(),
        sum(staffTail,'extraBatches').toString(),sum(staffTail,'items').toString(),
        _amount(sum(staffTail,'lineCents'))],
    ]),
    heading('Masa performansı'),
    compact(['MASA','HESAP','KAPALI','AÇIK','TUTAR'],[
      for(final n in [1,2,3,4,5]) [
        'Masa '+n.toString(),
        valid.where((o)=>o['source']=='Masa'&&o['table']==n).length.toString(),
        valid.where((o)=>o['source']=='Masa'&&o['table']==n&&o['closed']==true).length.toString(),
        valid.where((o)=>o['source']=='Masa'&&o['table']==n&&o['closed']!=true).length.toString(),
        _amount(valid.where((o)=>o['source']=='Masa'&&o['table']==n).fold<int>(0,(v,o)=>v+orderTotalCents(o))),
      ],
    ]),
    note('Masa = açılan hesap; farklı = farklı masa numarası. Ek sipariş, hesabı '
      'yeniden saymaz. Hesap sahibi ve giriş yapan personel ayrı ölçümlerdir.'),
  ]);
  page('03 · Satış ve Yoğunluk',[
    heading('Net yerel tahsilat · dönem grafiği'),
    bars(trend),
    heading('Saatlik sipariş yoğunluğu'),
    pw.Container(height:108,padding:const pw.EdgeInsets.only(top:4),
      child:pw.Row(crossAxisAlignment:pw.CrossAxisAlignment.end,children:[
        for(var h=0;h<24;h++) pw.Expanded(child:pw.Column(
          mainAxisAlignment:pw.MainAxisAlignment.end,children:[
            _text(hourly[h].toString(),size:6),
            pw.SizedBox(height:3),
            pw.Container(width:12,height:65*hourly[h]/maxHour,color:_green),
            pw.SizedBox(height:3),
            _text(h.toString().padLeft(2,'0'),size:7),
          ])),
      ])),
    heading('En çok satılan yerel ürünler'),
    compact(['ÜRÜN','ADET','SATIR TUTARI'],[
      for(final p in productRows.take(10)) [short(p.key,43),field(p.value,'qty'),_amount(_cents(p.value,'amount'))],
      if(productRows.length>10) ['Diğer ('+(productRows.length-10).toString()+' ürün)',
        productRows.skip(10).fold<int>(0,(n,p)=>n+_cents(p.value,'qty')).toString(),
        _amount(productRows.skip(10).fold<int>(0,(n,p)=>n+_cents(p.value,'amount')))],
    ]),
    note('Ürünler parti giriş tarihine göre; tahsilatlar ödeme/iade tarihine göre. '
      'İptal edilen ürünler satışa dahil değildir.'),
  ]);
  page('04 · Malzeme, Maaş ve Giderler',[
    heading('Market bazlı alımlar'),
    compact(['MARKET','KAYIT','NET ALIŞ'],[
      for(final brand in materialStores) [brand,
        materials.where((r)=>materialPurchaseStore(r)==brand).length.toString(),
        _amount(sum(materials.where((r)=>materialPurchaseStore(r)==brand),'totalCents'))],
      ['TOPLAM',materials.length.toString(),_amount(materialTotal)],
    ]),
    heading('Alış türü ve indirim'),
    compact(['DETAYLI ALIŞ','HIZLI GİDER','TOPLAM İNDİRİM'],[
      [_amount(sum(materials.where((r)=>!isQuickMaterial(r)),'totalCents')),
        _amount(sum(materials.where(isQuickMaterial),'totalCents')),
        _amount(sum(materials,'discountCents'))],
    ]),
    heading('Personel maaş özeti'),
    compact(['PERSONEL','SAAT','PRİM','HAK EDİŞ','AVANS','ÖDENMEMİŞ'],[
      for(final p in payRows.take(8)) [short(p.key,20),_hours(p.value['minutes']),
        _amount(_cents(p.value,'bonus')),_amount(_cents(p.value,'gross')),
        _amount(_cents(p.value,'advance')),_amount(_cents(p.value,'due'))],
      if(payRows.length>8) ['Diğer',_hours(payRows.skip(8).fold<int>(0,(n,p)=>n+_cents(p.value,'minutes'))),
        for(final key in ['bonus','gross','advance','due']) _amount(payRows.skip(8).fold<int>(0,(n,p)=>n+_cents(p.value,key)))],
      ['TOPLAM',_hours(sum(payroll,'workedMinutes')),_amount(sum(payroll,'bonusCents')),
        _amount(payrollTotal),_amount(sum(payroll,'advanceCents')),
        _amount(sum(payroll.where((p)=>p['paid']!=true),'payableCents'))],
    ]),
    heading('Gider kategorileri'),
    pair(compact(['SABİT GİDER','TUTAR'],aggregateRows(fixedByCategory,5)),
      compact(['DİĞER GİDER','TUTAR'],aggregateRows(categories,5))),
    note('Market fiyat takibi: '+trackedMarketProducts(state).length.toString()+
      ' takipli ürün (rapor anı); referans fiyat alış gideri değildir.'),
    note('Avans ikinci kez gider sayılmaz. Hızlı giderlerde ürün miktarı bilinmez. '
      'Sabit giderler mevcut şablonlara dayanır. Yalnızca Windows onaylı kayıtlar dahildir.'),
  ]);
  return pdf.save();
}
