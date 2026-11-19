import 'package:flutter/material.dart';

import 'brand.dart';
import 'pos_logic.dart';
import 'order_reporting.dart';

/// Non-actionable acknowledgment dialog for a new order sent from a staff
/// phone. No acceptance, preparation, or cancellation workflows are here.
class StaffOrderPopup extends StatelessWidget {
  const StaffOrderPopup({
    super.key,
    required this.notice,
    required this.order,
    required this.onOpen,
    required this.onDismiss,
  });

  final Json notice;
  final Json? order;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final isExtra = notice['action'] == 'Ek sipariş';
    final place = notice['table'] == null
        ? 'Gel-Al' : 'Masa ${notice['table']}';
    final batches = order == null ? <Json>[] : asMaps(order!['batches']);
    // An extra order notice displays the most recent staff-submitted batch.
    final lines = batches.isEmpty ? <Json>[] : asMaps(batches.last['lines']);
    final width = MediaQuery.sizeOf(context).width;
    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(22, 22, 22, 10),
      contentPadding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
      actionsPadding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
      title: Row(children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xffE7F3EA),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(Icons.notifications_active_outlined,
              color: NohutBrand.green, size: 28),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(isExtra ? 'PERSONELDEN EK SİPARİŞ' : 'PERSONELDEN YENİ SİPARİŞ',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17,
                color: NohutBrand.green)),
            Text(place, style: const TextStyle(fontSize: 14)),
          ],
        )),
      ]),
      content: SizedBox(
        width: width < 550 ? width - 95 : 470,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Personel: ${notice['staff'] ?? '—'}'
                '${order == null ? '' : ' · Sipariş #${displayOrderNumber(order!)}'}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Divider(),
              if (lines.isEmpty)
                const Text('Sipariş kaydedildi. Ayrıntılar için açın.'),
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Text(
                    '${line['qty'] ?? 1} × ${line['name'] ?? line['productKey'] ?? 'Ürün'}'
                    '${(line['note'] ?? '').toString().trim().isEmpty ? '' : ' · ${line['note']}'}',
                    style: const TextStyle(fontSize: 15),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: onDismiss,
          child: const Text('Tamam'),
        ),
        FilledButton.icon(
          onPressed: onOpen,
          icon: const Icon(Icons.receipt_long_outlined),
          label: const Text('Siparişi Aç'),
        ),
      ],
    );
  }
}
