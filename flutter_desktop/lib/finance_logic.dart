import 'dart:math' as math;

import 'package:nohut_core/nohut_core.dart';
export 'package:nohut_core/nohut_core.dart' show materialStores, financeMethods, quickMaterialTotalCents;

import 'market_prices.dart';

import 'operations.dart';
import 'order_reporting.dart';
import 'platform_net.dart';
import 'pos_logic.dart';

/// Local operational finance records are separate from sales and cash register.
/// Every amount is stored in kuruş; no financial operations send bank transfers.
Json financeBook(Json state) {
  if (state['finance'] is! Map) {
    state['finance'] = <String, dynamic>{};
  }
  final book = state['finance'] as Json;
  for (final key in const [
    'materials', 'weeklyPayroll', 'monthlyFixed', 'fixedPayments', 'other',
    'manualPlatformSales'
  ]) {
    if (book[key] is! List) book[key] = <dynamic>[];
  }
  return book;
}

List<Json> financeRows(Json state, String key) {
  final book = state['finance'];
  if (book is! Map) return <Json>[];
  return asMaps(book[key]);
}


String materialStoreFromBrand(String brand) {
  switch (marketBrandKey(brand)) {
    case 'bim':
      return 'BİM';
    case 'a101':
      return 'A101';
    case 'hakmar':
      return 'Hakmar';
    default:
      return 'Diğer';
  }
}

/// Historic entries without storeBrand are inferred from their recorded
/// market label; new manual entries preserve the chosen brand explicitly.
String materialPurchaseStore(Json purchase) {
  final brand = (purchase['storeBrand'] ?? '').toString();
  if (materialStores.contains(brand)) return brand;
  return materialStoreFromBrand((purchase['market'] ?? '').toString());
}

String _marketSearchText(String text) => text.trim()
  .replaceAll('İ', 'i').replaceAll('I', 'i')
  .toLowerCase().replaceAll('ı', 'i');

/// Only Market Fiyat Takibi products for the selected supermarket.
/// Diğer includes other retailer products; manual input always remains
/// available, even when this list is empty or price refresh is offline.
List<Json> marketTrackedForMaterial(
  Json state, String store, {String query = ''}
) {
  if (!materialStores.contains(store)) return <Json>[];
  final q = _marketSearchText(query);
  final entries = trackedMarketProducts(state).where((p) {
    final raw = (p['market'] ?? '').toString();
    var brand = materialStoreFromBrand(raw);
    if (raw.trim().isEmpty && p['storeId'] is String) {
      final place = nohutStorePlaces.where(
        (s) => s.id == p['storeId']).firstOrNull;
      if (place != null) brand = materialStoreFromBrand(place.market);
    }
    if (brand != store) return false;
    if (q.isEmpty) return true;
    return _marketSearchText([
      p['title'], p['market'], p['depotName'], p['unit'],
    ].join(' ')).contains(q);
  }).toList();
  entries.sort((a, b) => _marketSearchText((a['title'] ?? '').toString())
    .compareTo(_marketSearchText((b['title'] ?? '').toString())));
  final seen = <String>{};
  return [
    for (final p in entries)
      if (seen.add((p['key'] ?? '').toString()) &&
          (p['key'] ?? '').toString().isNotEmpty)
        p,
  ];
}

const financeUnits = <String>['kg', 'lt', 'adet', 'paket'];
const financeFixedCategories = <String>[
  'Kira', 'Muhasebe', 'SGK', 'Elektrik / Su / Doğalgaz',
  'İnternet', 'Diğer',
];
const financeOtherCategories = <String>[
  'Yol / Nakliye', 'Temizlik', 'Bakım / Onarım',
  'Elektrik / Su / Doğalgaz', 'Diğer',
];

int _nextId(Iterable<Json> items) =>
    items.fold<int>(0, (n, entry) =>
      entry['id'] is int ? math.max(n, entry['id'] as int) : n) + 1;

void _validateCents(int value, {bool allowZero = false}) {
  if (value < (allowZero ? 0 : 1) || value > 100000000000) {
    throw const FormatException('Tutar geçersiz.');
  }
}

void _checkDay(String day) {
  if (!validBusinessDate(day)) {
    throw const FormatException('Tarih YYYY-MM-DD olmalı.');
  }
}

bool validFinanceMonth(String value) =>
  RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(value);

