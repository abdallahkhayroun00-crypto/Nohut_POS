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
  final charged = <int>[];
  for (final original in orders) {
    final trial = copyJson(original);
    final amount = orderDueCents(trial);
    charged.add(amount);
    final oldPaymentCount = asMaps(trial['payments']).length;

    // Group settlement must honor previously split/person-allocated bills.
    // Product-level partial payments also create a guest allocation, with
    // other product units unallocated. Give only that outstanding part a
    // "Kalan hesap" allocation, then settle all due guest balances.
    if (asMaps(trial['guestChecks']).isNotEmpty) {
      final remainder = [
        for (final line in checkLines(trial))
          (line.key, line.total - allocatedTo(trial, line.key)),
      ];
      if (remainder.any((part) => part.$2 < 0)) {
        throw const FormatException('Kişi payları ürün toplamını aşıyor.');
      }
      if (remainder.any((part) => part.$2 > 0)) {
        addGuest(trial, 'Kalan hesap');
        final extraGuestId = asMaps(trial['guestChecks']).last['id'] as int;
        for (final part in remainder) {
          if (part.$2 > 0) {
            allocateProduct(trial, extraGuestId, part.$1, part.$2);
          }
        }
      }
      final guestDue = asMaps(trial['guestChecks']).fold<int>(
        0, (sum, guest) =>
          sum + guestBalance(trial, guest['id'] as int));
      if (guestDue != amount) {
        throw const FormatException(
          'Geçmiş kişi ödemeleri / ayrılmamış tahsilatlar kontrol edilmeli.');
      }
    }

    final targets = asMaps(trial['guestChecks']).isEmpty
        ? <(int?, int)>[(null, amount)]
        : <(int?, int)>[
            for (final guest in asMaps(trial['guestChecks']))
              if (guestBalance(trial, guest['id'] as int) > 0)
                (guest['id'] as int, guestBalance(trial, guest['id'] as int)),
          ];
    for (final (guestId, due) in targets) {
      final cash = cashRemaining < due ? cashRemaining : due;
      final card = due - cash;
      if (cash > 0 && card > 0) {
        recordMixedPayment(trial, due, cash,
          guestId: guestId, receivedCents: cash + changeRemaining);
      } else if (cash > 0) {
        recordPayment(trial, due, 'Nakit', guestId: guestId,
          receivedCents: cash + changeRemaining);
      } else {
        recordPayment(trial, due, 'Kart', guestId: guestId);
      }
      cashRemaining -= cash;
      if (cash > 0) changeRemaining = 0;
    }
    if (orderDueCents(trial) != 0) {
      throw const FormatException('Hesabın tamamı tahsil edilemedi.');
    }
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
      ' · ' + formatTry(charged[i]) + ' tahsilat',
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
