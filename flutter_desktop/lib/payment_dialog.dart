import 'package:flutter/material.dart';
import 'brand.dart';
import 'operations_ui.dart';
import 'pos_logic.dart';

class PaymentEntryDialog extends StatefulWidget {
  const PaymentEntryDialog({
    super.key,
    required this.dueCents,
    required this.orderNumber,
    this.guestName = '',
    this.inposReady = false,
    this.fixedAmount = false,
  });
  final bool inposReady, fixedAmount;
  final int dueCents;
  final String orderNumber, guestName;
  @override
  State<PaymentEntryDialog> createState() => _PaymentEntryDialogState();
}

class _PaymentEntryDialogState extends State<PaymentEntryDialog> {
  late final amount = TextEditingController(
    text: (widget.dueCents / 100).toStringAsFixed(2),
  );
  late final received = TextEditingController(
    text: (widget.dueCents / 100).toStringAsFixed(2),
  );
  final cashPart = TextEditingController();
  String method = 'Nakit';
  String? error;
  @override
  void dispose() {
    cashPart.dispose();
    amount.dispose();
    received.dispose();
    super.dispose();
  }

  String get change {
    try {
      final n = parseMoney(method == 'Karışık' ? cashPart.text : amount.text),
          r = parseMoney(received.text);
      return r < n ? 'Alınan nakit yetersiz' : 'Para üstü: ${formatTry(r - n)}';
    } on FormatException {
      return 'Tutarları girin';
    }
  }

  int get cardCents {
    try {
      final card = parseMoney(amount.text) - parseMoney(cashPart.text);
      return card < 0 ? 0 : card;
    } on FormatException {
      return 0;
    }
  }

  bool get changeOk {
    try {
      final n = parseMoney(method == 'Karışık' ? cashPart.text : amount.text),
          r = parseMoney(received.text);
      return r >= n;
    } on FormatException {
      return false;
    }
  }

  void setMethod(String m) => setState(() {
    method = m;
    error = null;
  });

