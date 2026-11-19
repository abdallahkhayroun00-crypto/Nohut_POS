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
  });
  final Json state;
  final ValueChanged<Json> onOpenOrder;
  final ValueChanged<Json> onPayOrder;

  @override
  State<OpenAccountsPanel> createState() => _OpenAccountsPanelState();
}

class _OpenAccountsPanelState extends State<OpenAccountsPanel> {
  String query = '';
  bool includeTables = false;

  List<PickupAccount> get accounts {
    final customers = pickupOpenAccounts(widget.state);
    if (includeTables) {
      final tableOrders = <int, List<Json>>{};
      for (final order in asMaps(widget.state['orders'])) {
        if (order['source'] != 'Masa' || order['cancelled'] == true ||
            orderDueCents(order) <= 0 || order['table'] is! int) continue;
        tableOrders.putIfAbsent(order['table'] as int, () => <Json>[]).add(order);
      }
      for (final entry in tableOrders.entries) {
        customers.add(PickupAccount(
          key: 'table:' + entry.key.toString(),
          name: 'Masa ' + entry.key.toString(),
          phone: '',
          orders: entry.value,
          dueCents: entry.value.fold<int>(0, (sum, o) =>
              sum + orderDueCents(o)),
        ));
      }
    }
    final q = query.trim().toLowerCase();
    return customers.where((account) => q.isEmpty ||
        account.name.toLowerCase().contains(q) ||
        account.phone.contains(q) ||
        account.orders.any((o) =>
            displayOrderNumber(o).toString().contains(q))).toList();
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
        const Text('Ödenmemiş ve kısmen ödenmiş hesaplar; bakiye her siparişin gerçek ödeme kaydından hesaplanır.'),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          ChoiceChip(
            label: const Text('Gel-Al'),
            selected: !includeTables,
            onSelected: (_) => setState(() => includeTables = false),
          ),
          ChoiceChip(
            label: const Text('Tüm Açık Hesaplar'),
            selected: includeTables,
            onSelected: (_) => setState(() => includeTables = true),
          ),
          const SizedBox(width: 12),
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
          const Card(child: ListTile(title: Text('Bu filtrede açık hesap bulunamadı.')))
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
