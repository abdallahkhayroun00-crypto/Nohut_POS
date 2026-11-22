import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/receipt_preview.dart';
import 'package:nohut_falafel_desktop/receipt_printer.dart';
import 'package:nohut_falafel_desktop/receipt_layout.dart';
import 'package:nohut_falafel_desktop/operations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Ctrl+P dialog is opt-in, previews actual raster and supports cancel', () async {
    final script = await rootBundle.loadString(
      'assets/printing/print-raster.ps1');
    expect(script, contains(r'$job.showWindowsPrintDialog'));
    expect(script, contains('System.Windows.Forms.PrintDialog'));
    expect(script, contains('System.Windows.Forms.PrintPreviewDialog'));
    expect(script, contains('NOHUT_DIALOG_CANCELLED'));
    expect(script, contains('NOHUT_DIALOG_PRINTED'));
    expect(script, contains(r'if($dialogMode)'));
    expect(script, contains(r'$doc.Print()'));
    expect(script, contains('Windows Fiş Önizleme ve Yazdır'));
  });

  test('native Windows print dialog refuses non-Windows host', () async {
    if (!Platform.isWindows) {
      await expectLater(
        windowsPrintWithDialog('Test', ''),
        throwsA(isA<FormatException>()),
      );
    }
  });

  testWidgets('56mm receipt preview retains its entire width in a narrow card',
      (tester) async {
    final order = <String, dynamic>{
      'id': 11, 'dailyNumber': 1, 'source': 'Masa',
      'table': 3, 'createdAt': '2026-11-18T09:00:00Z',
      'batches': [
        {'id': 1, 'lines': [
          {'name': 'Falafel Dürüm', 'qty': 1, 'price': 140},
          {'name': 'Ek Lavaş', 'qty': 1, 'price': 10},
        ]},
      ],
      'payments': [],
    };
    // The receipt raster loads an asset and renders asynchronously. Resolve
    // the actual artwork first rather than assuming pumpAndSettle waits for IO.
    final settings = <String, dynamic>{'paperWidthMm': 56,
      'printableWidthMm': 48};
    final ready = await tester.runAsync(() =>
      renderReceipt(billText(order), settings: settings));
    expect(ready, isNotNull);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 195,
            child: SingleChildScrollView(
              child: ReceiptPreview(order: order,
                settings: settings),
            ),
          ),
        ),
      ),
    ));
    // FutureBuilder can complete after the first test frame even when the
    // raster Future was pre-cached. Let real image/asset microtasks finish,
    // then pump the matching frame instead of assuming pumpAndSettle is IO.
    final raster = find.byKey(const ValueKey('receipt-artwork'),
      skipOffstage: false);
    for (var attempt = 0; attempt < 20 && raster.evaluate().isEmpty; attempt++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      });
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.pumpAndSettle();
    final paper = find.byKey(const ValueKey('receipt-paper'));
    expect(paper, findsOneWidget);
    expect(tester.getRect(paper).width, lessThanOrEqualTo(195));
    final errorText = find.textContaining('Fiş hazırlanamadı',
      skipOffstage: false);
    expect(errorText, findsNothing,
      reason: 'ReceiptPreview must not fail to render the raster.');
    expect(raster, findsOneWidget,
      reason: 'Raster still absent after async frames. '
        'Loading: ${find.textContaining('Fiş hazırlanıyor', skipOffstage: false).evaluate().length}; '
        'Errors: ${errorText.evaluate().length}');
    expect(tester.takeException(), isNull);
  });
}