  Widget methodTile(String value, IconData icon, String note) {
    final selected = method == value;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Material(
          color: selected ? NohutBrand.green : Colors.white,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setMethod(value),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected ? NohutBrand.green : const Color(0xffD5DED8)),
              ),
              child: Column(
                children: [
                  Icon(icon, color: selected ? Colors.white : NohutBrand.green),
                  const SizedBox(height: 4),
                  Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w800,
                      color: selected ? Colors.white : NohutBrand.ink)),
                  Text(note, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11,
                      color: selected ? const Color(0xffBFD6C8) : NohutBrand.muted)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget quick(String label, VoidCallback onTap) => OutlinedButton(
    style: OutlinedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 12),
    ),
    onPressed: onTap,
    child: Text(label),
  );

  void submit() {
    try {
      final n = parseMoney(amount.text),
          r = method == 'Nakit'
              ? parseMoney(received.text)
              : method == 'Karışık'
              ? parseMoney(cashPart.text)
              : null;
      if (n <= 0 || n > widget.dueCents)
        throw const FormatException(
          'Tutar kalan bakiyeyi aşamaz ve sıfır olamaz.',
        );
      if (method == 'Karışık' && (r == null || r <= 0 || r >= n))
        throw const FormatException(
          'Nakit kısmı toplamdan küçük ve sıfırdan büyük olmalı',
        );
      if (method == 'Nakit' && r != null && r < n)
        throw const FormatException('Alınan nakit tutarı yetersiz.');
      final mixedReceived = method == 'Karışık'
          ? parseMoney(received.text)
          : null;
      if (mixedReceived != null && mixedReceived < r!) {
        throw const FormatException('Alınan nakit yetersiz.');
      }
      Navigator.pop(context, (n, method, r, mixedReceived));
    } on FormatException catch (e) {
      setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cash = method == 'Nakit' || method == 'Karışık';
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      title: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Ödeme · #${widget.orderNumber} ${widget.guestName}'),
                const SizedBox(height: 2),
                const Text('Kısmi veya Nakit + Kart ödeme alabilirsiniz.',
                  style: TextStyle(fontSize: 12.5, color: NohutBrand.muted,
                    fontFamily: NohutBrand.bodyFont)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text('KALAN', style: TextStyle(fontSize: 11,
                letterSpacing: 1.1, fontWeight: FontWeight.w800,
                color: NohutBrand.muted, fontFamily: NohutBrand.bodyFont)),
              Text(formatTry(widget.dueCents), style: const TextStyle(
                fontSize: 24, fontWeight: FontWeight.w900,
                fontFamily: NohutBrand.bodyFont, color: NohutBrand.ink)),
            ],
          ),
        ],
      ),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 6),
              Row(children: [
                methodTile('Nakit', Icons.payments_outlined, 'Para üstü hesaplanır'),
                methodTile('Kart', Icons.credit_card, 'Banka terminali'),
                methodTile('Karışık', Icons.call_split, 'Nakit + Kart'),
                if (widget.inposReady)
                  methodTile('inPOS m530', Icons.point_of_sale, 'Cihaza gönder'),
              ]),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('payment-amount'),
                controller: amount,
                readOnly: widget.fixedAmount,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Tutar (₺)',
                  prefixIcon: Icon(Icons.receipt_long_outlined),
                ),
                onChanged: (_) => setState(() => error = null),
              ),
              if (!widget.fixedAmount) ...[
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  quick('Kalanın tamamı', () => setState(() {
                    amount.text = (widget.dueCents / 100).toStringAsFixed(2);
                    error = null;
                  })),
                  quick('Yarısı', () => setState(() {
                    amount.text = (widget.dueCents / 200).toStringAsFixed(2);
                    error = null;
                  })),
                ]),
              ],
              if (method == 'Karışık') ...[
                const SizedBox(height: 14),
                TextField(
                  controller: cashPart,
                  onChanged: (_) => setState(() => error = null),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Nakit kısmı (₺) · kalan Kart',
                    prefixIcon: Icon(Icons.payments_outlined),
                  ),
                ),
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.credit_card, size: 18, color: NohutBrand.green),
                  const SizedBox(width: 6),
                  Text('Kart: ${formatTry(cardCents)}', style: const TextStyle(
                    fontWeight: FontWeight.w800)),
                ]),
              ],
              if (cash) ...[
                const SizedBox(height: 14),
                TextField(
                  key: const ValueKey('payment-received'),
                  controller: received,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Alınan nakit (₺)',
                    prefixIcon: Icon(Icons.account_balance_wallet_outlined),
                  ),
                  onChanged: (_) => setState(() => error = null),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final option in [0, 50, 100, 200, 500, 1000])
                      quick(option == 0 ? 'Tam tutar' : '$option TL', () => setState(() {
                        received.text = option == 0
                            ? (method == 'Karışık'
                                  ? cashPart.text
                                  : amount.text)
                            : '$option';
                        error = null;
                      })),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: changeOk ? const Color(0xffE8F4EC) : const Color(0xffFBE9E6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(children: [
                    Icon(changeOk ? Icons.check_circle_outline : Icons.info_outline,
                      color: changeOk ? const Color(0xff2E7D4F) : const Color(0xffB3261E)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        change,
                        key: const ValueKey('payment-change'),
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: changeOk ? const Color(0xff1E5A37) : const Color(0xff8c352e),
                        ),
                      ),
                    ),
                  ]),
                ),
              ],
              if (method != 'Nakit') ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xffFFF6E0),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline, size: 18, color: Color(0xff8A6516)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          method == 'inPOS m530'
                              ? 'Tutar eşleştirilmiş inPOS cihazına gönderilir. Ödeme yalnızca cihaz onayından sonra kaydedilir.'
                              : 'Banka terminalinde başarılı tahsilatı ayrıca doğrulayın. Bu ekran bankaya işlem göndermez.',
                          style: const TextStyle(color: Color(0xff775624)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    key: const ValueKey('payment-error'),
                    style: const TextStyle(color: Color(0xff8c352e),
                      fontWeight: FontWeight.w700),
                  ),
                ),
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Vazgeç'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(220, 48)),
          onPressed: submit,
          icon: const Icon(Icons.arrow_forward),
          label: const Text('Ödemeyi Gözden Geçir'),
        ),
      ],
    );
  }
}
