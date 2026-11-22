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
      // FittedBox supports intrinsic sizing when embedded in AlertDialog,
      // unlike LayoutBuilder. Scale the entire physical paper, never crop
      // or scale only the receipt contents.
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.topCenter,
          child: Container(
            key: const ValueKey('receipt-paper'),
            width: cfg.paper * 5,
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
              left: left * 5,
              right: (cfg.paper - cfg.width - left) * 5,
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
                  width: cfg.width * 5,
                  fit: BoxFit.fitWidth,
                  excludeFromSemantics: true,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
