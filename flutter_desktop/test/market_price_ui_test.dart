import 'package:flutter_test/flutter_test.dart';
import 'manager_audit_test.dart' as helpers;

void main() {
  testWidgets('manager price watch is separate from shopping and expenses',
      (tester) async {
    await helpers.mountManager(tester, helpers.seed());
    await helpers.click(tester, 'Market Fiyat Takibi');
    expect(find.textContaining('Fiyat Uyarıları'), findsOneWidget);
    expect(find.text('Canlı fiyat kaynağı (deneysel)'), findsOneWidget);
    expect(find.text('Ürün Ara'), findsOneWidget);
    expect(find.text('Takibe Ekle'), findsNothing); // no real search results yet
    for (final unwanted in [
      'Alım Geçmişi', 'Gider Analizi', 'Alışveriş Listesi',
    ]) {
      expect(find.text(unwanted), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });
}