String _stamp() => DateTime.now().toUtc().toIso8601String();

class MarketUnitQuote {
  const MarketUnitQuote(this.unit, this.priceCents, this.label);
  final String unit;
  /// Market price converted from package to kg, liter, piece or package.
  final int priceCents;
  final String label;
}

/// 100 GR for 54.50 TL -> 545.00 TL/kg.
/// Reference does not modify the Market Fiyat Takibi price.
MarketUnitQuote? marketUnitQuote(Json tracked) {
  final price = tracked['priceCents'];
  if (price is! int || price <= 0) return null;
  final original = (tracked['unit'] ?? '').toString().trim();
  final match = RegExp(r'(\d+(?:[.,]\d+)?)\s*(KG|GR|G|LT|L|ML|ADET|AD|PAKET)',
      caseSensitive: false).firstMatch(original);
  if (match == null) {
    return MarketUnitQuote('paket', price, original.isEmpty ? 'Paket' : original);
  }
  final quantity = double.tryParse(match.group(1)!.replaceAll(',', '.'));
  if (quantity == null || !quantity.isFinite || quantity <= 0) return null;
  final code = match.group(2)!.toUpperCase();
  final String unit;
  final double packageInUnits;
  if (code == 'KG') {
    unit = 'kg'; packageInUnits = quantity;
  } else if (code == 'GR' || code == 'G') {
    unit = 'kg'; packageInUnits = quantity / 1000;
  } else if (code == 'LT' || code == 'L') {
    unit = 'lt'; packageInUnits = quantity;
  } else if (code == 'ML') {
    unit = 'lt'; packageInUnits = quantity / 1000;
  } else if (code == 'ADET' || code == 'AD') {
    unit = 'adet'; packageInUnits = quantity;
  } else {
    unit = 'paket'; packageInUnits = quantity;
  }
  final normalized = (price / packageInUnits).round();
  if (normalized < 1 || normalized > 100000000000) return null;
  return MarketUnitQuote(unit, normalized, original);
}

int materialTotalCents(int quantityMilli, int pricePerUnitCents) =>
  ((quantityMilli * pricePerUnitCents) / 1000).round();

/// Manual, purchase-specific discount. Never change market watch prices.
/// Tutar values are kuruş; Yüzde values are basis points (100 = 1%).
const materialDiscountTypes = <String>['Yok', 'Tutar', 'Yüzde'];

int materialDiscountCents(int grossCents, String type, int value) {
  if (grossCents < 0 || !materialDiscountTypes.contains(type) || value < 0) {
    throw const FormatException('İndirim bilgileri geçersiz.');
  }
  if (type == 'Yok') {
    if (value != 0) throw const FormatException('İndirim tipi seçin.');
    return 0;
  }
  if (type == 'Yüzde') {
    if (value > 10000) {
      throw const FormatException('İndirim yüzdesi %100 üzerinde olamaz.');
    }
    return ((grossCents * value) / 10000).round();
  }
  if (value > grossCents) {
    throw const FormatException('İndirim ara toplamı aşamaz.');
  }
  return value;
}

int materialAfterDiscountCents(
  int quantityMilli, int pricePerUnitCents, String discountType,
  int discountValue,
) {
  final gross = materialTotalCents(quantityMilli, pricePerUnitCents);
  return gross - materialDiscountCents(gross, discountType, discountValue);
}


