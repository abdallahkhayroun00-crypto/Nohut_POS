import 'order_reporting.dart';
import 'pos_logic.dart';
import 'campaign_menu.dart';

String utcNow() => DateTime.now().toUtc().toIso8601String();
bool isPlatform(Json o) => ['Yemeksepeti', 'Trendyol Go'].contains(o['source']);
void requireLocal(Json o) {
  if (isPlatform(o)) {
    throw const FormatException('Platform tahsilatı kasaya alınmaz');
  }
}

void requireOpen(Json o) {
  if (o['terminalPending'] != null)
    throw const FormatException(
      'Terminal sonucu bekleniyor; önce işlemi sorgulayın',
    );
  if (o['closed'] == true || o['cancelled'] == true) {
    throw const FormatException('Hesap kapalı');
  }
}

/// Stable batch:index keys match the phone split-check protocol.
class CheckLine {
  const CheckLine(this.key, this.line);
  final String key;
  final Json line;
  int get total => cents(line['price']) * (line['qty'] as int);
}

List<CheckLine> checkLines(Json o) => [
  for (final b in asMaps(o['batches']))
    for (var i = 0; i < (b['lines'] as List).length; i++)
      if (b['lines'][i]['voided'] != true &&
          b['lines'][i]['correction'] != true)
        CheckLine(
          '${b['id']}:$i',
          Map<String, dynamic>.from(b['lines'][i] as Map),
        ),
];
int allocatedTo(Json o, String key) => asMaps(o['guestChecks']).fold(
  0,
  (sum, g) =>
      sum +
      asMaps(g['allocations'])
          .where((a) => a['key'] == key)
          .fold<int>(0, (n, a) => n + (a['cents'] as int)),
);
int guestBalance(Json o, int id) {
  final g = asMaps(o['guestChecks']).firstWhere(
    (g) => g['id'] == id,
    orElse: () => throw const FormatException('Kişi bulunamadı'),
  );
  final allocated = asMaps(
    g['allocations'],
  ).fold<int>(0, (n, a) => n + (a['cents'] as int));
  final paid = asMaps(
    o['payments'],
  ).fold<int>(0, (n, p) => n + paymentGuestCents(p, id));
  return allocated - paid;
}

int paymentNetCents(Json p) => p['reversed'] == true
    ? 0
    : cents(p['amount']) -
          asMaps(p['refunds']).fold<int>(0, (n, r) => n + cents(r['amount']));

void addGuest(Json o, String name) {
  requireLocal(o);
  requireOpen(o);
  if (name.trim().isEmpty) throw const FormatException('Kişi adı gerekli');
  final guests = o.putIfAbsent('guestChecks', () => <dynamic>[]) as List;
  final id =
      asMaps(
        guests,
      ).fold<int>(0, (n, g) => (g['id'] as int) > n ? g['id'] as int : n) +
      1;
  guests.add({'id': id, 'name': name.trim(), 'allocations': <dynamic>[]});
}

void allocateProduct(Json o, int guestId, String key, int amount) {
  requireLocal(o);
  requireOpen(o);
  final line = checkLines(o).firstWhere(
    (l) => l.key == key,
    orElse: () => throw const FormatException('Ürün bulunamadı'),
  );
  final g = (o['guestChecks'] as List).cast<Map>().firstWhere(
    (g) => g['id'] == guestId,
  );
  final allocations = g['allocations'] as List;
  final previous = asMaps(allocations)
      .where((a) => a['key'] == key)
      .fold<int>(0, (n, a) => n + (a['cents'] as int));
  if (amount < 0 ||
      allocatedTo(o, key) - previous + amount > line.total ||
      guestBalance(o, guestId) - previous + amount < 0) {
    throw const FormatException('Ürün payı veya ödenen kişi bakiyesi aşıldı');
  }
  allocations.removeWhere((a) => a['key'] == key);
  if (amount > 0) allocations.add({'key': key, 'cents': amount});
}

