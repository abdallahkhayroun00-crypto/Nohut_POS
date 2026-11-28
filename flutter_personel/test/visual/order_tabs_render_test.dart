// Personel order flow screens (Masalar, Ürünler, Sepet, Siparişler) with
// synthetic data. NOHUT_RENDER_DIR writes PNGs for visual review.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_personel/home.dart';
import 'package:nohut_personel/models.dart';
import 'package:nohut_personel/pos_api.dart';
import 'package:nohut_personel/style.dart';

import 'render_harness.dart';
import 'screens_render_test.dart' show staffController, workApi;

PersonelController busyController() {
  final api = workApi()..sessionInfo = {'session': {'status': 'ok', 'employeeId': 1, 'username': 'personela'}};
  final c = PersonelController(api, StaffNotifications())
    ..state = staffController().state
    ..online = true;
  c.state['orders'] = [
    {'id': 11, 'source': 'Masa', 'table': 2, 'dailyNumber': 4, 'createdAt': '2026-11-28T09:10:00Z',
     'batches': [{'lines': [{'name': 'Test Falafel Dürüm', 'qty': 2, 'price': 140}, {'name': 'Test Ayran', 'qty': 2, 'price': 35}]}],
     'payments': []},
    {'id': 12, 'source': 'Masa', 'table': 4, 'dailyNumber': 5, 'createdAt': '2026-11-28T09:40:00Z',
     'batches': [{'lines': [{'name': 'Test Humus Tabağı', 'qty': 1, 'price': 165}]}], 'payments': []},
    {'id': 13, 'source': 'Gel-Al', 'dailyNumber': 6, 'createdAt': '2026-11-28T10:05:00Z',
     'batches': [{'lines': [{'name': 'Test Falafel Dürüm', 'qty': 1, 'price': 140}]}], 'payments': []},
  ];
  return c;
}

void main() {
  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await loadNohutFonts();
  });

  for (final (label, size, scale, mode) in [
    ('phone', const Size(412, 915), 1.0, Brightness.light),
    ('phone-dark', const Size(412, 915), 1.0, Brightness.dark),
    ('compact', const Size(320, 640), 1.3, Brightness.light),
  ]) {
    for (final tab in ['Masalar', 'Sipariş', 'Siparişler', 'Masa 1', 'Sepet']) {
      testWidgets('$tab $label', (t) async {
        final c = busyController();
        await renderScreen(t, 'order-${tab.toLowerCase().replaceAll(' ', '')}-$label', MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
          builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
          home: StaffHome(controller: c, onUnpair: () {})),
          size: size, brightness: mode,
          before: (t) async {
            if (tab == 'Sepet') {
              // A free table, three items.
              await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Masalar')));
              await t.pumpAndSettle();
              await t.tap(find.text('Masa 1'));
              await t.pumpAndSettle();
              final add = find.byTooltip('Sepete Ekle');
              await t.tap(add.first);
              await t.tap(add.first);
              await t.tap(add.at(1));
              await t.pumpAndSettle();
              await t.tap(find.byKey(const ValueKey('go-cart')));
            } else if (tab == 'Masa 1') {
              // Choosing a free table opens the product list for it.
              await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Masalar')));
              await t.pumpAndSettle();
              await t.tap(find.text('Masa 1'));
            } else {
              await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(tab)));
            }
            await t.pumpAndSettle();
          });
        expect(t.takeException(), isNull);
        if (tab == 'Masa 1') {
          // Windows category keys are shown in Turkish, Windows order.
          expect(find.text('Dürümler'), findsOneWidget);
          expect(find.text('wrap'), findsNothing);
        }
        if (tab == 'Siparişler') expect(find.textContaining('4 ürün'), findsOneWidget);
      });
    }
  }

  test('category order follows Windows; unknown keys last', () {
    expect(menuCategoriesOf([
      {'category': 'drink'}, {'category': 'zzz'}, {'category': 'wrap'}, {'category': 'plate'},
    ]), ['wrap', 'plate', 'drink', 'zzz']);
    expect(menuCategoryLabel('zzz'), 'zzz');
  });
}
