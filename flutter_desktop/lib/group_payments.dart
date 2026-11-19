import 'customer_accounts.dart';
import 'operations.dart';
import 'pos_logic.dart';
import 'order_reporting.dart';

/// Records one till transaction against multiple outstanding Gel-Al orders.
/// Caller applies this to one copied state and commits in one SQLite replace.
String recordCombinedPickupPayment(
  Json state, {
  required List<int> orderIds,
  required int amountCents,
  required String method,
  int? cashCents,
  int? receivedCents,
  String? transactionId,
}) {
  if (orderIds.isEmpty || orderIds.toSet().length != orderIds.length) {
    throw const FormatException('Bir veya daha fazla farklı sipariş seçin.');
  }
  if (orderIds.length > 100) {
    throw const FormatException('Bir işlemde en fazla 100 sipariş.');
  }
  if (!['Nakit', 'Kart', 'Karışık'].contains(method)) {
    throw const FormatException('Geçersiz ödeme yöntemi.');
  }
  final orders = <Json>[];
  String? accountKey;
  var total = 0;
  for (final id in orderIds) {
    final order = mutableOrder(state, id);
    if (order == null || order['source'] != 'Gel-Al' ||
        order['closed'] == true || order['cancelled'] == true ||
        order['terminalPending'] != null) {
      throw const FormatException('Gel-Al hesaplarından biri ödeme için uygun değil.');
    }
    if (asMaps(order['guestChecks']).isNotEmpty) {
      throw const FormatException(
        'Kişilere ayrılmış siparişleri önce tek tek tahsil edin.');
    }
    final currentKey = pickupAccountKey(order, state);
    if (accountKey != null && currentKey != accountKey) {
      throw const FormatException('Farklı müşteri hesapları birleştirilemez.');
    }
    accountKey = currentKey;
    final due = orderDueCents(order);
    if (due <= 0) {
      throw const FormatException('Hesaplardan biri zaten ödenmiş.');
    }
    total += due;
    orders.add(order);
  }
  if (amountCents <= 0 || total != amountCents) {
    throw const FormatException('Toplam değişti; işlemi yeniden açın.');
  }
  if (method == 'Karışık' &&
      (cashCents == null || cashCents <= 0 || cashCents >= total)) {
    throw const FormatException('Nakit ve kart payları geçersiz.');
  }
  final requiredCash = method == 'Nakit'
      ? total : method == 'Karışık' ? cashCents! : 0;
  if (requiredCash > 0 && (receivedCents == null ||
      receivedCents < requiredCash)) {
    throw const FormatException('Alınan nakit yetersiz.');
  }
  final ref = transactionId ??
      'gel-al-' + DateTime.now().toUtc().microsecondsSinceEpoch.toString();
  if (asMaps(state['combinedPayments']).any((p) => p['id'] == ref)) {
    throw const FormatException('Toplu ödeme zaten kaydedildi.');
  }
  var cashRemaining = requiredCash;
  var changeRemaining = receivedCents == null ? 0 :
      receivedCents - requiredCash;
  // Validate on detached copies so exceptions cannot partially charge orders.
  final updated = <Json>[];
  for (final original in orders) {
    final trial = copyJson(original);
    final amount = orderDueCents(trial);
    final cash = cashRemaining < amount ? cashRemaining : amount;
    final card = amount - cash;
    final oldPaymentCount = asMaps(trial['payments']).length;
    if (cash > 0 && card > 0) {
      recordMixedPayment(
        trial, amount, cash,
        receivedCents: cash + changeRemaining,
      );
    } else if (cash > 0) {
      recordPayment(
        trial, amount, 'Nakit',
        receivedCents: cash + changeRemaining,
      );
    } else {
      recordPayment(trial, amount, 'Kart');
    }
    cashRemaining -= cash;
    if (cash > 0) changeRemaining = 0;
    final payments = trial['payments'] as List;
    for (var index = oldPaymentCount; index < payments.length; index++) {
      (payments[index] as Map)['combinedPaymentId'] = ref;
    }
    finishPickupIfSettled(trial);
    updated.add(trial);
  }
  if (cashRemaining != 0) {
    throw const FormatException('Nakit dağıtım hatası.');
  }
  for (var i = 0; i < orders.length; i++) {
    orders[i].addAll(updated[i]);
  }
  (state.putIfAbsent('combinedPayments', () => <dynamic>[]) as List).add({
    'id': ref,
    'accountKey': accountKey,
    'orderIds': orderIds,
    'amount': fromCents(total),
    'cash': fromCents(requiredCash),
    'card': fromCents(total - requiredCash),
    'received': receivedCents == null ? null : fromCents(receivedCents),
    'method': method,
    'createdAt': DateTime.now().toUtc().toIso8601String(),
  });
  final lines = <String>[
    'NOHUT FALAFEL · TOPLU HESAP ÖZETİ',
    'MALİ FİŞ DEĞİLDİR',
    istanbulStamp(DateTime.now().toUtc().toIso8601String()),
    '-------------------------------',
    for (var i = 0; i < orders.length; i++)
      '#' + displayOrderNumber(orders[i]).toString() +
      ' · ' + formatTry(orderDueCents(updated[i]) +
          orderPaidCents(updated[i]) - orderPaidCents(orders[i])) +
      ' tahsilat',
    '-------------------------------',
    'Tahsilat ' + formatTry(total),
    if (requiredCash > 0) 'Nakit ' + formatTry(requiredCash),
    if (total - requiredCash > 0)
      'Kart ' + formatTry(total - requiredCash),
    if (receivedCents != null && receivedCents > requiredCash)
      'Para üstü ' + formatTry(receivedCents - requiredCash),
    'İşlem: ' + ref,
  ];
  return lines.join('\n');
}
