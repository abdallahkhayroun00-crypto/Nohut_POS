import 'dart:convert';

import 'package:flutter/material.dart';

import 'operations.dart';
import 'pos_logic.dart';
import 'receipt_layout.dart';

/// The same artwork is submitted to the physical printer.
class ReceiptPreview extends StatefulWidget {
  const ReceiptPreview({super.key, this.order, this.text, this.settings})
    : assert(order != null || text != null);
  final Json? order;

  /// Any slip text (Sipariş Fişi, Trendyol, Toplu Hesap); defaults to the
  /// order's Hesap Özeti.
  final String? text;
  final Map? settings;
  String get slip => text ?? billText(order!);
  @override
  State<ReceiptPreview> createState() => _ReceiptPreviewState();
}

class _ReceiptPreviewState extends State<ReceiptPreview> {
  late Future<ReceiptArtwork> artwork;
  late String signature;
  String? configurationError;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    signature = jsonEncode([widget.order, widget.text, widget.settings]);
    try {
      ReceiptDimensions(widget.settings);
      configurationError = null;
      artwork = renderReceipt(widget.slip, settings: widget.settings);
    } on FormatException catch (e) {
      configurationError = e.message;
    }
  }

  @override
  void didUpdateWidget(covariant ReceiptPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (signature != jsonEncode([widget.order, widget.text, widget.settings])) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (configurationError != null)
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Ayarlar → Yazıcı: $configurationError'),
      );
    final cfg = ReceiptDimensions(widget.settings);
    final left = (cfg.paper - cfg.width) / 2 + cfg.offset;
    return Semantics(
      label: '${receiptTitle(widget.slip)}\n${widget.slip}\nAfiyet olsun!',
      image: true,
      child: Container(
        width: cfg.paper * 5,
        color: Colors.white,
        padding: EdgeInsets.only(
          left: left * 5,
          right: (cfg.paper - cfg.width - left) * 5,
        ),
        child: FutureBuilder<ReceiptArtwork>(
          future: artwork,
          builder: (context, snapshot) {
            if (snapshot.hasError)
              return Padding(
                padding: const EdgeInsets.all(12),
                child: Text('Fiş hazırlanamadı: ${snapshot.error}'),
              );
            if (!snapshot.hasData)
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Fiş hazırlanıyor…', textAlign: TextAlign.center),
              );
            return Image.memory(
              snapshot.data!.png,
              key: const ValueKey('receipt-artwork'),
              width: cfg.width * 5,
              fit: BoxFit.fitWidth,
              excludeFromSemantics: true,
            );
          },
        ),
      ),
    );
  }
}