void resetGuests(Json o) {
  requireOpen(o);
  if (orderPaidCents(o) > 0) {
    throw const FormatException('Önce ödemeleri iade edin');
  }
  o['guestChecks'] = <dynamic>[];
}

void splitEqually(Json o, int count) {
  requireLocal(o);
  requireOpen(o);
  if (count < 2 ||
      count > 10 ||
      orderPaidCents(o) != 0 ||
      asMaps(o['guestChecks']).isNotEmpty) {
    throw const FormatException(
      '2–10 kişi; önce mevcut ödemeleri / payları kontrol edin',
    );
  }
  for (var i = 0; i < count; i++) {
    addGuest(o, 'Kişi ${i + 1}');
  }
  final total = orderTotalCents(o), lines = checkLines(o);
  var lineIndex = 0, used = 0;
  for (var i = 0; i < count; i++) {
    var need = total ~/ count + (i < total % count ? 1 : 0);
    while (need > 0 && lineIndex < lines.length) {
      final l = lines[lineIndex],
          left = l.total - used,
          portion = left < need ? left : need;
      allocateProduct(o, i + 1, l.key, portion);
      need -= portion;
      used += portion;
      if (used == l.total) {
        lineIndex++;
        used = 0;
      }
    }
  }
}

void changeGuest(Json o, int id, String name, {bool remove = false}) {
  requireLocal(o);
  requireOpen(o);
  final guests = o['guestChecks'] as List;
  final guest = guests.cast<Map>().firstWhere((g) => g['id'] == id);
  if (remove) {
    if (asMaps(guest['allocations']).isNotEmpty ||
        asMaps(o['payments']).any(
          (p) =>
              p['guestCheckId'] == id ||
              asMaps(p['guestAllocations']).any((a) => a['guestCheckId'] == id),
        )) {
      throw const FormatException(
        'Önce kişi paylarını / ödemeleri kontrol edin',
      );
    }
    guests.remove(guest);
  } else {
    if (name.trim().isEmpty) throw const FormatException('Ad gerekli');
    guest['name'] = name.trim();
  }
}

String billText(Json o) {
  final total = orderTotalCents(o),
      paid = orderPaidCents(o),
      due = orderDueCents(o);
  final customer = receiptCustomer(o);
  final payments = [
    for (final p in asMaps(o['payments']))
      if (paymentNetCents(p) > 0) p,
  ];
  return [
    'NOHUT FALAFEL · HESAP ÖZETİ',
    'MALİ FİŞ DEĞİLDİR',
    '#${displayOrderNumber(o)} · ${receiptService(o)}',
    ?customer,
    receiptStamp(o['createdAt']),
    for (final l in checkLines(o)) ...[
      '${l.line['qty']} × ${l.line['name']} · ${formatTry(l.total)}',
      if ((l.line['qty'] as int? ?? 1) > 1)
        '  ${l.line['qty']} × ${formatTry(cents(l.line['price']))}',
      ...receiptLineDetails(l.line),
    ],
    'Toplam ${formatTry(total)}',
    if (paid > 0) 'Ödenen ${formatTry(paid)}',
    if (due > 0) 'Kalan ${formatTry(due)}',
    if (due <= 0 && paid > 0 && o['cancelled'] != true) '!! ÖDENDİ',
    if (payments.isNotEmpty) '---',
    for (final p in payments) ...[
      '${p['method']}${'${p['guestName'] ?? ''}'.trim().isEmpty ? '' : ' · ${p['guestName']}'} '
          '${formatTry(paymentNetCents(p))}',
      if (p['method'] == 'Nakit' &&
          p['received'] != null &&
          cents(p['received']) > cents(p['amount']))
        '  Alınan ${formatTry(cents(p['received']))} · '
            'Para üstü ${formatTry(cents(p['received']) - cents(p['amount']))}',
    ],
  ].join('\n');
}

