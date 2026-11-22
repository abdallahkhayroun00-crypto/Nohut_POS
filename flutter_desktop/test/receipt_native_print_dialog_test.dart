import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/receipt_preview.dart';
import 'package:nohut_falafel_desktop/receipt_printer.dart';

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
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 195,
            child: SingleChildScrollView(
              child: ReceiptPreview(order: order,
                settings: const {'paperWidthMm': 56,
                  'printableWidthMm': 48}),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final paper = find.byKey(const ValueKey('receipt-paper'));
    expect(paper, findsOneWidget);
    expect(tester.getSize(paper).width, lessThanOrEqualTo(195));
    expect(find.byKey(const ValueKey('receipt-artwork')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
