import 'dart:convert';
import 'dart:math' as math;

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
  String? configurationError;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    signature = jsonEncode([widget.order, widget.settings]);
    try {
      ReceiptDimensions(widget.settings);
      configurationError = null;
      artwork = renderReceipt(
        billText(widget.order),
        settings: widget.settings,
      );
    } on FormatException catch (e) {
      configurationError = e.message;
    }
  }

  @override
  void didUpdateWidget(covariant ReceiptPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (signature != jsonEncode([widget.order, widget.settings])) _load();
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
    // The very same raster file is sent to the driver. Scale the PAPER and
    // printed artwork together; a 56-mm preview must not overflow a narrower
    // settings card and hide the receipt's right edge.
    return Semantics(
      label: 'HESAP ÖZETİ\n${billText(widget.order)}\nAfiyet olsun!',
      image: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final available = constraints.maxWidth.isFinite
              ? math.max(1.0, constraints.maxWidth - 2)
              : cfg.paper * 5;
          final scale = math.min(5.0, available / cfg.paper);
          return Center(
            child: Container(
              key: const ValueKey('receipt-paper'),
              width: cfg.paper * scale,
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(
                  color: const Color(0xffD6D6D6), width: 0.5),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x1A000000),
                    blurRadius: 10,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              padding: EdgeInsets.only(
                left: left * scale,
                right: (cfg.paper - cfg.width - left) * scale,
              ),
              child: FutureBuilder<ReceiptArtwork>(
                future: artwork,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('Fiş hazırlanamadı: ${snapshot.error}'),
                    );
                  }
                  if (!snapshot.hasData) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Fiş hazırlanıyor…', textAlign: TextAlign.center),
                    );
                  }
                  return Image.memory(
                    snapshot.data!.png,
                    key: const ValueKey('receipt-artwork'),
                    width: cfg.width * scale,
                    fit: BoxFit.fitWidth,
                    excludeFromSemantics: true,
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}