void saveMaterialPurchase(
  Json state, {
  int? id,
  required String date,
  required String title,
  required String unit,
  required int quantityMilli,
  required int pricePerUnitCents,
  String marketKey = '',
  String storeBrand = 'Diğer',
  String market = '',
  String marketUnit = '',
  int? referencePriceCents,
  String paymentMethod = 'Nakit',
  String discountType = 'Yok',
  int discountValue = 0,
  String note = '',
}) {
  _checkDay(date);
  if (!materialStores.contains(storeBrand)) {
    throw const FormatException('Market seçimi geçersiz.');
  }
  if (title.trim().isEmpty || title.length > 160 ||
      !financeUnits.contains(unit) ||
      quantityMilli <= 0 || quantityMilli > 100000000 ||
      !financeMethods.contains(paymentMethod) || note.length > 500) {
    throw const FormatException('Malzeme adı, miktarı veya ödeme bilgisi geçersiz.');
  }
  _validateCents(pricePerUnitCents);
  final gross = materialTotalCents(quantityMilli, pricePerUnitCents);
  _validateCents(gross);
  final discountCents = materialDiscountCents(gross,
    discountType, discountValue);
  final total = gross - discountCents;
  _validateCents(total, allowZero: true);
  final rows = financeBook(state)['materials'] as List;
  final before = id == null ? null : rows.cast<Map>().where((r) => r['id'] == id).firstOrNull;
  if (id != null && before == null) {
    throw const FormatException('Malzeme kaydı bulunamadı.');
  }
  if (before?['voided'] == true) {
    throw const FormatException('İptal edilen malzeme düzenlenemez.');
  }
  if (before?['recordType'] == 'quick') {
    throw const FormatException('Hızlı gideri kendi formundan düzenleyin.');
  }
  final recorded = <String, dynamic>{
    'id': id ?? _nextId(asMaps(rows)),
    'date': date,
    'title': title.trim(),
    'unit': unit,
    'quantityMilli': quantityMilli,
    'pricePerUnitCents': pricePerUnitCents,
    'subtotalCents': gross,
    'discountType': discountType,
    'discountValue': discountValue,
    'discountCents': discountCents,
    'totalCents': total,
    'marketKey': marketKey,
    'storeBrand': storeBrand,
    'market': market,
    'marketUnit': marketUnit,
    if (referencePriceCents != null)
      'referencePriceCents': referencePriceCents,
    'paymentMethod': paymentMethod,
    'note': note.trim(),
    'createdAt': before?['createdAt'] ?? _stamp(),
    'updatedAt': _stamp(),
    'voided': false,
    'history': [
      ...asMaps(before?['history']),
      if (before != null) {
        'changedAt': _stamp(),
        'previousTotalCents': before['totalCents'],
        'previousDiscountCents': before['discountCents'] ?? 0,
        'previousUnitPriceCents': before['pricePerUnitCents'],
        'previousQuantityMilli': before['quantityMilli'],
      }
    ],
  };
  if (before != null) {
    rows[rows.indexOf(before)] = recorded;
  } else {
    rows.add(recorded);
  }
}

/// A receipt/market total without item quantities. It shares the material
/// expense ledger, so summaries count it once and never fabricate stock.
bool isQuickMaterial(Json entry) => entry['recordType'] == 'quick';

void saveQuickMaterialPurchase(Json state, {
  int? id,
  required String date,
  required String storeBrand,
  required List<int> amountsCents,
  String market = '',
  String paymentMethod = 'Nakit',
  String note = '',
}) {
  _checkDay(date);
  if (date.compareTo(istanbulDay(DateTime.now().toUtc())) > 0) {
    throw const FormatException('Alış tarihi gelecekte olamaz.');
  }
  if (!materialStores.contains(storeBrand) ||
      !financeMethods.contains(paymentMethod) ||
      market.length > 160 || note.length > 500) {
    throw const FormatException('Market veya gider bilgisi geçersiz.');
  }
  final total = quickMaterialTotalCents(amountsCents);
  final rows = financeBook(state)['materials'] as List;
  final before = id == null ? null : rows.cast<Map>()
    .where((r) => r['id'] == id).firstOrNull;
  if (id != null && (before == null ||
      before['recordType'] != 'quick' || before['voided'] == true)) {
    throw const FormatException('Aktif hızlı gider bulunamadı.');
  }
  final entry = <String, dynamic>{
    'id': id ?? _nextId(asMaps(rows)),
    'recordType': 'quick',
    'date': date,
    'title': 'Hızlı Malzeme Gideri',
    'storeBrand': storeBrand,
    'market': storeBrand == 'Diğer' && market.trim().isNotEmpty
      ? market.trim() : storeBrand,
    'amountsCents': List<int>.of(amountsCents),
    'subtotalCents': total,
    'discountCents': 0,
    'totalCents': total,
    'paymentMethod': paymentMethod,
    'note': note.trim(),
    'createdAt': before?['createdAt'] ?? _stamp(),
    'updatedAt': _stamp(),
    'voided': false,
    'history': [
      ...asMaps(before?['history']),
      if (before != null) {
        'changedAt': _stamp(),
        'previousDate': before['date'],
        'previousStoreBrand': before['storeBrand'],
        'previousMarket': before['market'],
        'previousAmountsCents': before['amountsCents'],
        'previousTotalCents': before['totalCents'],
        'previousPaymentMethod': before['paymentMethod'],
        'previousNote': before['note'],
      },
    ],
  };
  if (before == null) {
    rows.add(entry);
  } else {
    rows[rows.indexOf(before)] = entry;
  }
}

