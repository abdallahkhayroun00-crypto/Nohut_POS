import 'package:flutter/material.dart';

import 'customer_accounts.dart';
import 'pos_logic.dart';
import 'order_reporting.dart';

class OpenAccountsPanel extends StatefulWidget {
  const OpenAccountsPanel({
    super.key,
    required this.state,
    required this.onOpenOrder,
    required this.onPayOrder,
    required this.onPayAccount,
    required this.onLinkCustomer,
  });
  final Json state;
  final ValueChanged<Json> onOpenOrder;
  final ValueChanged<Json> onPayOrder;
  final ValueChanged<List<Json>> onPayAccount;
  final void Function(int orderId, int? customerId, String? newName, String phone)
      onLinkCustomer;

  @override
  State<OpenAccountsPanel> createState() => _OpenAccountsPanelState();
}

class _OpenAccountsPanelState extends State<OpenAccountsPanel> {
  String query = '';

  List<PickupAccount> get accounts {
    final customers = pickupOpenAccounts(widget.state);
    final q = query.trim().toLowerCase();
    return customers.where((account) => q.isEmpty ||
        account.name.toLowerCase().contains(q) ||
        account.phone.contains(q) ||
        account.orders.any((o) =>
            displayOrderNumber(o).toString().contains(q))).toList();
  }