void assignExistingPayment(Json o, int index, int guestId, int amount) {
  requireLocal(o);
  final p = ((o['payments'] as List)[index] as Map).cast<String, dynamic>();
  if (p['guestCheckId'] != null || p['reversed'] == true) {
    throw const FormatException(
      'Bu ödeme doğrudan bir kişiye ait / iade edilmiş',
    );
  }
  final mappings = p.putIfAbsent('guestAllocations', () => <dynamic>[]) as List;
  final previous = asMaps(mappings)
      .where((a) => a['guestCheckId'] == guestId)
      .fold<int>(0, (n, a) => n + cents(a['amount']));
  final total = asMaps(mappings).fold<int>(0, (n, a) => n + cents(a['amount']));
  if ((o['closed'] == true || o['cancelled'] == true) && amount > previous) {
    throw const FormatException(
      'Kapalı hesapta yalnız eşlemeyi azaltabilirsiniz',
    );
  }
  if (amount < 0 ||
      total - previous + amount > paymentNetCents(p) ||
      guestBalance(o, guestId) + previous < amount) {
    throw const FormatException('Tahsilat veya kişi payı aşıldı');
  }
  mappings.removeWhere((a) => a['guestCheckId'] == guestId);
  if (amount > 0) {
    mappings.add({'guestCheckId': guestId, 'amount': fromCents(amount)});
  }
}

void refundPayment(Json o, int index, int amount, String reason) {
  requireLocal(o);
  final payments = o['payments'] as List;
  if (index < 0 ||
      index >= payments.length ||
      reason.trim().isEmpty ||
      amount <= 0) {
    throw const FormatException('İade tutarı / nedeni gerekli');
  }
  final p = (payments[index] as Map).cast<String, dynamic>();
  if (amount > paymentNetCents(p)) {
    throw const FormatException('Tahsilattan fazla iade edilemez');
  }
  if (asMaps(
        p['guestAllocations'],
      ).fold<int>(0, (n, a) => n + cents(a['amount'])) >
      paymentNetCents(p) - amount) {
    throw const FormatException('Önce geçmiş ödeme kişi eşlemesini azaltın');
  }
  (p.putIfAbsent('refunds', () => <dynamic>[]) as List).add({
    'amount': fromCents(amount),
    'createdAt': utcNow(),
    'reason': reason.trim(),
    'by': 'Kasa (PC)',
  });
  // Refunds and service/table release are independent. A closed historical check
  // is not reopened over a new occupant of the same physical table.
  (o['events'] as List).add(
    '${utcNow()} · İade ${formatTry(amount)} · $reason',
  );
}

void cancelProduct(
  Json state,
  int orderId,
  String key,
  int qty,
  String reason,
) {
  final o =
      mutableOrder(state, orderId) ??
      (throw const FormatException('Sipariş yok'));
  requireLocal(o);
  requireOpen(o);
  final parts = key.split(':');
  final b = (o['batches'] as List).cast<Map>().firstWhere(
    (b) => '${b['id']}' == parts[0],
  );
  final l = (b['lines'][int.parse(parts[1])] as Map).cast<String, dynamic>();
  final before = l['qty'] as int;
  if (reason.trim().isEmpty ||
      qty < 1 ||
      qty > before ||
      l['voided'] == true ||
      l['correction'] == true) {
    throw const FormatException('İptal adedi / nedeni geçersiz');
  }
  final remaining = cents(l['price']) * (before - qty);
  if (allocatedTo(o, key) > remaining ||
      orderTotalCents(o) - cents(l['price']) * qty < orderPaidCents(o)) {
    throw const FormatException(
      'Önce kişi payını azaltın ve fazla tahsilatı iade edin',
    );
  }
  l['originalQty'] ??= before;
  l['qty'] = before - qty;
  l['voided'] = l['qty'] == 0;
  final batches = o['batches'] as List;
  final id =
      asMaps(
        batches,
      ).fold<int>(0, (n, b) => (b['id'] as int) > n ? b['id'] as int : n) +
      1;
  batches.add({
    'id': id,
    'staff': 'Kasa (PC)',
    'time': nowTime(),
    'createdAt': utcNow(),
    'lines': [
      {
        'name': 'İPTAL: ${l['name']}',
        'qty': qty,
        'price': 0,
        'correction': true,
        'removed': [],
        'note': reason.trim(),
      },
    ],
  });
  queueLocalKitchen(state, o, batches.last as Map);
  (o.putIfAbsent('voids', () => <dynamic>[]) as List).add({
    'name': l['name'],
    'qty': qty,
    'price': l['price'],
    'reason': reason,
    'createdAt': utcNow(),
  });
  (o['events'] as List).add(
    '${utcNow()} · $qty × ${l['name']} iptal · $reason',
  );
}