void voidMaterialPurchase(Json state, int id, String reason) {
  if (reason.trim().isEmpty) throw const FormatException('İptal nedeni gerekli.');
  final rows = financeBook(state)['materials'] as List;
  final item = rows.cast<Map>().where((r) => r['id'] == id).firstOrNull;
  if (item == null || item['voided'] == true) {
    throw const FormatException('Aktif malzeme kaydı bulunamadı.');
  }
  item['voided'] = true;
  item['voidReason'] = reason.trim();
  item['voidedAt'] = _stamp();
}

void saveEmployeePay(Json state, int employeeId, String type, int rateCents) {
  if (type != 'Saatlik' && type != 'Haftalık Sabit') {
    throw const FormatException('Ücret türü geçersiz.');
  }
  _validateCents(rateCents);
  final employees = state['employees'];
  if (employees is! List) throw const FormatException('Personel kaydı yok.');
  final person = employees.cast<Map>()
      .where((p) => p['id'] == employeeId).firstOrNull;
  if (person == null) throw const FormatException('Personel bulunamadı.');
  person['payType'] = type;
  person['payRateCents'] = rateCents;
}

String weekStartOf(String day) {
  _checkDay(day);
  final d = DateTime.parse(day);
  final start = d.subtract(Duration(days: d.weekday - DateTime.monday));
  return start.toIso8601String().substring(0, 10);
}

String weekEndOf(String weekStart) {
  if (weekStartOf(weekStart) != weekStart) {
    throw const FormatException('Hafta başlangıcı pazartesi olmalı.');
  }
  return DateTime.parse(weekStart).add(const Duration(days: 6))
    .toIso8601String().substring(0, 10);
}

void saveWeeklyPayroll(
  Json state, {
  required int employeeId,
  required String weekStart,
  required int workedMinutes,
  int bonusCents = 0,
  int advanceCents = 0,
  bool paid = false,
}) {
  final end = weekEndOf(weekStart);
  if (workedMinutes < 0 || workedMinutes > 10080) {
    throw const FormatException('Haftalık çalışma saati geçersiz.');
  }
  _validateCents(bonusCents, allowZero: true);
  _validateCents(advanceCents, allowZero: true);
  final person = asMaps(state['employees'])
      .where((p) => p['id'] == employeeId).firstOrNull;
  if (person == null) throw const FormatException('Personel bulunamadı.');
  final rate = person['payRateCents'];
  final type = person['payType'];
  if (rate is! int || rate < 1 ||
      (type != 'Saatlik' && type != 'Haftalık Sabit')) {
    throw const FormatException('Ayarlar → Personel bölümünden ücret belirleyin.');
  }
  final base = type == 'Saatlik'
      ? (rate * workedMinutes / 60).round() : rate;
  final gross = base + bonusCents;
  _validateCents(gross);
  if (advanceCents > gross) {
    throw const FormatException('Avans, hak edilen ücretten büyük olamaz.');
  }
  final rows = financeBook(state)['weeklyPayroll'] as List;
  final existing = rows.cast<Map>().where((r) =>
      r['employeeId'] == employeeId && r['weekStart'] == weekStart).firstOrNull;
  if (existing?['paid'] == true) {
    if (!paid || existing?['workedMinutes'] != workedMinutes ||
        existing?['bonusCents'] != bonusCents ||
        existing?['advanceCents'] != advanceCents ||
        existing?['grossCents'] != gross) {
      throw const FormatException(
        'Ödenmiş maaş değiştirilemez. Yönetici muhasebe düzeltmesi gerekli.');
    }
  }
  final entry = <String, dynamic>{
    'id': existing?['id'] ?? _nextId(asMaps(rows)),
    'employeeId': employeeId,
    'employeeName': person['name'],
    'weekStart': weekStart,
    'weekEnd': end,
    'payType': type,
    'rateCents': rate,
    'workedMinutes': workedMinutes,
    'baseCents': base,
    'bonusCents': bonusCents,
    'advanceCents': advanceCents,
    'grossCents': gross, // Expense incl. advance, once.
    'payableCents': gross - advanceCents, // Remainder to hand over.
    'paid': paid,
    'paidAt': paid ? (existing?['paidAt'] ?? _stamp()) : null,
    'createdAt': existing?['createdAt'] ?? _stamp(),
    'updatedAt': _stamp(),
  };
  if (existing == null) {
    rows.add(entry);
  } else {
    rows[rows.indexOf(existing)] = entry;
  }
}

