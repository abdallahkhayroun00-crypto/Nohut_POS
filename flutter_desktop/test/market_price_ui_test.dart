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
    expect(find.text('A101 · Nohut yakını'), findsWidgets);
    expect(find.text('BİM · Nohut yakını'), findsOneWidget);
    expect(find.text('Hakmar 1'), findsOneWidget);
    expect(find.text('Hakmar 2'), findsOneWidget);
    expect(find.text('Enlem'), findsNothing);
    expect(find.text('Boylam'), findsNothing);
    await tester.ensureVisible(find.text('Kaynak Ayarları'));
    await tester.tap(find.text('Kaynak Ayarları'));
    await tester.pumpAndSettle();
    expect(find.text('Canlı fiyat kaynağı (deneysel)'), findsOneWidget);
    expect(find.text('Ürün Ara'), findsOneWidget);
    expect(find.text('Takibe Ekle'), findsNothing);
    for (final unwanted in [
      'Alım Geçmişi', 'Gider Analizi', 'Alışveriş Listesi',
    ]) {
      expect(find.text(unwanted), findsNothing);
    }
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
    expect(find.text('Göbek Marul'), findsOneWidget);
    expect(find.text('55,00 TL'), findsOneWidget);
    expect(find.text('42,00 TL'), findsOneWidget);
    expect(find.text('-23,6%'), findsOneWidget);
    expect(find.text('Hakmar Serdivan'), findsOneWidget);
    expect(find.byIcon(Icons.trending_down), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Zam Geldi  (0)'));
    await tester.pumpAndSettle();
    expect(find.text('Göbek Marul'), findsNothing);
    expect(find.text('Bu filtrede fiyat değişimi yok'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
