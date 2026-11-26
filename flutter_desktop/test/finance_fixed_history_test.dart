import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/finance_logic.dart';
import 'package:nohut_falafel_desktop/order_reporting.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';

String shift(String month, int by) {
  final y = int.parse(month.substring(0, 4)), m = int.parse(month.substring(5));
  final d = DateTime.utc(y, m + by, 1);
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';
}

int fixedTotal(Json s, String month) =>
    fixedDueRows(s, month).fold<int>(0, (n, r) => n + r.$2);

void main() {
  final now = istanbulDay(DateTime.now().toUtc()).substring(0, 7);
  final past = shift(now, -2), next = shift(now, 1);

  Json rent() {
    final s = emptyPosState();
    saveMonthlyFixed(s, category: financeFixedCategories.first, name: 'Kira',
      amountCents: 2000000, startMonth: past);
    return s;
  }

  test('changing the amount only affects this month and later', () {
    final s = rent();
    final id = financeRows(s, 'monthlyFixed').single['id'] as int;
    saveMonthlyFixed(s, id: id, category: financeFixedCategories.first,
      name: 'Kira', amountCents: 2500000, startMonth: past);
    expect(fixedTotal(s, past), 2000000);
    expect(fixedTotal(s, shift(now, -1)), 2000000);
    expect(fixedTotal(s, now), 2500000);
    expect(fixedTotal(s, next), 2500000);
    expect(financeMonthSummary(s, past).fixedCents, 2000000);
  });

  test('deactivating keeps past months and this month, stops later ones', () {
    final s = rent();
    final id = financeRows(s, 'monthlyFixed').single['id'] as int;
    saveMonthlyFixed(s, id: id, category: financeFixedCategories.first,
      name: 'Kira', amountCents: 2000000, startMonth: past, active: false);
    expect(fixedTotal(s, past), 2000000);
    expect(fixedTotal(s, now), 2000000);
    expect(fixedTotal(s, next), 0);
  });

  test('reactivating restarts from this month without filling the gap', () {
    final s = emptyPosState();
    saveMonthlyFixed(s, category: financeFixedCategories.first, name: 'Kira',
      amountCents: 1000000, startMonth: now);
    final id = financeRows(s, 'monthlyFixed').single['id'] as int;
    saveMonthlyFixed(s, id: id, category: financeFixedCategories.first,
      name: 'Kira', amountCents: 1000000, startMonth: now, active: false);
    saveMonthlyFixed(s, id: id, category: financeFixedCategories.first,
      name: 'Kira', amountCents: 1000000, startMonth: now, active: true);
    expect(fixedTotal(s, shift(now, -1)), 0);
    expect(fixedTotal(s, now), 1000000);
    expect(fixedTotal(s, next), 1000000);
  });

  test('a paid month keeps the amount that was paid', () {
    final s = rent();
    final id = financeRows(s, 'monthlyFixed').single['id'] as int;
    markMonthlyFixedPaid(s, id, now, true);
    saveMonthlyFixed(s, id: id, category: financeFixedCategories.first,
      name: 'Kira', amountCents: 3000000, startMonth: past);
    expect(fixedTotal(s, now), 2000000);
    expect(fixedTotal(s, next), 3000000);
  });

  test('older records without history behave as before', () {
    final s = emptyPosState();
    financeBook(s)['monthlyFixed'] = [
      {'id': 1, 'category': 'Kira', 'name': 'Eski', 'amountCents': 500000,
        'startMonth': past, 'dueDay': 1, 'active': true},
      {'id': 2, 'category': 'Kira', 'name': 'Pasif', 'amountCents': 700000,
        'startMonth': past, 'dueDay': 1, 'active': false},
    ];
    expect(fixedTotal(s, now), 500000);
    expect(fixedTotal(s, shift(past, -1)), 0);
  });

  test('expenses cannot be dated in the future', () {
    final s = emptyPosState();
    final tomorrow = DateTime.parse(istanbulDay(DateTime.now().toUtc()))
        .add(const Duration(days: 1)).toIso8601String().substring(0, 10);
    expect(() => saveOtherExpense(s, day: tomorrow, category: 'Yol / Nakliye',
      name: 'Taksi', amountCents: 10000, paymentMethod: 'Nakit'),
      throwsA(isA<FormatException>().having((e) => e.message, 'message',
        'Gider tarihi gelecekte olamaz.')));
    expect(() => saveQuickMaterialPurchase(s, date: tomorrow,
      storeBrand: 'BİM', amountsCents: [5000]), throwsFormatException);
  });

  test('month names are shown in Turkish', () {
    expect(financeMonthLabel('2026-11'), 'Kasım 2026');
    expect(financeMonthLabel('2027-01'), 'Ocak 2027');
    expect(financeMonthLabel('bad'), 'bad');
  });
}
