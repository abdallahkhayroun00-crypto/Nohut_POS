import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/finance_ui.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';

void main() {
  testWidgets('quick purchase sums three market receipt amounts and saves once', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final state = <String, dynamic>{'orders': <dynamic>[]};
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: FinancePanel(
        state: state, edit: (void Function(Json) change) {
          change(state); return true;
        },
      ))),
    ));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Günlük Malzeme'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('finance-new-quick-material')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('finance-store-BİM')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      if (i > 0) {
        final add = find.byKey(const ValueKey('finance-quick-add-amount'));
        await tester.ensureVisible(add);
        await tester.tap(add);
        await tester.pumpAndSettle();
      }
      final field = find.byKey(ValueKey('finance-quick-amount-$i'));
      await tester.ensureVisible(field);
      await tester.enterText(field, ['50', '60', '300'][i]);
      await tester.pumpAndSettle();
    }
    final save = find.byKey(const ValueKey('finance-quick-save'));
    await tester.tap(save);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    final rows = state['finance']['materials'] as List;
    expect(rows.length, 1);
    expect(rows.single['totalCents'], 41000);
    expect(rows.single['storeBrand'], 'BİM');
    expect(rows.single['quantityMilli'], isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Giderler offers only Hızlı Gider Ekle; itemized history stays', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final today = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final day = '${today.year}-${two(today.month)}-${two(today.day)}';
    final state = <String, dynamic>{
      'employees': <dynamic>[],
      'orders': <dynamic>[],
      'finance': {
        'materials': [
          {'id': 1, 'date': day, 'title': 'Nohut', 'market': 'BİM',
           'storeBrand': 'BİM', 'quantityMilli': 2000, 'unit': 'kg',
           'pricePerUnitCents': 6450, 'discountCents': 0,
           'totalCents': 12900, 'paymentMethod': 'Nakit'},
        ],
      },
    };
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(
        child: FinancePanel(
          state: state,
          edit: (void Function(Json) change) {
            change(state);
            return true;
          },
        ),
      )),
    ));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Günlük Malzeme'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('finance-new-material')), findsNothing);
    expect(find.text('Malzeme Ekle'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Hızlı Gider Ekle'), findsOneWidget);
    // Legacy itemized purchase is still listed with its details and total.
    expect(find.text('Nohut'), findsOneWidget);
    expect(find.textContaining('kg ×'), findsOneWidget);
    expect(find.textContaining('129,00'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('finance-new-quick-material')));
    await tester.pumpAndSettle();
    expect(find.text('Hızlı Gider Ekle'), findsWidgets);
    expect(find.byKey(const ValueKey('finance-material-search')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
