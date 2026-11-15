import 'package:flutter/material.dart';
import 'operations.dart';
import 'pos_logic.dart';
import 'order_reporting.dart';

class ReceiptPreview extends StatelessWidget {
  const ReceiptPreview({super.key, required this.order, this.settings});
  final Json order;
  final Map? settings;
  @override
  Widget build(BuildContext context) {
    final paper = (settings?['paperWidthMm'] as num? ?? 56).toDouble(),
        content = (settings?['printableWidthMm'] as num? ?? 48)
            .toDouble()
            .clamp(30, paper - 2),
        offset = (settings?['receiptOffsetMm'] as num? ?? 0).toDouble();
    final left = ((paper - content) / 2 + offset)
        .clamp(1, paper - content - 1)
        .toDouble();
    Widget row(String label, String value, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: bold ? 18 : 14,
                fontWeight: bold ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: bold ? 18 : 14,
              fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
    return DefaultTextStyle(
      style: const TextStyle(
        fontFamily: 'Arial',
        fontSize: 14,
        color: Colors.black,
      ),
      child: Container(
        width: paper * 5,
        color: Colors.white,
        padding: EdgeInsets.fromLTRB(
          left * 5,
          20,
          (paper - content - left) * 5,
          20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Image.asset(
                'assets/printing/nohut-receipt-logo.png',
                width: (settings?['receiptLogoMm'] as num? ?? 18) * 5,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'HESAP ÖZETİ',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            row(
              '#${displayOrderNumber(order)}',
              order['source'] == 'Masa' ? 'Masa ${order['table']}' : 'Gel-Al',
            ),
            Text(istanbulStamp(order['createdAt'])),
            const Divider(color: Colors.black),
            for (final l in checkLines(order)) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 25,
                      child: Text(
                        '${l.line['qty']}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '${l.line['name']}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 89,
                      child: Text(
                        formatTry(l.total),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              ),
              if ('${l.line['note'] ?? ''}'.isNotEmpty)
                Text('Not: ${l.line['note']}'),
              if ((l.line['removed'] as List? ?? []).isNotEmpty)
                Text('Çıkar: ${(l.line['removed'] as List).join(', ')}'),
              if ((l.line['adjustmentCents'] as int? ?? 0) != 0)
                Text(
                  'Adet farkı: ${formatTry(l.line['adjustmentCents'] as int)}',
                ),
            ],
            const Divider(color: Colors.black),
            row('TOPLAM', formatTry(orderTotalCents(order)), bold: true),
            row('Ödenen', formatTry(orderPaidCents(order))),
            row('Kalan', formatTry(orderDueCents(order))),
            const Divider(color: Colors.black),
            const Text(
              'Afiyet olsun!',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 19),
            ),
            const SizedBox(height: 10),
            const Text(
              'MALİ FİŞ DEĞİLDİR',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
