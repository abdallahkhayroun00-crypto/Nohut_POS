import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_core/report_period.dart';
import 'package:nohut_falafel_desktop/finance_pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const period = ReportPeriod('2026-10-01', '2026-10-31');

  test('report presets include both end dates and correctly identify full months', () {
    final d = DateTime.utc(2026, 10, 15);
    final week = ReportPeriod.preset('Son 7 Gün', now: d);
    expect(week.from, '2026-10-09');
    expect(week.to, '2026-10-15');
    expect(week.fullMonth('2026-10'), false);
    expect(period.fullMonth('2026-10'), true);
    expect(period.includesStamp('2026-09-30T21:30:00Z'), true);
    expect(period.includesStamp('2026-10-31T21:00:00Z'), false);
    expect(() => const ReportPeriod('2026-10-31', '2026-10-01').validate(),
      throwsFormatException);
  });

  Map<String, dynamic> batch(int id, String staff, String stamp, String product,
    {bool voided = false}) => {
      'id': id, 'staff': staff, 'createdAt': stamp,
      'lines': [{'name': product, 'qty': 1, 'price': 140, 'voided': voided}],
    };
  Map<String, dynamic> order(int id, int table, List<Map<String, dynamic>> batches,
    {bool cancelled = false}) => {
      'id': id, 'dailyNumber': id, 'source': 'Masa', 'table': table,
      'createdAt': '2026-10-04T10:00:00Z', 'closed': true, 'cancelled': cancelled,
      'batches': batches, 'payments': <dynamic>[],
    };
  Map<String, dynamic> fixture() => {
    'employees': [
      {'id': 1, 'name': 'Mehmet', 'active': true},
      {'id': 2, 'name': 'Bassil', 'active': true},
    ],
    'orders': [
      order(1, 1, [
        batch(1, 'Mehmet', '2026-10-04T10:00:00Z', 'Falafel Dürüm'),
        batch(2, 'Bassil', '2026-10-04T11:00:00Z', 'Humus'),
        batch(3, 'Bassil', '2026-10-04T11:10:00Z', 'İptal Ürün', voided: true),
      ]),
      order(2, 1, [batch(1, 'Mehmet', '2026-10-04T13:00:00Z', 'Falafel Dürüm')]),
      order(3, 2, [batch(1, 'Bassil', '2026-10-04T14:00:00Z', 'Humus')], cancelled: true),
    ],
    'finance': {
      'materials': [
        {'id': 1, 'recordType': 'quick', 'date': '2026-10-04',
         'title': 'Hızlı Malzeme Gideri', 'storeBrand': 'BİM', 'market': 'BİM',
         'amountsCents': [5000, 6000, 30000], 'totalCents': 41000,
         'discountCents': 0, 'voided': false},
      ],
      'weeklyPayroll': [
        {'id': 1, 'employeeName': 'Mehmet', 'weekStart': '2026-10-05',
         'weekEnd': '2026-10-11', 'workedMinutes': 2400, 'rateCents': 10000,
         'grossCents': 400000, 'advanceCents': 5000, 'payableCents': 395000,
         'paid': false},
      ],
      'manualPlatformSales': [
        {'source': 'Migros Yemek', 'month': '2026-10', 'kind': 'Net',
         'amountCents': 90000, 'voided': false},
      ],
    },
  };

  test('staff report separates opened table accounts, distinct tables and extra batches', () {
    final facts = managementReportFacts(fixture(), period);
    final staff = facts['staff'] as List<Map<String,dynamic>>;
    final mehmet = staff.firstWhere((p) => p['name'] == 'Mehmet');
    final bassil = staff.firstWhere((p) => p['name'] == 'Bassil');
    expect(mehmet['tableOrders'], 2);
    expect(mehmet['tables'], {'1'});
    expect(mehmet['ownedCents'], 42000);
    expect(bassil['tableOrders'], 0);
    expect(bassil['extraBatches'], 2);
    expect(bassil['items'], 1);
    expect(bassil['cancelled'], 1);
    expect((facts['valid'] as List).length, 2);
    expect((facts['products'] as Map).containsKey('İptal Ürün'), false);
  });

  test('one management PDF renders all sections for populated and empty records', () async {
    for (final state in [fixture(), <String,dynamic>{'orders': <dynamic>[]}]) {
      final bytes = await generateManagementPdf(state, period);
      expect(bytes, isA<Uint8List>());
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(bytes.length, greaterThan(5000));
    }
  });
}
