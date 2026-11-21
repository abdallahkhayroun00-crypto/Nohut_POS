import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/market_prices.dart';
import 'manager_audit_test.dart' as helpers;

void main() {
  testWidgets('premium price watch UI excludes purchasing and expenses',
      (tester) async {
    await helpers.mountManager(tester, helpers.seed());
    await helpers.click(tester, 'Market Fiyat Takibi');
    expect(find.textContaining('MARKET RADARI'), findsOneWidget);
    expect(find.text('Fiyat Uyarıları'), findsOneWidget);
    expect(find.text('Dışa Aktar'), findsOneWidget);
    expect(find.text('İçe Aktar'), findsOneWidget);
    expect(find.textContaining('Sebze ('), findsOneWidget);
    expect(find.textContaining('Baharat ('), findsOneWidget);
    expect(find.text('A101 Bağlar'), findsWidgets);
    expect(find.text('BİM İstiklal'), findsOneWidget);
    expect(find.text('Hakmar Karadere'), findsOneWidget);
    expect(find.text('Hakmar Mavi Durak'), findsOneWidget);
    expect(find.textContaining('Kemalpaşa Mah. Bağlar Cad. No:82'),
      findsOneWidget);
    expect(find.text('Enlem'), findsNothing);
    expect(find.text('Boylam'), findsNothing);
    await tester.ensureVisible(find.text('Kaynak Ayarları'));
    await tester.tap(find.text('Kaynak Ayarları'));
    await tester.pumpAndSettle();
    expect(find.text('Canlı fiyat kaynağı (deneysel)'), findsOneWidget);
    expect(find.byKey(const ValueKey('market-refresh-interval')),
      findsOneWidget);
    expect(find.text('12 Saat'), findsOneWidget);
    expect(find.text('Yeni Kategori'), findsOneWidget);
    expect(find.text('Ürün Ara'), findsOneWidget);
    expect(find.text('Takibe Ekle'), findsNothing);
    for (final unwanted in [
      'Alım Geçmişi', 'Gider Analizi', 'Alışveriş Listesi',
    ]) {
      expect(find.text(unwanted), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('manager creates a new price-watch category in the filter',
      (tester) async {
    await helpers.mountManager(tester, helpers.seed());
    await helpers.click(tester, 'Market Fiyat Takibi');
    final add = find.text('Yeni Kategori');
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.text('Yeni Kategori Oluştur'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Soslar');
    await tester.tap(find.text('Kategori Ekle'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Soslar (0)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('branded cards display prior and current price and filter alerts',
      (tester) async {
    final seed = helpers.seed();
    const first = MarketQuote(
      productId: 'marul', title: 'Göbek Marul',
      market: 'Hakmar', depotId: 'hakmar-01',
      depotName: 'Hakmar Serdivan', unit: 'Adet',
      priceCents: 5500, observedAt: '2026-11-20T08:00:00Z',
    );
    const lower = MarketQuote(
      productId: 'marul', title: 'Göbek Marul',
      market: 'Hakmar', depotId: 'hakmar-01',
      depotName: 'Hakmar Serdivan', unit: 'Adet',
      priceCents: 4200, observedAt: '2026-11-21T08:00:00Z',
    );
    addTrackedMarketQuote(seed, first);
    applyMarketQuote(seed, lower);
    await helpers.mountManager(tester, seed);
    await helpers.click(tester, 'Market Fiyat Takibi');
    expect(find.text('Göbek Marul'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('market-unread-alerts')), findsOneWidget);
    expect(find.text('Okunmamış Fiyat Uyarıları (1)'), findsOneWidget);
    await tester.tap(find.text('Okundu'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('market-unread-alerts')), findsNothing);
    expect(find.text('Göbek Marul'), findsOneWidget);
    // Changed vegetables appear in the priority group, not as Sebze heading.
    expect(find.textContaining('Sebze (1)'), findsOneWidget);
    expect(find.text('Son Fiyat Değişiklikleri'), findsOneWidget);
    expect(find.text('Hakmar'), findsOneWidget);
    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
    expect(find.text('Önce 55,00 TL'), findsOneWidget);
    expect(find.text('42,00 TL'), findsOneWidget);
    expect(find.text('-23,6%'), findsOneWidget);
    expect(find.text('Hakmar Serdivan'), findsOneWidget);
    expect(find.byIcon(Icons.trending_down), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Zam Geldi  (0)'));
    await tester.pumpAndSettle();
    expect(find.text('Göbek Marul'), findsNothing);
    expect(find.text('Bu filtrede fiyat değişimi yok'), findsOneWidget);
    expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
