// Runs on the CI Android emulator: real Flutter screens of the Personel app
// with clearly synthetic data (no restaurant data, no server). Screenshots
// are evidence of rendering on Android, not of a physical device.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nohut_personel/home.dart';
import 'package:nohut_personel/pos_api.dart';
import 'package:nohut_personel/style.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Personel screens with synthetic data', (tester) async {
    final c = PersonelController(NohutApi(), StaffNotifications());
    c.state = {
      'employees': [
        {'id': 1, 'name': 'Test Personel A', 'active': true},
        {'id': 2, 'name': 'Test Personel B', 'active': true},
      ],
      'localMenu': [
        {'id': 1, 'name': 'Test Falafel Dürüm', 'price': 140, 'category': 'wrap'},
        {'id': 2, 'name': 'Test Humus Tabağı', 'price': 165, 'category': 'plate'},
        {'id': 3, 'name': 'Test Ayran', 'price': 35, 'category': 'drink'},
      ],
      'orders': <dynamic>[],
    };
    c.online = true;
    await tester.pumpWidget(MaterialApp(
      theme: NohutStyle.theme,
      home: StaffHome(controller: c, onUnpair: () {}),
    ));
    await tester.pumpAndSettle();
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();
    await binding.takeScreenshot('personel-masalar');
    for (final (tab, name) in [('Ürünler', 'urunler'), ('Sepet', 'sepet'), ('Siparişler', 'siparisler')]) {
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
      await binding.takeScreenshot('personel-$name');
    }
  });
}
