import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_core/nohut_core.dart';
import 'package:nohut_personel/expense_drafts.dart';
import 'package:nohut_personel/home.dart';
import 'package:nohut_personel/pos_api.dart';
import 'package:nohut_personel/style.dart';

class MemoryDraftStore extends ExpenseDraftStore {
  MemoryDraftStore() : super('test-restaurant');
  List<Map<String, dynamic>> values = [];
  @override
  Future<List<Map<String, dynamic>>> read() async => List.of(values);
  @override
  Future<void> write(List<Map<String, dynamic>> entries) async {
    values = List.of(entries);
  }
}

void main() {
  test('common Android/Windows quick expense arithmetic is exact', () {
    expect(parseExpenseCents('50,25'), 5025);
    expect(parseExpenseCents('300'), 30000);
    expect(quickMaterialTotalCents(['50', '60', '300']
      .map(parseExpenseCents).toList()), 41000);
    expect(() => parseExpenseCents('1.234,50'), throwsFormatException);
    expect(() => parseExpenseCents('-1'), throwsFormatException);
    expect(() => quickMaterialTotalCents([]), throwsFormatException);
  });

  for (final size in [
    const Size(320, 568), const Size(360, 640),
    const Size(412, 915), const Size(600, 960),
    const Size(800, 1280), const Size(1280, 800),
    const Size(800, 360), const Size(1200, 600),
  ]) {
    testWidgets('phone/tablet layout ' + size.toString(), (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final controller = PersonelController(NohutApi(), StaffNotifications());
      controller.state = {
        'employees': [{'id': 1, 'name': 'Personel', 'active': true}],
        'localMenu': [
          {'id': 1, 'name': 'Falafel Dürüm', 'price': 140},
          {'id': 2, 'name': 'Nohut Özel Tabağı', 'price': 290},
        ],
        'orders': <dynamic>[],
      };
      controller.online = true;
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: NohutStyle.theme,
        home: StaffHome(controller: controller, onUnpair: () {}),
      ));
      expect(find.text('Masa 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.restaurant_menu).first);
      await tester.pumpAndSettle();
      expect(find.text('Falafel Dürüm'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.shopping_cart_outlined).first);
      await tester.pumpAndSettle();
      expect(find.text('Sipariş Sepeti'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('expense draft survives screen reopen and remains local',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final store = MemoryDraftStore();
      Widget page() => MaterialApp(
        theme: NohutStyle.theme,
        home: Scaffold(body: ExpenseDraftPage(store: store)));
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('android-quick-draft-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Tutar 1 (₺)'), '410');
      await tester.ensureVisible(find.text('Cihaza Kaydet'));
      await tester.tap(find.text('Cihaza Kaydet'));
      await tester.pumpAndSettle();
      expect(store.values.single['totalCents'], 41000);
      expect(store.values.single['status'], 'local_draft');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.textContaining('410,00 ₺'), findsOneWidget);
      expect(find.textContaining('Gönderilmedi'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
}