void markWeeklyPayrollPaid(Json state, int employeeId, String weekStart) {
  final rows = financeBook(state)['weeklyPayroll'] as List;
  final existing = rows.cast<Map>().where((r) =>
    r['employeeId'] == employeeId && r['weekStart'] == weekStart).firstOrNull;
  if (existing == null) throw const FormatException('Haftalık maaş bulunamadı.');
  if (existing['paid'] == true) return;
  existing['paid'] = true;
  existing['paidAt'] = _stamp();
  existing['updatedAt'] = _stamp();
}

void saveMonthlyFixed(
  Json state, {
  int? id,
  required String category,
  required String name,
  required int amountCents,
  required String startMonth,
  int dueDay = 1,
  bool active = true,
}) {
  if (!financeFixedCategories.contains(category) ||
      name.trim().isEmpty || name.length > 120 ||
      !validFinanceMonth(startMonth) || dueDay < 1 || dueDay > 28) {
    throw const FormatException('Aylık gider adı, kategorisi veya tarihi geçersiz.');
  }
  _validateCents(amountCents);
  final rows = financeBook(state)['monthlyFixed'] as List;
  final previous = id == null ? null :
      rows.cast<Map>().where((r) => r['id'] == id).firstOrNull;
  if (id != null && previous == null) {
    throw const FormatException('Sabit gider bulunamadı.');
  }
  final record = <String, dynamic>{
    'id': id ?? _nextId(asMaps(rows)), 'category': category,
    'name': name.trim(), 'amountCents': amountCents,
    'startMonth': startMonth, 'dueDay': dueDay, 'active': active,
    'createdAt': previous?['createdAt'] ?? _stamp(), 'updatedAt': _stamp(),
  };
  if (previous == null) {
    rows.add(record);
  } else {
    rows[rows.indexOf(previous)] = record;
  }
}

void markMonthlyFixedPaid(Json state, int id, String month, bool paid) {
  if (!validFinanceMonth(month)) throw const FormatException('Ay geçersiz.');
  final book = financeBook(state);
  final template = asMaps(book['monthlyFixed']).where((r) =>
    r['id'] == id && r['active'] == true &&
    (r['startMonth'] as String).compareTo(month) <= 0).firstOrNull;
  if (template == null) {
    throw const FormatException('Bu ay için aktif sabit gider yok.');
  }
  final rows = book['fixedPayments'] as List;
  rows.removeWhere((r) => r is Map &&
    r['templateId'] == id && r['month'] == month);
  if (paid) {
    rows.add({'templateId': id, 'month': month,
      'amountCents': template['amountCents'], 'paidAt': _stamp()});
  }
}

void saveOtherExpense(
  Json state, {
  required String day,
  required String category,
  required String name,
  required int amountCents,
  required String paymentMethod,
}) {
  _checkDay(day);
  if (!financeOtherCategories.contains(category) ||
      name.trim().isEmpty || name.length > 120 ||
      !financeMethods.contains(paymentMethod)) {
    throw const FormatException('Gider bilgileri geçersiz.');
  }
  _validateCents(amountCents);
  final rows = financeBook(state)['other'] as List;
  rows.add({
    'id': _nextId(asMaps(rows)), 'date': day,
    'category': category, 'name': name.trim(),
    'amountCents': amountCents, 'paymentMethod': paymentMethod,
    'createdAt': _stamp(), 'voided': false,
  });
}

void voidOtherExpense(Json state, int id, String reason) {
  if (reason.trim().isEmpty) throw const FormatException('İptal nedeni gerekli.');
  final item = (financeBook(state)['other'] as List).cast<Map>()
    .where((r) => r['id'] == id && r['voided'] != true).firstOrNull;
  if (item == null) throw const FormatException('Gider bulunamadı.');
  item['voided'] = true;
  item['voidReason'] = reason.trim();
  item['voidedAt'] = _stamp();
}

