import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/finance_logic.dart';

void main() {
  test('manual discount is per purchase and never changes source price', () {
    expect(materialDiscountCents(20100, 'Yüzde', 1000), 2010);
    expect(materialAfterDiscountCents(3000, 6700, 'Yüzde', 1000), 18090);
    expect(materialAfterDiscountCents(3000, 6700, 'Tutar', 1500), 18600);
    expect(materialDiscountCents(20100, 'Yok', 0), 0);
    expect(() => materialDiscountCents(20100, 'Yüzde', 10001),
      throwsFormatException);
    expect(() => materialDiscountCents(20100, 'Tutar', 20101),
      throwsFormatException);
    final state = <String, dynamic>{
      'marketPrices': {'tracked': [
        {'key': 'a-1', 'title': 'Nohut', 'market': 'A101',
          'priceCents': 6450},
      ]},
      'orders': <dynamic>[],
    };
    saveMaterialPurchase(state,
      date: '2026-11-22', title: 'Nohut', unit: 'kg',
      storeBrand: 'A101', marketKey: 'a-1',
      referencePriceCents: 6450, quantityMilli: 3000,
      pricePerUnitCents: 6700, discountType: 'Yüzde',
      discountValue: 1000);
    final purchase = financeRows(state, 'materials').single;
    expect(purchase['subtotalCents'], 20100);
    expect(purchase['discountCents'], 2010);
    expect(purchase['totalCents'], 18090);
    expect(financeMonthSummary(state, '2026-11').materialsCents, 18090);
    expect((state['marketPrices']['tracked'] as List).first['priceCents'],
      6450);
  });

  test('market filter is store-specific with Turkish accents and search', () {
    final state = <String, dynamic>{
      'marketPrices': {'tracked': [
        {'key': 'b-1', 'title': 'Nohut 1 Kg', 'market': 'BİM',
          'depotName': 'İstiklal', 'unit': '1 KG', 'priceCents': 5000},
        {'key': 'a-1', 'title': 'Nohut 1 Kg', 'market': 'A101',
          'depotName': 'Bağlar', 'unit': '1 KG', 'priceCents': 6000},
        {'key': 'h-1', 'title': 'Tahin 400 Gr', 'market': 'Hakmar',
          'depotName': 'Mavi Durak', 'unit': '400 GR', 'priceCents': 7000},
        {'key': 'h-2', 'title': 'Tahin 400 Gr', 'market': 'Hakmar',
          'depotName': 'Karadere', 'unit': '400 GR', 'priceCents': 7500},
        {'key': 'o-1', 'title': 'Nar Ekşisi', 'market': 'ŞOK',
          'depotName': 'Merkez', 'unit': '1 LT', 'priceCents': 5000},
        {'key': 'b-2', 'title': 'Yogurt', 'storeId': 'bim',
          'unit': '1 KG', 'priceCents': 3500},
      ]},
    };
    expect(marketTrackedForMaterial(state, 'BİM').length, 2);
    expect(marketTrackedForMaterial(state, 'BİM', query: 'NOHUT')
      .single['key'], 'b-1');
    expect(marketTrackedForMaterial(state, 'A101')
      .single['key'], 'a-1');
    expect(marketTrackedForMaterial(state, 'Hakmar', query: 'mavi')
      .single['key'], 'h-1');
    expect(marketTrackedForMaterial(state, 'Diğer')
      .single['key'], 'o-1');
    expect(marketTrackedForMaterial(state, 'BİM', query: 'unlisted'),
      isEmpty);
  });

  test('manual material still stores BİM/A101/Hakmar/Diğer identity', () {
    final state = <String, dynamic>{};
    saveMaterialPurchase(state,
      date: '2026-11-22', title: 'Domates', unit: 'kg',
      storeBrand: 'Diğer', market: 'Manav',
      quantityMilli: 2500, pricePerUnitCents: 4000);
    final entry = financeRows(state, 'materials').single;
    expect(entry['storeBrand'], 'Diğer');
    expect(entry['market'], 'Manav');
    expect(materialPurchaseStore(entry), 'Diğer');
    expect(entry['totalCents'], 10000);
    expect(materialPurchaseStore({'market': 'BİM İstiklal'}), 'BİM');
    expect(materialPurchaseStore({'market': 'Hakmar Karadere'}), 'Hakmar');
    expect(() => saveMaterialPurchase(state,
      date: '2026-11-22', title: 'Domates', unit: 'kg',
      storeBrand: 'NotAStore',
      quantityMilli: 1000, pricePerUnitCents: 4000),
      throwsFormatException);
  });

  test('market tracked package prices normalize to kg, lt, adet', () {
    final citric = marketUnitQuote({
      'unit': '100 GR', 'priceCents': 5450,
    })!;
    expect(citric.unit, 'kg');
    expect(citric.priceCents, 54500);
    expect(materialTotalCents(500, citric.priceCents), 27250);

    final chickpeas = marketUnitQuote({
      'unit': '1 KG', 'priceCents': 6450,
    })!;
    expect(chickpeas.priceCents, 6450);
    expect(materialTotalCents(3000, 6700), 20100);

    final detergent = marketUnitQuote({
      'unit': '750 ML', 'priceCents': 6250,
    })!;
    expect(detergent.unit, 'lt');
    expect(detergent.priceCents, 8333);
    expect(materialTotalCents(750, detergent.priceCents), 6250);

    final ayran = marketUnitQuote({
      'unit': '2 Adet', 'priceCents': 2950,
    })!;
    expect(ayran.unit, 'adet');
    expect(ayran.priceCents, 1475);
  });

  test('daily material price correction does not modify market watch', () {
    final state = <String, dynamic>{
      'marketPrices': {
        'tracked': [
          {'key': '0BAA|hakmar-5522',
           'title': 'Rençber Nohut 1 Kg', 'priceCents': 6450,
           'unit': '1 KG'},
        ],
      },
    };
    saveMaterialPurchase(state,
      date: '2026-11-22',
      title: 'Rençber Nohut 1 Kg', unit: 'kg',
      quantityMilli: 3000, pricePerUnitCents: 6700,
      marketKey: '0BAA|hakmar-5522', market: 'Hakmar · Mavi Durak',
      marketUnit: '1 KG', referencePriceCents: 6450);
    var rows = financeRows(state, 'materials');
    expect(rows.length, 1);
    expect(rows.first['totalCents'], 20100);
    expect(rows.first['referencePriceCents'], 6450);
    expect((state['marketPrices']['tracked'] as List).first['priceCents'], 6450);
    final id = rows.first['id'] as int;

    saveMaterialPurchase(state,
      id: id,
      date: '2026-11-22', title: 'Rençber Nohut 1 Kg',
      unit: 'kg', quantityMilli: 3000, pricePerUnitCents: 6800);
    rows = financeRows(state, 'materials');
    expect(rows.length, 1);
    expect(rows.first['totalCents'], 20400);
    expect((rows.first['history'] as List).length, 1);
    voidMaterialPurchase(state, id, 'Yanlış fiş');
    expect(financeMonthSummary(state, '2026-11').materialsCents, 0);
  });

  test('payroll links immutable employee id, snapshots rate and applies advance once', () {
    final state = <String, dynamic>{
      'employees': [
        {'id': 2, 'name': 'Mehmet', 'active': true},
      ],
      'orders': <dynamic>[],
    };
    saveEmployeePay(state, 2, 'Saatlik', 9000);
    saveWeeklyPayroll(state,
      employeeId: 2, weekStart: '2026-11-16',
      workedMinutes: 45 * 60, bonusCents: 10000,
      advanceCents: 20000);
    var payroll = financeRows(state, 'weeklyPayroll');
    expect(payroll.length, 1);
    expect(payroll.first['employeeId'], 2);
    expect(payroll.first['baseCents'], 405000);
    expect(payroll.first['grossCents'], 415000);
    expect(payroll.first['payableCents'], 395000);
    expect(financeMonthSummary(state, '2026-11').payrollCents, 415000);

    saveEmployeePay(state, 2, 'Saatlik', 10000);
    // The closed historical week is not silently recalculated by changing
    // the current employee pay rate.
    expect(financeRows(state, 'weeklyPayroll').first['grossCents'], 415000);
    markWeeklyPayrollPaid(state, 2, '2026-11-16');
    expect(financeRows(state, 'weeklyPayroll').first['paid'], true);
    expect(() => saveWeeklyPayroll(state,
      employeeId: 2, weekStart: '2026-11-16',
      workedMinutes: 47 * 60, paid: true), throwsFormatException);
    expect(financeRows(state, 'weeklyPayroll').length, 1);
  });

  test('payroll is in end-of-week month, not counted twice', () {
    final state = <String, dynamic>{
      'employees': [
        {'id': 9, 'name': 'Test', 'active': true},
      ],
      'orders': <dynamic>[],
    };
    saveEmployeePay(state, 9, 'Haftalık Sabit', 500000);
    // Monday 30 Nov -> Sunday 6 Dec, December accrued week.
    saveWeeklyPayroll(state,
      employeeId: 9, weekStart: '2026-11-30',
      workedMinutes: 0);
    expect(financeMonthSummary(state, '2026-11').payrollCents, 0);
    expect(financeMonthSummary(state, '2026-12').payrollCents, 500000);
    expect(() => saveWeeklyPayroll(state, employeeId: 9,
      weekStart: '2026-12-01', workedMinutes: 0),
      throwsFormatException);
  });

  test('monthly fixed obligations differ from paid flags and ad hoc costs', () {
    final state = <String, dynamic>{
      'employees': <dynamic>[], 'orders': <dynamic>[],
    };
    saveMonthlyFixed(state,
      category: 'Kira', name: 'Dükkan kirası',
      amountCents: 2500000, startMonth: '2026-11', dueDay: 5);
    final id = financeRows(state, 'monthlyFixed').first['id'] as int;
    markMonthlyFixedPaid(state, id, '2026-11', true);
    markMonthlyFixedPaid(state, id, '2026-11', true);
    expect(financeRows(state, 'fixedPayments').length, 1);
    expect(financeMonthSummary(state, '2026-11').fixedCents, 2500000);
    expect(financeMonthSummary(state, '2026-12').fixedCents, 2500000);
    expect(financeMonthSummary(state, '2026-10').fixedCents, 0);
    saveOtherExpense(state,
      day: '2026-11-22', category: 'Yol / Nakliye',
      name: 'Servis', amountCents: 5000, paymentMethod: 'Nakit');
    expect(financeMonthSummary(state, '2026-11').otherCents, 5000);
    expect(() => saveMonthlyFixed(state,
      category: 'Kira', name: 'Test',
      amountCents: 3000, startMonth: '2026-15'),
      throwsFormatException);
  });

  test('month summary uses actual local receipts, not open orders or duplicate payouts', () {
    final state = <String, dynamic>{
      'employees': <dynamic>[],
      'orders': [
        {
          'id': 1, 'source': 'Masa', 'closed': true,
          'payments': [
            {'amount': 300, 'method': 'Nakit',
             'createdAt': '2026-11-22T12:00:00Z'},
          ],
        },
        {
          'id': 2, 'source': 'Gel-Al', 'closed': false,
          'payments': <dynamic>[],
        },
      ],
      'trendyolGoOrders': [
        {
          'status': 'Delivered', 'createdAt': '2026-11-20T08:00:00Z',
          'totalCents': 100000, 'testPackage': false,
        },
      ],
      'settings': {
        'platformDeductionRates': {'Trendyol Go': 38.4},
      },
    };
    var summary = financeMonthSummary(state, '2026-11');
    expect(summary.localReceiptsCents, 30000);
    expect(summary.onlineKnownNetCents, 61600);
    expect(summary.knownIncomeCents, 91600);
    expect(summary.estimateCents, 91600);
    (state['settings']['platformDeductionRates'] as Map).clear();
    summary = financeMonthSummary(state, '2026-11');
    expect(summary.onlineUnpricedGrossCents, 100000);
    expect(summary.estimateCents, isNull);
  });
}
