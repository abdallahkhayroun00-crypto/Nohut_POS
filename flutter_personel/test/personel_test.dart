import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_personel/home.dart';
import 'package:nohut_personel/models.dart';
import 'package:nohut_personel/pos_api.dart';
import 'package:nohut_personel/style.dart';

void main() {
  test('QR pairing only accepts a private restaurant LAN address', () {
    final valid = NohutApi.normalizeQr('http://192.168.1.105:8787/personel');
    expect(valid?.host, '192.168.1.105');
    expect(valid?.port, 8787);
    expect(NohutApi.normalizeQr('https://example.com/personel'), isNull);
    expect(NohutApi.normalizeQr('http://8.8.8.8:8787/personel'), isNull);
    expect(NohutApi.normalizeQr('http://192.168.1.2:8787/evil'), isNull);
    expect(NohutApi.normalizeQr('http://10.12.0.1:8787/personel'), isNotNull);
    expect(NohutApi.normalizeQr('http://172.20.0.5:8787/personel'), isNotNull);
  });

  test('cart line maps to server validated price and employee payload', () {
    final cart = CartEntry({
      'id': 5, 'name': 'Falafel Dürüm', 'price': 140,
    }, qty: 2, note: 'Az acılı', removed: ['Soğan']);
    expect(cart.totalCents, 28000);
    expect(cart.asOrderLine()['expectedPriceCents'], 14000);
    expect(cart.asOrderLine()['removed'], ['Soğan']);
    expect(money(14000), '140,00 ₺');
  });

  testWidgets('native Android phone layout has 5 tabs and Nohut tables',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final c = PersonelController(NohutApi(), StaffNotifications());
    c.state = {
      'employees': [{'id': 1, 'name': 'Ömer', 'active': true}],
      'localMenu': [{'id': 1, 'name': 'Falafel Dürüm', 'price': 140}],
      'orders': <dynamic>[],
    };
    c.online = true;
    addTearDown(c.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: NohutStyle.theme,
      home: StaffHome(controller: c, onUnpair: () {}),
    ));
    expect(find.byType(NavigationBar), findsOneWidget);
    // §24.3: staff open on Ana Sayfa with the quick actions.
    expect(find.text('Hoş geldiniz'), findsOneWidget);
    for (final label in ['Ana Sayfa', 'Masalar', 'Sipariş', 'Siparişler', 'Daha Fazla']) {
      expect(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)), findsOneWidget);
    }
    await tester.tap(find.text('Masalar').last);
    await tester.pumpAndSettle();
    expect(find.text('Masa 1'), findsOneWidget);
    expect(find.text('Masa 5'), findsOneWidget);
    await tester.tap(find.text('Ana Sayfa').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sipariş Al'));
    await tester.pumpAndSettle();
    expect(find.text('Falafel Dürüm'), findsOneWidget);
    await tester.tap(find.byTooltip('Sepete Ekle').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('go-cart')));
    await tester.pumpAndSettle();
    expect(find.text('Sipariş Sepeti'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-more')));
    await tester.pumpAndSettle();
    expect(find.text('Falafel Dürüm'), findsOneWidget);
  });

  testWidgets('native Android tablet uses NavigationRail instead of bottom navigation',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final c = PersonelController(NohutApi(), StaffNotifications());
    c.state = {
      'employees': <dynamic>[],
      'localMenu': <dynamic>[],
      'orders': <dynamic>[],
    };
    c.online = false;
    addTearDown(c.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: NohutStyle.theme,
      home: StaffHome(controller: c, onUnpair: () {}),
    ));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });
}