/// A month-long summary entered by a manager when the platform has no
/// confirmed automatic sales. Keeping one active record per platform/month
/// avoids accidentally adding repeated monthly totals together.
const manualIncomePlatforms = <String>['Yemeksepeti', 'Migros Yemek'];
const manualIncomeTypes = <String>['Brüt', 'Net'];

Json? manualPlatformIncome(Json state, String source, String month) =>
  financeRows(state, 'manualPlatformSales').where((item) =>
    item['source'] == source &&
    item['month'] == month && item['voided'] != true).firstOrNull;

/// The presence of any real delivered records means the manual *monthly*
/// fallback is superseded, never summed with those records.
bool platformHasAutomaticSales(Json state, String source, String month) {
  if (!manualIncomePlatforms.contains(source) ||
      !validFinanceMonth(month)) return false;
  bool inMonth(String stamp) {
    final date = DateTime.tryParse(stamp);
    return date != null && istanbulDay(date).startsWith(month);
  }
  return deliveryNetEstimates(state, inMonth, source: source)
    .any((value) => value.orderCount > 0);
}

void saveManualPlatformIncome(Json state, {
  required String source,
  required String month,
  required String kind,
  required int amountCents,
  String note = '',
}) {
  if (!manualIncomePlatforms.contains(source) ||
      !manualIncomeTypes.contains(kind) ||
      !validFinanceMonth(month) || note.length > 500) {
    throw const FormatException('Platform, dönem veya tutar türü geçersiz.');
  }
  _validateCents(amountCents);
  if (platformHasAutomaticSales(state, source, month)) {
    throw const FormatException(
      'Bu platformda otomatik sipariş var. Çift saymamak için '
      'manuel aylık toplam kaydedilemez.');
  }
  final rows = financeBook(state)['manualPlatformSales'] as List;
  final existing = rows.cast<Map>().where((r) =>
    r['source'] == source && r['month'] == month &&
    r['voided'] != true).firstOrNull;
  final entry = <String, dynamic>{
    'id': existing?['id'] ?? _nextId(asMaps(rows)),
    'source': source,
    'month': month,
    'kind': kind,
    'amountCents': amountCents,
    'note': note.trim(),
    'createdAt': existing?['createdAt'] ?? _stamp(),
    'updatedAt': _stamp(),
    'voided': false,
    'history': [
      ...asMaps(existing?['history']),
      if (existing != null) {
        'changedAt': _stamp(),
        'kind': existing['kind'],
        'amountCents': existing['amountCents'],
      },
    ],
  };
  if (existing == null) {
    rows.add(entry);
  } else {
    rows[rows.indexOf(existing)] = entry;
  }
}

void voidManualPlatformIncome(Json state, String source, String month) {
  final item = manualPlatformIncome(state, source, month);
  if (item == null) throw const FormatException('Manuel kayıt bulunamadı.');
  final rows = financeBook(state)['manualPlatformSales'] as List;
  final entry = rows.cast<Map>().where((r) => r['id'] == item['id'])
    .firstOrNull;
  if (entry == null) throw const FormatException('Kayıt bulunamadı.');
  entry['voided'] = true;
  entry['voidedAt'] = _stamp();
}

class FinancePlatformFigure {
  const FinancePlatformFigure({
    required this.source, required this.origin, required this.grossCents,
    required this.deductionCents, required this.netCents,
    required this.unknownGrossCents, required this.automaticOrders,
    required this.inputKind,
  });
  final String source, origin;
  final int? grossCents, deductionCents, netCents;
  final int unknownGrossCents, automaticOrders;
  final String? inputKind;
  bool get isManual => origin == 'Manuel';
  bool get isAutomatic => origin == 'Otomatik';
}

