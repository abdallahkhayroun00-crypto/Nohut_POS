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

  testWidgets('daily materials ask for store first and color-filter search', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final state = <String, dynamic>{
      'employees': <dynamic>[],
      'orders': <dynamic>[],
      'marketPrices': {
        'tracked': [
          {'key': 'bim-nohut', 'market': 'BİM',
           'title': 'Nohut 1 Kg', 'unit': '1 KG',
           'depotName': 'İstiklal', 'priceCents': 6450},
          {'key': 'a101-nohut', 'market': 'A101',
           'title': 'Nohut 1 Kg', 'unit': '1 KG',
           'depotName': 'Bağlar', 'priceCents': 7000},
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
    await tester.tap(find.byKey(const ValueKey('finance-new-material')));
    await tester.pumpAndSettle();
    expect(find.text('Önce Marketi Seçin'), findsOneWidget);
    expect(find.byKey(const ValueKey('finance-store-BİM')), findsOneWidget);
    expect(find.byKey(const ValueKey('finance-store-A101')), findsOneWidget);
    expect(find.byKey(const ValueKey('finance-store-Hakmar')), findsOneWidget);
    expect(find.byKey(const ValueKey('finance-store-Diğer')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('finance-store-BİM')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('finance-material-search')),
      findsOneWidget);
    expect(find.byKey(const ValueKey('finance-market-product-bim-nohut')),
      findsOneWidget);
    expect(find.byKey(const ValueKey('finance-market-product-a101-nohut')),
      findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('finance-material-search')), 'not found');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('finance-market-product-bim-nohut')),
      findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('finance-material-search')), 'NOHUT');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('finance-market-product-bim-nohut')),
      findsOneWidget);

    await tester.ensureVisible(find.byKey(
      const ValueKey('finance-store-chip-A101')));
    await tester.tap(find.byKey(const ValueKey('finance-store-chip-A101')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('finance-market-product-bim-nohut')),
      findsNothing);
    expect(find.byKey(const ValueKey('finance-market-product-a101-nohut')),
      findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('finance-material-search')), 'noh');
    await tester.ensureVisible(find.byKey(
      const ValueKey('finance-market-live-search')));
    await tester.tap(find.byKey(
      const ValueKey('finance-market-live-search')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Market fiyat kaynağı etkin değil'),
      findsOneWidget);
    expect(find.byKey(const ValueKey('finance-manual-material')),
      findsOneWidget);
    expect(find.byKey(const ValueKey('finance-discount-type-Yok')),
      findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