void cancelLocalOrder(Json state, int id, String reason) {
  final o = mutableOrder(state, id)!;
  requireLocal(o);
  requireOpen(o);
  if (orderPaidCents(o) > 0) {
    throw const FormatException('Önce tüm ödemeleri iade edin');
  }
  if (reason.trim().isEmpty) {
    throw const FormatException('İptal nedeni gerekli');
  }
  resetGuests(o);
  final batchesBefore = (o['batches'] as List).length,
      jobsBefore = (state['printJobs'] as List).length;
  for (final l in checkLines(o)) {
    cancelProduct(state, id, l.key, l.line['qty'] as int, reason);
  }
  // One İPTAL slip for the whole order instead of one slip per product.
  final batches = o['batches'] as List;
  if (batches.length - batchesBefore > 1) {
    final added = batches.sublist(batchesBefore).cast<Map>();
    final merged = added.first;
    merged['lines'] = [for (final b in added) ...(b['lines'] as List)];
    batches.removeRange(batchesBefore + 1, batches.length);
    final jobs = state['printJobs'] as List;
    if (jobs.length > jobsBefore) {
      jobs.removeRange(jobsBefore, jobs.length);
      queueLocalKitchen(state, o, merged);
    }
  }
  o['closed'] = true;
  o['cancelled'] = true;
  o['cancelledAt'] = utcNow();
  o['cancelReason'] = reason.trim();
  o['tableReleased'] = true;
  for (final job in (state['printJobs'] as List).whereType<Map>()) {
    if (job['orderId'] == id &&
        job['state'] == 'Bekliyor' &&
        !correctionKitchenJob(state, job)) {
      job['state'] = 'İptal';
    }
  }
}

void setLocalService(Json o, String status) {
  requireLocal(o);
  requireOpen(o);
  const sequence = ['Hazırlanıyor', 'Hazır', 'Teslim Edildi'];
  final old = sequence.indexOf('${o['serviceStatus']}');
  if (sequence.indexOf(status) != old + 1) {
    throw const FormatException('Geçersiz hizmet geçişi');
  }
  o['serviceStatus'] = status;
  o[status == 'Hazır' ? 'readyAt' : 'deliveredAt'] = utcNow();
  (o['events'] as List).add('${utcNow()} · Hizmet: $status');
}

void markPickupDelivered(Json order) {
  requireOpen(order);
  if (order['source'] != 'Gel-Al' || order['deliveredAt'] != null) {
    throw const FormatException('Teslim işlemi geçersiz');
  }
  order['serviceStatus'] = 'Teslim Edildi';
  order['deliveredAt'] = utcNow();
  (order['events'] as List).add('${utcNow()} · Teslim Edildi');
  finishPickupIfSettled(order);
}

