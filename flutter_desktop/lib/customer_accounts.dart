import 'pos_logic.dart';

/// Private contacts are persisted in the laptop's local SQLite snapshot.
String customerPhoneKey(String value) =>
    value.replaceAll(RegExp(r'[^0-9]'), '');

String customerNameKey(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

List<Json> savedCustomers(Json state) => asMaps(state['customers']);

/// Returns the stable customer ID. Different nonempty phone numbers never
/// merge merely because two customers share a name.
int savePickupCustomer(
  Json state, {
  required String name,
  required String phone,
  int? existingId,
}) {
  final cleanName = name.trim();
  final cleanPhone = phone.trim();
  if (cleanName.isEmpty || cleanName.length > 120 || cleanPhone.length > 40) {
    throw const FormatException('Geçerli müşteri adı gerekli.');
  }
  final phoneKey = customerPhoneKey(cleanPhone);
  final customers = state.putIfAbsent('customers', () => <dynamic>[]) as List;
  Map? match;
  for (final item in customers) {
    if (item is! Map) continue;
    final previousPhone = customerPhoneKey((item['phone'] ?? '').toString());
    if (existingId != null && item['id'] == existingId) {
      match = item;
      break;
    }
    if (phoneKey.isNotEmpty && phoneKey == previousPhone) {
      match = item;
      break;
    }
    if (phoneKey.isEmpty && previousPhone.isEmpty &&
        customerNameKey((item['name'] ?? '').toString()) == customerNameKey(cleanName)) {
      match = item;
      break;
    }
  }
  if (match != null) {
    match['name'] = cleanName;
    if (cleanPhone.isNotEmpty) match['phone'] = cleanPhone;
    match['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    return match['id'] as int;
  }
  final nextId = asMaps(customers).fold<int>(
        0, (maxId, item) => item['id'] is int && (item['id'] as int) > maxId
            ? item['id'] as int : maxId,
      ) + 1;
  customers.add({
    'id': nextId,
    'name': cleanName,
    'phone': cleanPhone,
    'createdAt': DateTime.now().toUtc().toIso8601String(),
  });
  return nextId;
}

/// The order keeps a snapshot of contact information and a verified customer ID.
Json linkedPickupCustomer(Json state, Json draft) {
  final result = <String, dynamic>{
    'name': (draft['name'] ?? '').toString().trim(),
    'phone': (draft['phone'] ?? '').toString().trim(),
    'time': (draft['time'] ?? '').toString().trim(),
  };
  if (draft['id'] is int && savedCustomers(state).any(
      (customer) => customer['id'] == draft['id'])) {
    result['id'] = draft['id'];
  }
  if (draft['saveCustomer'] == true) {
    result['id'] = savePickupCustomer(
      state,
      name: result['name'] as String,
      phone: result['phone'] as String,
      existingId: result['id'] as int?,
    );
  }
  return result;
}

/// ID first, then phone for legacy orders. Anonymous name-only accounts
/// are never silently merged; two different customers can share a name.
String pickupAccountKey(Json order, Json state) {
  final person = order['customer'];
  if (person is! Map) return 'order:' + order['id'].toString();
  final id = person['id'];
  if (id is int) return 'id:' + id.toString();
  final phone = customerPhoneKey((person['phone'] ?? '').toString());
  if (phone.isNotEmpty) {
    for (final saved in savedCustomers(state)) {
      if (customerPhoneKey((saved['phone'] ?? '').toString()) == phone) {
        return 'id:' + saved['id'].toString();
      }
    }
    return 'phone:' + phone;
  }
  return 'order:' + order['id'].toString();
}

class PickupAccount {
  const PickupAccount({
    required this.key,
    required this.name,
    required this.phone,
    required this.orders,
    required this.dueCents,
  });
  final String key, name, phone;
  final List<Json> orders;
  final int dueCents;
}

/// Balances derive from authoritative order payments; no duplicate debt ledger.
List<PickupAccount> pickupOpenAccounts(Json state) {
  final grouped = <String, List<Json>>{};
  for (final order in asMaps(state['orders'])) {
    if (order['source'] != 'Gel-Al' || order['cancelled'] == true ||
        orderDueCents(order) <= 0) continue;
    grouped.putIfAbsent(pickupAccountKey(order, state), () => <Json>[])
        .add(order);
  }
  final accounts = <PickupAccount>[];
  for (final entry in grouped.entries) {
    final orders = entry.value
      ..sort((a, b) => (b['createdAt'] ?? '').toString()
          .compareTo((a['createdAt'] ?? '').toString()));
    final first = orders.first['customer'] is Map
        ? orders.first['customer'] as Map : <String, dynamic>{};
    final customer = entry.key.startsWith('id:')
        ? savedCustomers(state).where((c) =>
            'id:' + c['id'].toString() == entry.key).firstOrNull
        : null;
    final name = (customer?['name'] ?? first['name'] ?? '').toString().trim();
    accounts.add(PickupAccount(
      key: entry.key,
      name: name.isEmpty ? 'İsimsiz Gel-Al' : name,
      phone: (customer?['phone'] ?? first['phone'] ?? '').toString(),
      orders: orders,
      dueCents: orders.fold<int>(0, (sum, order) =>
          sum + orderDueCents(order)),
    ));
  }
  accounts.sort((a, b) => (b.orders.first['createdAt'] ?? '').toString()
      .compareTo((a.orders.first['createdAt'] ?? '').toString()));
  return accounts;
}
