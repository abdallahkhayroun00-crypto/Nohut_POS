import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/receipt_preview.dart';

void main() {
  testWidgets(
    'legacy oversized or displaced receipt settings show actionable help without crashing',
    (t) async {
      for (final settings in [
        <String, dynamic>{'printableWidthMm': 80},
        <String, dynamic>{'receiptOffsetMm': 8},
      ]) {
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReceiptPreview(order: const {}, settings: settings),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(find.textContaining('Ayarlar → Yazıcı'), findsOneWidget);
        expect(t.takeException(), isNull);
      }
    },
  );
}