void finishPickupIfSettled(Json order) {
  if (order['source'] == 'Gel-Al' &&
      order['closed'] != true &&
      order['cancelled'] != true &&
      order['terminalPending'] == null &&
      (order['deliveredAt'] != null ||
          order['serviceStatus'] == 'Teslim Edildi') &&
      orderDueCents(order) == 0) {
    order['closed'] = true;
    order['closedAt'] = utcNow();
  }
}

void closePickup(Json o) {
  requireLocal(o);
  requireOpen(o);
  if (o['source'] != 'Gel-Al' ||
      orderDueCents(o) != 0 ||
      o['serviceStatus'] != 'Teslim Edildi') {
    throw const FormatException('Önce ödeme ve teslim tamamlanmalı');
  }
  o['closed'] = true;
}

Json cashBook(Json s) =>
    (s.putIfAbsent(
              'cashBook',
              () => {
                'sessions': <dynamic>[],
                'movements': <dynamic>[],
                'next': 1,
              },
            )
            as Map)
        .cast<String, dynamic>();
Json? activeCash(Json s) => asMaps(
  cashBook(s)['sessions'],
).where((c) => c['closedAt'] == null).firstOrNull;
void openCash(Json s, int opening) {
  if (opening < 0 || activeCash(s) != null) {
    throw const FormatException('Açık kasa var veya tutar geçersiz');
  }
  final book = cashBook(s), id = cashBook(s)['next'] as int;
  book['next'] = id + 1;
  (book['sessions'] as List).add({
    'id': id,
    'openedAt': utcNow(),
    'openingCents': opening,
    'openedBy': 'Kasa (PC)',
    'closedAt': null,
  });
}

class LedgerEntry {
  const LedgerEntry(
    this.orderId,
    this.source,
    this.method,
    this.kind,
    this.amount,
    this.stamp,
    this.staff,
  );
  final int orderId, amount;
  final String source, method, kind, stamp, staff;
}

List<LedgerEntry> ledger(Json state) => [
  for (final o in asMaps(state['orders'])) ...[
    for (final p in asMaps(o['payments'])) ...[
      LedgerEntry(
        o['id'] as int,
        '${o['source']}',
        '${p['method']}',
        'Tahsilat',
        cents(p['amount']),
        '${p['createdAt'] ?? ''}',
        '${p['by'] ?? ''}',
      ),
      if (p['reversed'] == true)
        LedgerEntry(
          o['id'] as int,
          '${o['source']}',
          '${p['method']}',
          'İade',
          -cents(p['amount']),
          '${p['reversedAt'] ?? ''}',
          '${p['by'] ?? ''}',
        ),
      for (final r in asMaps(p['refunds']))
        LedgerEntry(
          o['id'] as int,
          '${o['source']}',
          '${p['method']}',
          'İade',
          -cents(r['amount']),
          '${r['createdAt']}',
          '${r['by'] ?? 'Kasa (PC)'}',
        ),
    ],
    if (isPlatform(o))
      for (final a in asMaps(o['platformAdjustments']))
        LedgerEntry(
          o['id'] as int,
          '${o['source']}',
          'Platform',
          'Platform düzeltmesi',
          cents(a['amount']),
          '${a['stamp']}',
          '${o['source']}',
        ),
  ],
];

class SaleEntry {
  const SaleEntry(
    this.orderId,
    this.source,
    this.staff,
    this.product,
    this.quantity,
    this.amount,
    this.stamp,
  );
  final int orderId, quantity, amount;
  final String source, staff, product, stamp;
}

