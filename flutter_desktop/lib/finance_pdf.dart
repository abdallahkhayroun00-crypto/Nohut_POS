import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:nohut_core/report_period.dart';
import 'package:pdf/widgets.dart' as pw;

import 'finance_logic.dart';
import 'market_prices.dart';
import 'platform_net.dart';
import 'trendyol_go_readonly.dart';
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
  final lines = facts['lines'] as List<Json>;
  final products = facts['products'] as Map<String, Json>;
  final payments = facts['payments'] as List<LedgerEntry>;
  final materials = financeRows(state, 'materials').where((r) =>
    period.includes((r['date'] ?? '').toString())).toList();
  final payroll = financeRows(state, 'weeklyPayroll').where((r) =>
    period.includes((r['weekEnd'] ?? '').toString())).toList();
  final other = financeRows(state, 'other').where((r) =>
    period.includes((r['date'] ?? '').toString())).toList();
  int sum(Iterable<Json> rows, String key) =>
    rows.fold<int>(0, (n, r) => n + _cents(r, key));
  String field(Json r, String k) => (r[k] ?? '—').toString();
  String money(Json r, String k) => r[k] is int ? _amount(r[k] as int) : '—';
  String place(Json o) => o['source'] == 'Masa' ? 'Masa ' + field(o, 'table') : field(o, 'source');
  String status(Json o) => o['cancelled'] == true ? 'İptal' :
    o['closed'] == true ? 'Kapalı' : 'Açık';
  final localPay = payments.where((e) => ['Masa', 'Gel-Al'].contains(e.source)).toList();
  final localTotal = localPay.fold<int>(0, (n, p) => n + p.amount);
  final materialTotal = sum(materials.where((r) => r['voided'] != true), 'totalCents');
  final payrollTotal = sum(payroll, 'grossCents');
  final otherTotal = sum(other.where((r) => r['voided'] != true), 'amountCents');
  final fixedRows = <List<String>>[];
  final fixedPayments = financeRows(state, 'fixedPayments');
  var fixedTotal = 0, onlineNet = 0;
  var incomplete = false;
  final platformRows = <List<String>>[];
  final manualRows = <List<String>>[];
  for (final month in period.months) {
    final full = period.fullMonth(month);
    if (!full) incomplete = true;
    for (final r in financeRows(state, 'monthlyFixed')) {
      if (r['active'] != true || field(r, 'startMonth').compareTo(month) > 0) continue;
      final payment = fixedPayments.where((p) =>
        p['templateId'] == r['id'] && p['month'] == month).firstOrNull;
      if (full) fixedTotal += _cents(r, 'amountCents');
      fixedRows.add([month, field(r, 'name') + ' / ' + field(r, 'category'),
        money(r, 'amountCents'), payment == null ? 'Bekliyor' :
          'Ödendi: ' + money(payment, 'amountCents'),
        full ? 'Dahil' : 'Kısmi ay · hariç']);
    }
    final figures = financePlatformFigures(state, month);
    final estimates = deliveryNetEstimates(state, (stamp) {
      final d = DateTime.tryParse(stamp);
      return d != null && istanbulDay(d).startsWith(month) && period.includesStamp(stamp);
    });
    for (final p in figures) {
      final a = estimates.firstWhere((e) => e.source == p.source);
      int? gross, net, fee;
      String origin;
      if (full) {
        gross = p.grossCents; net = p.netCents; fee = p.deductionCents;
        origin = p.origin;
        if (p.origin == 'Yok' || p.unknownGrossCents > 0) incomplete = true;
      } else {
        gross = a.orderCount == 0 ? null : a.grossCents;
        fee = a.orderCount == 0 ? null : a.deductionCents;
        net = a.orderCount == 0 ? null : a.estimatedNetCents;
        origin = a.orderCount > 0 ? 'Otomatik · dönem' : 'Veri yok';
      }
      if (net != null) onlineNet += net;
      if (a.orderCount > 0 && net == null) incomplete = true;
      platformRows.add([month, p.source, origin, a.orderCount.toString(),
        gross == null ? '—' : _amount(gross), fee == null ? '—' : _amount(fee),
        net == null ? '—' : _amount(net)]);
    }
    for (final r in financeRows(state, 'manualPlatformSales').where((r) => r['month'] == month)) {
      final automatic = platformHasAutomaticSales(state, field(r, 'source'), month);
      manualRows.add([month, field(r, 'source'), field(r, 'kind'), money(r, 'amountCents'),
        r['voided'] == true ? 'İptal' : automatic ? 'Otomatik veri · hariç' :
        full ? 'Aylık toplam · dahil' : 'Kısmi ay · hariç', field(r, 'note')]);
    }
  }
  final knownExpenses = materialTotal + payrollTotal + otherTotal + fixedTotal;
  final dates = <String>[];
  for (var d = ReportPeriod.parse(period.from); !d.isAfter(ReportPeriod.parse(period.to));
      d = d.add(const Duration(days: 1))) { dates.add(ReportPeriod.day(d)); }
  final hourly = hourlyOrderCounts(valid, from: period.from, to: period.to);
  final maxHour = hourly.fold<int>(1, (a, b) => a > b ? a : b);
  final productRows = products.entries.toList()
    ..sort((a,b) => (b.value['qty'] as int).compareTo(a.value['qty'] as int));
  final cash = state['cashBook'] is Map ? state['cashBook'] as Map : {};
  final platformOrders = asMaps(state['orders']).where((o) =>
    deliverySources.contains(o['source']) && o['source'] != 'Trendyol Go' &&
    o['testPackage'] != true && o['demoRemoteStatus'] == null &&
    period.includesStamp(o['createdAt'])).toList();
  final tgo = tgoOrders(state).where((o) => o['testPackage'] != true &&
    period.includesStamp(o['createdAt'])).toList();
  final normalData = await rootBundle.load('assets/brand/fonts/Barlow-Regular.ttf');
  final boldData = await rootBundle.load('assets/brand/fonts/Barlow-Bold.ttf');
  final theme = pw.ThemeData.withFont(base: pw.Font.ttf(normalData), bold: pw.Font.ttf(boldData));
  final pdf = pw.Document();
  final label = period.from + ' / ' + period.to;
  void section(String title, List<pw.Widget> body) => _addPages(pdf, theme,
    title: title, descriptor: 'Tam yönetim raporu · Gizli',
    period: label, footer: 'Yöneticiye özel', body: body);
  section('01 · Yönetim Özeti', [
    _notice('TEK PDF · Seçilen tarih aralığının tamamı. Oluşturulma: ' +
      istanbulStamp(DateTime.now().toUtc().toIso8601String()) +
      '. Windows kayıtlarının anlık görünümü; resmi mali belge değildir.'),
    pw.Row(children: [
      _metric('YEREL TAHSİLAT', _amount(localTotal), 'İadeler düşülmüş'),
      pw.SizedBox(width: 8),
      _metric('BİLİNEN ONLINE NET', _amount(onlineNet), 'Tahmini / manuel'),
      pw.SizedBox(width: 8),
      _metric('BİLİNEN GİDER', _amount(knownExpenses), 'Dahil edilen kalemler'),
    ]),
    _section('Finans özeti'),
    _table(['KALEM', 'TUTAR'], [
      ['Nakit net tahsilat', _amount(localPay.where((p) => p.method == 'Nakit').fold(0, (n,p) => n+p.amount))],
      ['Kart net tahsilat', _amount(localPay.where((p) => p.method == 'Kart').fold(0, (n,p) => n+p.amount))],
      ['Malzeme', _amount(materialTotal)], ['Maaş hak edişi', _amount(payrollTotal)],
      ['Tam aylara ait sabit gider', _amount(fixedTotal)], ['Diğer gider', _amount(otherTotal)],
      ['Bilinen gelir − bilinen gider', _amount(localTotal + onlineNet - knownExpenses)],
      ['Kesin kâr', 'Hesaplanamaz'],
    ]),
    _notice((incomplete ? 'Eksik / kısmi dönem verisi var. ' : '') +
      'Bilinen fark banka mutabakatı, vergi veya stok tüketimi sonrası kâr değildir. '
      'Maaş haftası Pazar gününe kaydedilir; aylık sabit gider ve manuel online toplam '
      'yalnızca tam ay seçilmişse toplamda yer alır. Kısmi aylarda ayrı gösterilir. '
      'Sabit giderler mevcut şablonlara dayanır; geçmiş değişiklikler tam olarak saklanmayabilir.'),
    _section('Operasyon özeti'),
    _table(['GÖSTERGE', 'ADET'], [
      ['Geçerli yerel sipariş', valid.length.toString()],
      ['Masa hesapları', valid.where((o) => o['source'] == 'Masa').length.toString()],
      ['Gel-Al hesapları', valid.where((o) => o['source'] == 'Gel-Al').length.toString()],
      ['İptal edilen yerel sipariş', orders.where((o) => o['cancelled'] == true).length.toString()],
      ['Açık yerel hesap (rapor anı)', valid.where((o) => o['closed'] != true).length.toString()],
      ['Online kayıt (test hariç)', (platformOrders.length + tgo.length).toString()],
    ]),
  ]);
  section('02 · Satış ve Yoğunluk', [
    _section('Gün gün sipariş ve tahsilat'),
    _table(['TARİH','MASA','GEL-AL','İPTAL','NET TAHSİLAT'], [
      for (final d in dates) [d,
        valid.where((o) => onIstanbulDay(o['createdAt'], d) && o['source'] == 'Masa').length.toString(),
        valid.where((o) => onIstanbulDay(o['createdAt'], d) && o['source'] == 'Gel-Al').length.toString(),
        orders.where((o) => onIstanbulDay(o['createdAt'], d) && o['cancelled'] == true).length.toString(),
        _amount(localPay.where((p) => onIstanbulDay(p.stamp, d)).fold(0, (n,p) => n+p.amount))],
    ]),
    _section('Saatlere göre yerel sipariş yoğunluğu'),
    for (var h = 0; h < 24; h++) pw.Row(children: [
      pw.SizedBox(width: 70, child: _text(h.toString().padLeft(2,'0') + ':00')),
      pw.Container(width: 240 * hourly[h] / maxHour, height: 7, color: _green),
      pw.SizedBox(width: 8), _text(hourly[h].toString()),
    ]),
    _section('Masa performansı'),
    _table(['MASA', 'HESAP', 'KAPALI', 'AÇIK', 'SİPARİŞ TUTARI'], [
      for (final n in [1,2,3,4,5]) [
        'Masa ' + n.toString(),
        valid.where((o) => o['source'] == 'Masa' && o['table'] == n).length.toString(),
        valid.where((o) => o['source'] == 'Masa' && o['table'] == n && o['closed'] == true).length.toString(),
        valid.where((o) => o['source'] == 'Masa' && o['table'] == n && o['closed'] != true).length.toString(),
        _amount(valid.where((o) => o['source'] == 'Masa' && o['table'] == n).fold(0,(v,o)=>v+orderTotalCents(o))),
      ],
    ]),
    _notice('Masa sayısı hesap açılış adedidir; aynı masanın farklı ziyaretleri ayrı sayılır. '
      'Masa aktarımı varsa son kayıtlı masa kullanılır; oturma süresi / misafir sayısı ölçülmez.'),
    _section('Ürün bazlı yerel satış'),
    _table(['ÜRÜN','ADET','SATIR TUTARI'], [
      for (final p in productRows) [p.key, field(p.value, 'qty'), money(p.value, 'amount')],
    ]),
  ]);
  section('03 · Personel Performansı', [
    _table(['PERSONEL','MASA HESABI','FARKLI MASA','GEL-AL','HESAP TUTARI','İPTAL'], [
      for (final p in staff) [field(p,'name'),field(p,'tableOrders'),
        (p['tables'] as Set<String>).length.toString(),field(p,'pickupOrders'),
        money(p,'ownedCents'),field(p,'cancelled')],
    ]),
    _section('Fiilen girilen sipariş ve ek siparişler'),
    _table(['PERSONEL','PARTİ','EK SİPARİŞ','ÜRÜN ADET','SATIR TUTARI'], [
      for (final p in staff) [field(p,'name'),field(p,'batches'),field(p,'extraBatches'),
        field(p,'items'),money(p,'lineCents')],
    ]),
    _notice('Hesap sahibi ilk siparişin personelidir; ek sipariş gerçek kayıt yapan '
      'personelin satırlarına yazılır. İki tablo farklı ölçümlerdir; toplanmaz. '
      'PC/atanmamış kayıtlar bir çalışana tahminle yazılmaz. Ücret ve satış '
      'tutarı birbirinden bağımsızdır.'),
    _section('Personel ve ücret ayarları (rapor anı)'),
    _table(['PERSONEL','ROL','DURUM','ÜCRET TÜRÜ','ÜCRET'], [
      for (final e in asMaps(state['employees'])) [field(e,'name'),field(e,'role'),
        e['active'] == true ? 'Aktif' : 'Pasif',field(e,'payType'),money(e,'payRateCents')],
    ]),
  ]);
  section('04 · Sipariş ve Tahsilat Dökümü', [
    _section('Tüm yerel hesaplar'),
    _table(['TARİH / NO','KAYNAK','SAHİP','DURUM','TOPLAM','ÖDENEN','KALAN'], [
      for (final o in orders) [istanbulStamp(o['createdAt']) + '\n#' + displayOrderNumber(o) + ' / ID ' + field(o,'id'),
        place(o), orderOwnerName(o), status(o), _amount(orderTotalCents(o)),
        _amount(orderPaidCents(o)), _amount(orderDueCents(o))],
    ]),
    _section('Ürün satırları ve ek siparişler'),
    _table(['TARİH / ID','PERSONEL','ÜRÜN','ADET','BİRİM','TUTAR','DURUM'], [
      for (final l in lines) [istanbulStamp(l['stamp']) + '\n' + field(l,'orderId') + '/' + field(l,'batch'),
        field(l,'staff'),field(l,'product'),field(l,'qty'),money(l,'unitCents'),money(l,'amount'),field(l,'status')],
    ]),
    _section('Ödeme ve iade hareketleri'),
    _table(['TARİH / ID','KAYNAK','YÖNTEM','İŞLEM','KAYDEDEN','TUTAR'], [
      for (final p in payments) [istanbulStamp(p.stamp) + '\n' + p.orderId.toString(),
        p.source,p.method,p.kind,p.staff,_amount(p.amount)],
    ]),
    _notice('Hesap toplamı ve kalan borç rapor anındaki durumdur. Tahsilat/iade '
      'işlem tarihine, ürünler parti tarihine göre listelenir. Kalıcı silinen '
      'hesaplar, kayıt dışı ödeme ve eksik zaman damgaları geri getirilemez.'),
  ]);
  section('05 · Online Siparişler', [
    _section('Platform gelirleri · Brüt / kesinti / net'),
    _table(['AY','PLATFORM','KAYNAK','ADET','BRÜT','KESİNTİ','NET'], platformRows),
    _section('Manuel aylık girişler'),
    _table(['AY','PLATFORM','TÜR','TUTAR','DURUM','NOT'], manualRows),
    _section('Online sipariş kayıtları'),
    _table(['TARİH / NO','PLATFORM','DURUM','KAYITLI TUTAR'], [
      for (final o in platformOrders) [istanbulStamp(o['createdAt']) + '\n' + displayOrderNumber(o),
        field(o,'source'),field(o,'status'),_amount(orderTotalCents(o))],
      for (final o in tgo) [istanbulStamp(o['createdAt']) + '\n' + field(o,'orderNumber'),
        'Trendyol Go',field(o,'status'),money(o,'totalCents')],
    ]),
    _section('Online ürün detayları'),
    _table(['SİPARİŞ','PLATFORM','ÜRÜN','ADET','BİRİM','DURUM'], [
      for (final o in platformOrders)
        for (final b in asMaps(o['batches']))
          for (final l in asMaps(b['lines'])) [field(o,'id'),field(o,'source'),
            field(l,'name'),field(l,'qty'),_amount(cents(l['price'])),
            l['voided'] == true ? 'İptal' : l['correction'] == true ? 'Düzeltme' : field(o,'status')],
      for (final o in tgo)
        for (final l in asMaps(o['lines'])) [field(o,'orderNumber'),'Trendyol Go',
          field(l,'name'),field(l,'qty'),money(l,'unitPriceCents'),field(o,'status')],
    ]),
    _notice('Online satış tahmini yalnızca teslim edilen gerçek siparişlere dayanır. '
      'Otomatik veri eksik olabilir; manuel toplam otomatik veriyle birleştirilmez. '
      'Platform neti banka ödemesi değildir.'),
  ]);
  section('06 · Malzeme ve Marketler', [
    _table(['MARKET','KAYIT','NET ALIŞ'], [
      for (final brand in materialStores) [brand,
        materials.where((r) => r['voided'] != true && materialPurchaseStore(r) == brand).length.toString(),
        _amount(sum(materials.where((r) => r['voided'] != true && materialPurchaseStore(r) == brand),'totalCents'))],
    ]),
    _section('Tüm malzeme kayıtları'),
    _table(['TARİH / ID','ÜRÜN / MARKET','MİKTAR','BİRİM','İNDİRİM','NET','ÖDEME'], [
      for (final r in materials) [field(r,'date') + '\n' + field(r,'id'),
        field(r,'title') + '\n' + field(r,'market') + (r['voided'] == true ? '\nİPTAL' : ''),
        isQuickMaterial(r) ? '—' : _quantity(r['quantityMilli']) + ' ' + field(r,'unit'),
        isQuickMaterial(r) ? '—' : money(r,'pricePerUnitCents'),
        money(r,'discountCents'),money(r,'totalCents'),field(r,'paymentMethod')],
    ]),
    _section('Hızlı gider tutarları ve açıklamalar'),
    _table(['ID','TARİH','MARKET','TUTARLAR / NOT'], [
      for (final r in materials.where((r) => isQuickMaterial(r) || (r['note'] ?? '').toString().isNotEmpty))
        [field(r,'id'),field(r,'date'),field(r,'market'),
          (isQuickMaterial(r) && r['amountsCents'] is List ?
            (r['amountsCents'] as List).whereType<int>().map(_amount).join(' + ') + '\n' : '') + field(r,'note')],
    ]),
    _section('Malzeme değişiklik ve iptal geçmişi'),
    _table(['ID','TARİH','İŞLEM','ÖNCEKİ TUTAR / AÇIKLAMA'], [
      for (final r in materials) ...[
        for (final h in asMaps(r['history'])) [field(r,'id'),istanbulStamp(h['changedAt']),
          'Düzenleme',money(h,'previousTotalCents')],
        if (r['voided'] == true) [field(r,'id'),istanbulStamp(r['voidedAt']),'İptal',field(r,'voidReason')],
      ],
    ]),
    _section('Market fiyat takibi · son kayıtlı referans'),
    _table(['ÜRÜN','MARKET','BİRİM','FİYAT','SON KONTROL'], [
      for (final r in trackedMarketProducts(state)) [field(r,'title'),field(r,'market'),
        field(r,'unit'),money(r,'priceCents'),istanbulStamp(r['lastCheckedAt'])],
    ]),
    _notice('Takip fiyatı satın alma maliyeti değildir. Hızlı giderde ürün miktarı '
      've stok tüketimi bilinmez; uydurulmaz.'),
  ]);
  section('07 · Maaş ve Diğer Giderler', [
    _section('Haftalık maaş kayıtları · Pazar tarihine göre'),
    _table(['PERSONEL / HAFTA','SAAT / ÜCRET','PRİM','HAK EDİŞ','AVANS','KALAN / DURUM'], [
      for (final r in payroll) [field(r,'employeeName') + '\n' + field(r,'weekStart') + ' / ' + field(r,'weekEnd'),
        _hours(r['workedMinutes']) + '\n' + field(r,'payType') + ' · ' + money(r,'rateCents'),
        money(r,'bonusCents'),money(r,'grossCents'),money(r,'advanceCents'),
        money(r,'payableCents') + '\n' + (r['paid'] == true ? 'Ödendi' : 'Ödenmedi')],
    ]),
    _section('Sabit giderler ve ödeme durumu'),
    _table(['AY','GİDER','AYLIK TUTAR','ÖDEME','RAPOR TOPLAMI'], fixedRows),
    _section('Diğer giderler'),
    _table(['TARİH','KATEGORİ','GİDER','TUTAR','ÖDEME / DURUM'], [
      for (final r in other) [field(r,'date'),field(r,'category'),field(r,'name'),
        money(r,'amountCents'),field(r,'paymentMethod') + (r['voided'] == true ? ' · İPTAL' : '')],
    ]),
    _notice('Avans hak edişin parçasıdır ve ikinci kez gider yazılmaz. '
      'Ödendi işareti gerçek banka veya kasa hareketinin yerine geçmez.'),
  ]);
  section('08 · Kasa ve Kontrol', [
    _section('Kasa oturumları (açılış veya kapanış dönemde)'),
    _table(['ID / AÇILIŞ','KAPANIŞ','AÇILIŞ TUTARI','BEKLENEN','SAYIM','FARK'], [
      for (final r in asMaps(cash['sessions']))
        if (period.includesStamp(r['openedAt']) || period.includesStamp(r['closedAt']))
          [field(r,'id') + '\n' + istanbulStamp(r['openedAt']),istanbulStamp(r['closedAt']),
            money(r,'openingCents'),money(r,'expectedCents'),money(r,'countedCents'),money(r,'differenceCents')],
    ]),
    _section('Kasa giriş / çıkışları'),
    _table(['TARİH','KASA ID','İŞLEM','KAYDEDEN','TUTAR'], [
      for (final r in asMaps(cash['movements']))
        if (period.includesStamp(r['at'])) [istanbulStamp(r['at']),field(r,'sessionId'),
          field(r,'note'),field(r,'by'),money(r,'cents')],
    ]),
    _notice('Yöneticiye özel: ücret ve işletme bilgileri içerir. Kişisel müşteri '
      'telefonu/adresi, şifreler ve API anahtarları rapora dahil edilmez. '
      'Rapor sadece mevcut, onaylı POS verilerini içerir; bekleyen Android '
      'işlemleri senkronize olmadan dahil değildir.'),
  ]);
  return pdf.save();
}