/// Single reporting truth for all platform sources in a month. A manually
/// entered Net is ALREADY net and must never be discounted again.
List<FinancePlatformFigure> financePlatformFigures(Json state, String month) {
  if (!validFinanceMonth(month)) throw const FormatException('Ay geçersiz.');
  bool included(String stamp) {
    final date = DateTime.tryParse(stamp);
    return date != null && istanbulDay(date).startsWith(month);
  }
  final auto = deliveryNetEstimates(state, included);
  return [
    for (final p in auto)
      if (p.orderCount > 0 || !manualIncomePlatforms.contains(p.source))
        FinancePlatformFigure(
          source: p.source,
          origin: p.orderCount > 0 ? 'Otomatik' : 'Yok',
          grossCents: p.grossCents,
          deductionCents: p.deductionCents,
          netCents: p.grossCents == 0 ? 0 : p.estimatedNetCents,
          unknownGrossCents:
            p.estimatedNetCents == null ? p.grossCents : 0,
          automaticOrders: p.orderCount,
          inputKind: null,
        )
      else
        (() {
          final manual = manualPlatformIncome(state, p.source, month);
          final amount = manual?['amountCents'] as int?;
          final isGross = manual?['kind'] == 'Brüt';
          final percent = deliveryDeductionPercent(state, p.source);
          final deduction = amount != null && isGross && percent != null
            ? (amount * percent / 100).round() : null;
          return FinancePlatformFigure(
            source: p.source, origin: manual == null ? 'Yok' : 'Manuel',
            grossCents: isGross ? amount : null,
            deductionCents: isGross ? deduction : null,
            netCents: amount == null ? 0 :
              (isGross ? (deduction == null ? null : amount - deduction)
                : amount),
            unknownGrossCents: amount != null && isGross &&
                deduction == null ? amount : 0,
            automaticOrders: 0,
            inputKind: manual?['kind'] as String?,
          );
        })(),
  ];
}

class FinanceMonthSummary {
  const FinanceMonthSummary({
    required this.month,
    required this.localReceiptsCents,
    required this.onlineKnownNetCents,
    required this.onlineUnpricedGrossCents,
    required this.materialsCents,
    required this.payrollCents,
    required this.fixedCents,
    required this.otherCents,
  });
  final String month;
  final int localReceiptsCents, onlineKnownNetCents,
      onlineUnpricedGrossCents, materialsCents, payrollCents,
      fixedCents, otherCents;
  int get knownIncomeCents => localReceiptsCents + onlineKnownNetCents;
  int get totalExpensesCents =>
      materialsCents + payrollCents + fixedCents + otherCents;
  bool get missingOnlineRate => onlineUnpricedGrossCents > 0;
  int? get estimateCents => missingOnlineRate ? null :
      knownIncomeCents - totalExpensesCents;
}

FinanceMonthSummary financeMonthSummary(Json state, String month) {
  if (!validFinanceMonth(month)) throw const FormatException('Ay geçersiz.');
  bool inMonth(String stamp) {
    final instant = DateTime.tryParse(stamp);
    return instant != null && istanbulDay(instant).startsWith(month);
  }
  final local = ledger(state).where((p) =>
    (p.source == 'Masa' || p.source == 'Gel-Al') &&
    inMonth(p.stamp)).fold<int>(0, (sum, p) => sum + p.amount);
  final online = financePlatformFigures(state, month);
  final knownOnline = online.fold<int>(0, (sum, p) =>
    sum + (p.netCents ?? 0));
  final unknown = online.fold<int>(0, (sum, p) =>
    sum + p.unknownGrossCents);
  final materials = financeRows(state, 'materials')
    .where((p) => p['voided'] != true &&
      (p['date'] as String? ?? '').startsWith(month))
    .fold<int>(0, (sum, p) => sum + (p['totalCents'] as int));
  // A full weekly payroll is accrued on its week's Sunday. This keeps
  // the expense from being counted in two months.
  final payroll = financeRows(state, 'weeklyPayroll')
    .where((p) => (p['weekEnd'] as String? ?? '').startsWith(month))
    .fold<int>(0, (sum, p) => sum + (p['grossCents'] as int));
  final fixed = financeRows(state, 'monthlyFixed')
    .where((p) => p['active'] == true &&
      (p['startMonth'] as String).compareTo(month) <= 0)
    .fold<int>(0, (sum, p) => sum + (p['amountCents'] as int));
  final other = financeRows(state, 'other')
    .where((p) => p['voided'] != true &&
      (p['date'] as String? ?? '').startsWith(month))
    .fold<int>(0, (sum, p) => sum + (p['amountCents'] as int));
  return FinanceMonthSummary(
    month: month, localReceiptsCents: local,
    onlineKnownNetCents: knownOnline, onlineUnpricedGrossCents: unknown,
    materialsCents: materials, payrollCents: payroll,
    fixedCents: fixed, otherCents: other,
  );
}