  Future<void> _linkLegacyOrder(Json order) async {
    final directory = savedCustomers(widget.state);
    final name = TextEditingController(
      text: (order['customer'] is Map
          ? (order['customer'] as Map)['name'] : '').toString(),
    );
    final phone = TextEditingController(
      text: (order['customer'] is Map
          ? (order['customer'] as Map)['phone'] : '').toString(),
    );
    final search = TextEditingController();
    bool createNew = directory.isEmpty;
    int? chosenId;
    final result = await showDialog<(int?, String?, String)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) {
          final needle = search.text.trim().toLowerCase();
          final matching = directory.where((c) => needle.isEmpty ||
            (c['name'] ?? '').toString().toLowerCase().contains(needle) ||
            customerPhoneKey((c['phone'] ?? '').toString())
              .contains(customerPhoneKey(needle)) &&
            customerPhoneKey(needle).isNotEmpty,
          ).take(8).toList();
          return AlertDialog(
            title: const Text('Eski Gel-Al Siparişini Müşteriye Bağla'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Sipariş #' + displayOrderNumber(order).toString() +
                      ' · Kalan ' + formatTry(orderDueCents(order))),
                    const SizedBox(height: 7),
                    const Text('Ürünler ve önceki ödemeler değişmez. '
                      'Yalnızca müşteri bağlantısı eklenir.'),
                    const SizedBox(height: 12),
                    Wrap(spacing: 8, children: [
                      ChoiceChip(
                        label: const Text('Kayıtlı Müşteri'),
                        selected: !createNew,
                        onSelected: directory.isEmpty ? null
                          : (_) => update(() => createNew = false),
                      ),
                      ChoiceChip(
                        label: const Text('Yeni Müşteri'),
                        selected: createNew,
                        onSelected: (_) => update(() => createNew = true),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    if (createNew) ...[
                      TextField(
                        controller: name,
                        maxLength: 120,
                        onChanged: (_) => update(() {}),
                        decoration: const InputDecoration(labelText: 'Müşteri Adı *'),
                      ),
                      TextField(
                        controller: phone,
                        maxLength: 40,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(labelText: 'Telefon (isteğe bağlı)'),
                      ),
                    ] else ...[
                      TextField(
                        controller: search,
                        decoration: const InputDecoration(
                          labelText: 'Kayıtlı müşteri ara',
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (_) => update(() {}),
                      ),
                      for (final customer in matching)
                        ListTile(
                          dense: true,
                          leading: Icon(chosenId == customer['id']
                              ? Icons.check_circle : Icons.person_outline),
                          title: Text((customer['name'] ?? '').toString()),
                          subtitle: Text((customer['phone'] ?? '').toString()),
                          selected: chosenId == customer['id'],
                          onTap: () => update(
                            () => chosenId = customer['id'] as int),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Vazgeç'),
              ),
              FilledButton(
                onPressed: (createNew ? name.text.trim().isNotEmpty
                    : chosenId != null)
                    ? () => Navigator.pop(
                      dialogContext,
                      createNew
                          ? (null, name.text.trim(), phone.text.trim())
                          : (chosenId, null, ''),
                    )
                    : null,
                child: const Text('Müşteriye Bağla'),
              ),
            ],
          );
        },
      ),
    );
    name.dispose();
    phone.dispose();
    search.dispose();
    if (result == null || !mounted) return;
    widget.onLinkCustomer(order['id'] as int, result.$1, result.$2, result.$3);
  }

  @override
  Widget build(BuildContext context) {
    final rows = accounts;
    final total = rows.fold<int>(0, (sum, a) => sum + a.dueCents);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Açık Hesaplar', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 5),
        const Text('Gel-Al · Ödenmemiş ve kısmen ödenmiş hesaplar. Bakiye gerçek ödeme kayıtlarından hesaplanır.'),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('Kalan Toplam: ' + formatTry(total),
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
          Text('· ' + rows.length.toString() + ' açık hesap'),
        ]),
        const SizedBox(height: 12),
        TextField(
          decoration: const InputDecoration(
            labelText: 'Müşteri adı, telefon veya sipariş numarası ara',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (s) => setState(() => query = s),
        ),
        const SizedBox(height: 12),
        if (rows.isEmpty)
          const Card(child: ListTile(title: Text('Açık Gel-Al hesabı bulunamadı.')))
        else
          for (final account in rows)
            Card(
              key: ValueKey(account.key),
              margin: const EdgeInsets.only(bottom: 10),
              child: ExpansionTile(
                leading: const Icon(Icons.account_balance_wallet_outlined),
                title: Text(account.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                subtitle: Text(
                  (account.phone.isEmpty ? '' : account.phone + ' · ') +
                  account.orders.length.toString() + ' ödenmemiş sipariş',
                ),
                trailing: Text(formatTry(account.dueCents),
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                children: [
                  if (account.key.startsWith('id:') || account.key.startsWith('phone:'))
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(
                          key: ValueKey('combined-pay-' + account.key),
                          onPressed: account.orders.length > 1
                              ? () => widget.onPayAccount(account.orders)
                              : null,
                          icon: const Icon(Icons.library_add_check),
                          label: const Text('Tüm Siparişleri Birlikte Öde'),
                        ),
                      ),
                    ),
                  if (account.key.startsWith('order:'))
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: Text('Telefon veya kayıtlı müşteri kimliği yok: aynı isimli farklı müşteriler yanlışlıkla birleştirilmez.'),
                    ),
                  for (final order in account.orders)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Divider(),
                          Text(
                            'Sipariş #' + displayOrderNumber(order).toString() +
                            ' · ' + istanbulStamp(order['createdAt']),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          for (final line in activeLines(order))
                            Text(
                              (line['qty'] ?? 0).toString() + '× ' +
                              (line['name'] ?? line['productKey'] ?? 'Ürün').toString(),
                            ),
                          const SizedBox(height: 6),
                          Text('Toplam ' + formatTry(orderTotalCents(order)) +
                              ' · Ödenen ' + formatTry(orderPaidCents(order)) +
                              ' · Kalan ' + formatTry(orderDueCents(order)),
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          Wrap(spacing: 8, children: [
                            OutlinedButton.icon(
                              onPressed: () => widget.onOpenOrder(order),
                              icon: const Icon(Icons.receipt_long_outlined),
                              label: const Text('Sipariş Detayı'),
                            ),
                            FilledButton.icon(
                              onPressed: () => widget.onPayOrder(order),
                              icon: const Icon(Icons.payments_outlined),
                              label: const Text('Ödeme Al'),
                            ),
                            if (!savedCustomers(widget.state).any((c) =>
                                order['customer'] is Map &&
                                c['id'] == (order['customer'] as Map)['id']))
                              OutlinedButton.icon(
                                key: ValueKey('link-legacy-' + order['id'].toString()),
                                onPressed: () => _linkLegacyOrder(order),
                                icon: const Icon(Icons.person_add_alt_1_outlined),
                                label: const Text('Müşteriye Bağla'),
                              ),
                          ]),
                        ],
                      ),
                    ),
                ],
              ),
            ),
      ],
    );
  }
}