List<SaleEntry> sales(Json state) => [
  for (final o in asMaps(state['orders']))
    if (o['cancelled'] != true)
      for (final b in asMaps(o['batches']))
        for (final l in asMaps(b['lines']))
          if (l['voided'] != true && l['correction'] != true)
            SaleEntry(
              o['id'] as int,
              '${o['source']}',
              orderOwnerName(o),
              '${l['name'] ?? l['productKey']}',
              l['qty'] as int,
              cents(l['price']) * (l['qty'] as int),
              '${b['createdAt'] ?? o['createdAt'] ?? ''}',
            ),
];
String salesCsv(Iterable<SaleEntry> rows) =>
    '\uFEFF${[
      ['Sipariş', 'Kaynak', 'Personel', 'Ürün', 'Adet', 'Ürün toplamı kuruş', 'Tarih UTC'],
      ...rows.map((r) => [r.orderId, r.source, r.staff, r.product, r.quantity, r.amount, r.stamp]),
    ].map((r) => r.map(csvCell).join(',')).join('\r\n')}\r\n';

int expectedCash(Json s, Json c, {String? end}) {
  final stop = end ?? c['closedAt'] as String? ?? utcNow();
  final start = c['openedAt'] as String;
  final receipts = ledger(s)
      .where(
        (e) =>
            e.method == 'Nakit' &&
            !['Yemeksepeti', 'Trendyol Go'].contains(e.source) &&
            DateTime.tryParse(e.stamp) != null &&
            !DateTime.parse(e.stamp).isBefore(DateTime.parse(start)) &&
            !DateTime.parse(e.stamp).isAfter(DateTime.parse(stop)),
      )
      .fold<int>(0, (n, e) => n + e.amount);
  return (c['openingCents'] as int) +
      receipts +
      asMaps(cashBook(s)['movements'])
          .where((m) => m['sessionId'] == c['id'])
          .fold<int>(0, (n, m) => n + (m['cents'] as int));
}

void moveCash(Json s, int signed, String reason) {
  final c = activeCash(s);
  if (c == null || signed == 0 || reason.trim().isEmpty) {
    throw const FormatException('Açık kasa, tutar ve açıklama gerekli');
  }
  if (expectedCash(s, c) + signed < 0) {
    throw const FormatException('Kasada yeterli nakit yok');
  }
  (cashBook(s)['movements'] as List).add({
    'sessionId': c['id'],
    'cents': signed,
    'note': reason.trim(),
    'at': utcNow(),
    'by': 'Kasa (PC)',
  });
}

void closeCash(Json s, int counted) {
  if (counted < 0) throw const FormatException('Sayım geçersiz');
  final active = activeCash(s);
  if (active == null) throw const FormatException('Açık kasa yok');
  final c = (cashBook(s)['sessions'] as List).cast<Map>().firstWhere(
    (c) => c['id'] == active['id'],
  );
  final end = utcNow();
  final expected = expectedCash(s, active, end: end);
  c.addAll(<String, dynamic>{
    'closedAt': end,
    'countedCents': counted,
    'expectedCents': expected,
    'differenceCents': counted - expected,
    'closedBy': 'Kasa (PC)',
  });
}

String csvCell(Object? value) {
  var text = '${value ?? ''}';
  // Prevent spreadsheet formula execution in names/notes received over LAN.
  if (RegExp(r'^\s*[=+@-]').hasMatch(text)) text = "'$text";
  return '"${text.replaceAll('"', '""')}"';
}

String ledgerCsv(Iterable<LedgerEntry> rows) =>
    '\uFEFF${[
      ['Sipariş', 'Kaynak', 'Yöntem', 'Tür', 'Tutar (kuruş)', 'Tarih UTC', 'Personel'],
      ...rows.map((r) => [r.orderId, r.source, r.method, r.kind, r.amount, r.stamp, r.staff]),
    ].map((row) => row.map(csvCell).join(',')).join('\r\n')}\r\n';

