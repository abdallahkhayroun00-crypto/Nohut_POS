import 'dart:convert';

import 'package:flutter/material.dart';

import 'operations.dart';
import 'pos_logic.dart';
import 'receipt_layout.dart';

/// The same artwork is submitted to the physical printer.
class ReceiptPreview extends StatefulWidget {
  const ReceiptPreview({super.key, required this.order, this.settings});
  final Json order;
  final Map? settings;
  @override
  State<ReceiptPreview> createState() => _ReceiptPreviewState();
}

class _ReceiptPreviewState extends State<ReceiptPreview> {
  late Future<ReceiptArtwork> artwork;
  late String signature;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    signature = jsonEncode([widget.order, widget.settings]);
    artwork = renderReceipt(billText(widget.order), settings: widget.settings);
  }

  @override
  void didUpdateWidget(covariant ReceiptPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (signature != jsonEncode([widget.order, widget.settings])) _load();
  }

  @override
  Widget build(BuildContext context) {
    final cfg = ReceiptDimensions(widget.settings);
    final left = (cfg.paper - cfg.width) / 2 + cfg.offset;
    return Semantics(
      label: 'HESAP ÖZETİ\n${billText(widget.order)}\nAfiyet olsun!',
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
                child: Center(child: CircularProgressIndicator()),
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
