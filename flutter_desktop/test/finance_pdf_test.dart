import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/finance_pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final request = FinancePdfRequest(
    kind: FinancePdfKind.monthly,
    month: '2026-11',
    day: '2026-11-22',
    weekStart: '2026-11-16',
  );

  test('PDF filenames and report types are deterministic', () {
    expect(request.suggestedName, 'Nohut_Aylik_Finans_2026-11.pdf');
    expect(request.title, 'Aylık Finans Özeti');
    expect(FinancePdfRequest(
      kind: FinancePdfKind.materials,
      month: request.month, day: request.day,
      weekStart: request.weekStart).suggestedName,
      'Nohut_Gunluk_Malzeme_2026-11-22.pdf');
    expect(FinancePdfRequest(
      kind: FinancePdfKind.payroll,
      month: request.month, day: request.day,
      weekStart: request.weekStart).suggestedName,
      'Nohut_Haftalik_Maas_2026-11-16.pdf');
  });

  test('invalid period is blocked before writing a PDF', () {
    expect(() => FinancePdfRequest(
      kind: FinancePdfKind.monthly, month: '2026-13',
      day: request.day, weekStart: request.weekStart).validate(),
      throwsFormatException);
    expect(() => FinancePdfRequest(
      kind: FinancePdfKind.payroll, month: request.month,
      day: request.day, weekStart: '2026-11-17').validate(),
      throwsFormatException);
  });

  test('all three A4 reports generate nonempty PDF data from actual record schema', () async {
    final state = <String, dynamic>{
      'orders': <dynamic>[],
      'trendyolGoOrders': [
        {'status': 'Delivered', 'createdAt': '2026-11-20T12:00:00Z',
         'totalCents': 105000, 'testPackage': false},
      ],
      'settings': {
        'platformDeductionRates': {'Trendyol Go': 38.4},
      },
      'finance': {
        'materials': [
          {'id': 3, 'date': '2026-11-22',
           'recordType': 'quick', 'title': 'Hızlı Malzeme Gideri',
           'storeBrand': 'Hakmar', 'market': 'Hakmar',
           'amountsCents': [5000, 6000, 30000],
           'subtotalCents': 41000, 'discountCents': 0,
           'totalCents': 41000, 'voided': false},
          {'id': 1, 'date': '2026-11-22', 'title': 'Nohut 1 Kg',
           'storeBrand': 'BİM', 'market': 'BİM',
           'quantityMilli': 2500, 'unit': 'kg',
           'pricePerUnitCents': 6700, 'subtotalCents': 16750,
           'discountCents': 1675, 'totalCents': 15075,
           'voided': false},
          {'id': 2, 'date': '2026-11-22', 'title': 'Lavaş',
           'storeBrand': 'A101', 'market': 'A101',
           'quantityMilli': 5000, 'unit': 'adet',
           'pricePerUnitCents': 2500, 'subtotalCents': 12500,
           'discountCents': 0, 'totalCents': 12500,
           'voided': false},
        ],
        'weeklyPayroll': [
          {'id': 1, 'employeeId': 1, 'employeeName': 'Test Personel A',
           'weekStart': '2026-11-16', 'weekEnd': '2026-11-22',
           'payType': 'Saatlik', 'workedMinutes': 40*60,
           'rateCents': 10000, 'grossCents': 400000,
           'advanceCents': 10000, 'payableCents': 390000, 'paid': false},
        ],
        'monthlyFixed': [
          {'id': 1, 'category': 'Kira', 'name': 'Dükkan Kirası',
           'amountCents': 2500000, 'active': true,
           'startMonth': '2026-11'},
        ],
        'fixedPayments': <dynamic>[],
        'other': <dynamic>[],
      },
    };
    for (final kind in FinancePdfKind.values) {
      final bytes = await generateFinancePdf(state,
        FinancePdfRequest(
          kind: kind,
          month: request.month,
          day: request.day,
          weekStart: request.weekStart,
        ));
      expect(bytes, isA<Uint8List>());
      expect(bytes.length, greaterThan(3500));
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    }
  });

  test('monthly PDF generation includes manually entered source records', () async {
    final state = <String, dynamic>{
      'orders': <dynamic>[],
      'settings': {'platformDeductionRates': {'Migros Yemek': 25.0}},
      'finance': {'manualPlatformSales': [
        {'id': 1, 'source': 'Yemeksepeti', 'month': '2026-11',
         'kind': 'Net', 'amountCents': 90000, 'voided': false},
        {'id': 2, 'source': 'Migros Yemek', 'month': '2026-11',
         'kind': 'Brüt', 'amountCents': 100000, 'voided': false},
      ]},
    };
    final bytes = await generateFinancePdf(state, request);
    expect(bytes.length, greaterThan(3000));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('reports handle zero records and unknown platform fee', () async {
    final state = <String, dynamic>{
      'orders': <dynamic>[],
      'settings': <String, dynamic>{},
    };
    final bytes = await generateFinancePdf(state, request);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(2500));
  });
}