void saveEmployee(Json state, int? id, String name, String role, bool active) {
  if (name.trim().isEmpty || !['Personel', 'Yönetici'].contains(role)) {
    throw const FormatException('Ad / görev geçersiz');
  }
  final employees = state['employees'] as List;
  if (asMaps(employees).any(
    (e) =>
        e['id'] != id &&
        '${e['name']}'.toLowerCase() == name.trim().toLowerCase(),
  )) {
    throw const FormatException('Bu ad zaten var');
  }
  if (id == null) {
    id =
        asMaps(
          employees,
        ).fold<int>(0, (n, e) => (e['id'] as int) > n ? e['id'] as int : n) +
        1;
    employees.add({
      'id': id,
      'name': name.trim(),
      'role': role,
      'active': active,
    });
  } else {
    final person = employees.cast<Map>().firstWhere((e) => e['id'] == id);
    person['name'] = name.trim();
    person['role'] = role;
    person['active'] = active;
  }
}

/// "Masa 3", "Gel-Al · Telefon" or the platform name, for both slips.
String receiptService(Map o) {
  if (o['source'] == 'Masa') return 'Masa ${o['table'] ?? '?'}';
  if (o['source'] == 'Gel-Al') {
    final channel = '${o['pickupChannel'] ?? ''}';
    return channel.isEmpty ? 'Gel-Al' : 'Gel-Al · $channel';
  }
  return '${o['source'] ?? 'Sipariş'}';
}

/// Pickup customer name / promised time, when the cashier entered them.
String? receiptCustomer(Map o) {
  final customer = o['customer'];
  if (o['source'] != 'Gel-Al' || customer is! Map) return null;
  final name = '${customer['name'] ?? ''}'.trim(),
      time = '${customer['time'] ?? ''}'.trim();
  if (name.isEmpty && time.isEmpty) return null;
  return [
    if (name.isNotEmpty) 'Müşteri: $name',
    if (time.isNotEmpty) 'Saat $time',
  ].join(' · ');
}

/// Detail rows printed under an item, indented so a menu component is never
/// read as a separate product.
List<String> receiptLineDetails(Map l) {
  final removed = [
    for (final r in (l['removed'] as List? ?? [])) '$r'.trim(),
  ].where((r) => r.isNotEmpty).toList();
  final note = '${l['note'] ?? ''}'.trim();
  return [
    for (final c in asMaps(l['components']))
      '  › ${[
        '${c['name']}',
        if (campaignComponentDetails(c).isNotEmpty)
          campaignComponentDetails(c),
      ].join(' · ')}',
    if (removed.isNotEmpty) '  Çıkar: ${removed.join(', ')}',
    if (note.isNotEmpty)
      l['correction'] == true
          ? '  Neden: ${note.replaceFirst(RegExp(r'^Neden:?\s*'), '')}'
          : '  Not: $note',
    if ((l['adjustmentCents'] as int? ?? 0) != 0)
      '  Adet farkı: ${formatTry(l['adjustmentCents'] as int)}',
  ];
}

String receiptText(Json state, Json job) {
  final snapshot = job['snapshot'];
  final o = snapshot is Map && snapshot['order'] is Map
      ? Map<String, dynamic>.from(snapshot['order'] as Map)
      : mutableOrder(state, job['orderId'] as int);
  if (o == null) throw const FormatException('Sipariş bulunamadı');
  final batch = snapshot is Map && snapshot['batch'] is Map
      ? Map<String, dynamic>.from(snapshot['batch'] as Map)
      : asMaps(
          o['batches'],
        ).where((b) => b['id'] == job['batchId']).firstOrNull;
  if (batch == null) throw const FormatException('Sipariş partisi bulunamadı');
  final lines = [
    for (final l in asMaps(batch['lines']))
      if (l['voided'] != true || l['correction'] == true) l,
  ];
  final correction =
      lines.isNotEmpty && lines.every((l) => l['correction'] == true);
  int lineTotal(Map l) => cents(l['price']) * (l['qty'] as int? ?? 0);
  final total = lines
      .where((l) => l['correction'] != true)
      .fold<int>(0, (n, l) => n + lineTotal(l));
  final customer = receiptCustomer(o);
  return [
    'NOHUT FALAFEL · SİPARİŞ FİŞİ',
    'MALİ FİŞ DEĞİLDİR',
    '#${displayOrderNumber(o)} · ${receiptService(o)}',
    ?customer,
    '${batch['staff']} · ${receiptStamp(batch['createdAt'] ?? o['createdAt'])}',
    if (correction)
      '!! İPTAL'
    else if ((batch['id'] as int? ?? 1) > 1)
      '!! EK SİPARİŞ',
    for (final l in lines) ...[
      l['correction'] == true
          ? '${l['qty']} × ${l['name'] ?? l['productKey']}'
          : '${l['qty']} × ${l['name'] ?? l['productKey']} · '
                '${formatTry(lineTotal(l))}',
      if (l['correction'] != true && (l['qty'] as int? ?? 1) > 1)
        '  ${l['qty']} × ${formatTry(cents(l['price']))}',
      ...receiptLineDetails(l),
    ],
    if (!correction) 'Toplam ${formatTry(total)}',
  ].join('\n');
}

