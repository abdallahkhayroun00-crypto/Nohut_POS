import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_personel/home.dart';
import 'package:nohut_personel/pos_api.dart';
import 'package:nohut_personel/style.dart';

PersonelController _controller() {
  final c = PersonelController(NohutApi(), StaffNotifications());
  c.state = {
    'employees': [{'id': 1, 'name': 'Ömer', 'active': true}],
    'localMenu': [
      {'id': 1, 'name': 'Falafel Dürüm', 'price': 140},
      {'id': 2, 'name': 'Çay', 'price': 20},
    ],
    'orders': [
      {'id': 9, 'source': 'Masa', 'table': 1, 'batches': [
        {'lines': [{'name': 'Çay', 'qty': 2, 'price': 20}]},
      ]},
    ],
  };
  c.online = true;
  return c;
}

Future<void> _open(WidgetTester t, PersonelController c) async {
  t.view.physicalSize = const Size(400, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
  addTearDown(c.dispose);
  await t.pumpWidget(MaterialApp(
    theme: NohutStyle.theme,
    home: StaffHome(controller: c, onUnpair: () {}),
  ));
}

void main() {
  testWidgets('one unit of a multi-unit line gets its own removed ingredients', (t) async {
    final c = _controller();
    await _open(t, c);
    await t.tap(find.text('Sipariş Al'));
    await t.pumpAndSettle();
    final add = find.byTooltip('Sepete Ekle').first;
    await t.tap(add);
    await t.pump();
    await t.tap(add);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('go-cart')));
    await t.pumpAndSettle();
    expect(find.text('2 × 140,00 ₺'), findsOneWidget);
    await t.tap(find.text('Not / Malzeme'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('customize-one-unit')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('edit-removed')), 'Soğan');
    await t.tap(find.byKey(const ValueKey('edit-save')));
    await t.pumpAndSettle();
    expect(find.text('1 × 140,00 ₺'), findsNWidgets(2));
    expect(find.text('Çıkar: Soğan'), findsOneWidget);
    expect(find.text('Not / Malzeme'), findsOneWidget);
  });

  testWidgets('Ek Sipariş repeats an account item with one tap', (t) async {
    final c = _controller();
    await _open(t, c);
    await t.tap(find.text('Masalar').last);
    await t.pumpAndSettle();
    await t.tap(find.text('Masa 1'));
    await t.pumpAndSettle();
    await t.tap(find.text('Ürün Ekle'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Sepete Ekle').first);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('go-cart')));
    await t.pumpAndSettle();
    final chip = find.byKey(const ValueKey('quick-add-2'));
    expect(chip, findsOneWidget);
    await t.tap(chip);
    await t.pump();
    await t.tap(chip);
    await t.pumpAndSettle();
    expect(find.text('2 × 20,00 ₺'), findsOneWidget);
  });
}