void recordMixedPayment(
  Json o,
  int total,
  int cash, {
  int? guestId,
  int? receivedCents,
}) {
  requireLocal(o);
  requireOpen(o);
  if (cash <= 0 || cash >= total)
    throw const FormatException('Nakit ve Kart kısmı sıfırdan büyük olmalı');
  final trial = copyJson(o);
  recordPayment(
    trial,
    cash,
    'Nakit',
    receivedCents: receivedCents ?? cash,
    guestId: guestId,
  );
  recordPayment(trial, total - cash, 'Kart', guestId: guestId);
  o.addAll(trial);
}

/// The phone and cashier use the same rules, and only commit after payment.
String recordProductPayment(
  Json order,
  Map<String, int> shares,
  int amount,
  String method, {
  int? receivedCents,
  int? cashCents,
}) {
  requireLocal(order);
  requireOpen(order);
  if (shares.isEmpty ||
      shares.values.any((value) => value <= 0) ||
      shares.values.fold<int>(0, (sum, value) => sum + value) != amount) {
    throw const FormatException('Seçilen ürünlerin toplamı değişti.');
  }
  final trial = copyJson(order);
  addGuest(trial, 'Ürün ödemesi');
  final guestId = asMaps(trial['guestChecks']).last['id'] as int;
  for (final entry in shares.entries) {
    allocateProduct(trial, guestId, entry.key, entry.value);
  }
  if (method == 'Karışık') {
    recordMixedPayment(
      trial,
      amount,
      cashCents ?? 0,
      guestId: guestId,
      receivedCents: receivedCents,
    );
  } else {
    recordPayment(
      trial,
      amount,
      method,
      guestId: guestId,
      receivedCents: receivedCents,
    );
  }
  final receipt = [
    'NOHUT FALAFEL · HESAP ÖZETİ',
    'MALI FIS DEGILDIR',
    '#${displayOrderNumber(trial)} · ${trial['source']} · ${trial['table'] ?? ''}',
    istanbulStamp(utcNow()),
    for (final item in checkLines(trial))
      if (shares[item.key] case final int share) ...[
        '${_quantityLabel(item, share)} × ${item.line['name']} · ${formatTry(share)}',
        for (final component in asMaps(item.line['components']))
          '${component['name']} · ${campaignComponentDetails(component)}',
      ],
    'Toplam ${formatTry(amount)}',
    if (method == 'Karışık') ...[
      'Nakit · ${formatTry(cashCents!)}',
      'Kart · ${formatTry(amount - cashCents)}',
    ] else
      '$method · ${formatTry(amount)}',
  ].join('\n');
  order.addAll(trial);
  return receipt;
}

String _quantityLabel(CheckLine item, int share) {
  final unit = cents(item.line['price']);
  return share % unit == 0
      ? '${share ~/ unit}'
      : (share / unit)
            .toStringAsFixed(3)
            .replaceFirst(RegExp(r'0+$'), '')
            .replaceAll('.', ',');
}
