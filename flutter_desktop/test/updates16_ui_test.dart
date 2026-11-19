import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'manager_audit_test.dart' as helpers;

void main() {
  testWidgets(
    'removed dashboard and shift/queue controls stay absent; report and settings tabs are usable',
    (t) async {
      await helpers.mountManager(t, helpers.seed());
      for (final label in [
        'Günlük Son Fiş',
        'Yazdırma Bekleyen',
        'Yazdırma Kuyruğu',
      ])
        expect(find.textContaining(label), findsNothing);
      await helpers.click(t, 'Kasa & Ödemeler');
      expect(find.text('Kasayı Aç'), findsNothing);
      expect(find.text('Kasayı Kapat'), findsNothing);
      await helpers.click(t, 'Raporlar');
      for (final tab in [
        'Satışlar',
        'Ürünler',
        'Mutabakat',
        'Hazırlık Süresi',
        'İptaller',
        'Yoğunluk',
        'Genel Bakış',
      ]) {
        final chip = find.widgetWithText(ChoiceChip, tab);
        await t.ensureVisible(chip);
        await t.tap(chip);
        await t.pumpAndSettle();
        if (tab == 'Yoğunluk') {
          expect(find.text('30 dakikalık sipariş yoğunluğu'), findsOneWidget);
          expect(
            find.text('Haftanın günü ve saate göre yoğunluk'),
            findsOneWidget,
          );
        }
        expect(t.takeException(), isNull);
      }
      await helpers.click(t, 'Ayarlar');
      for (final tab in [
        'Menü',
        'Yazıcı',
        'Entegrasyonlar',
        'Yedekleme',
        'Genel',
      ]) {
        await helpers.click(t, tab);
        expect(t.takeException(), isNull);
      }
      expect(find.text('inPOS'), findsNothing);
      expect(find.text('Yeni sipariş sesi'), findsOneWidget);
    },
  );
  testWidgets(
    'saved table opens a compact account dialog with edit and move actions; new orders do not print',
    (t) async {
      final s = helpers.seed();
      newLocalOrder(
        state: s,
        source: 'Masa',
        table: 1,
        productLines: [
          {
            'productId': 0,
            'name': 'Falafel',
            'price': 140,
            'qty': 1,
            'note': '',
            'removed': <String>[],
          },
        ],
      );
      final file = await helpers.mountManager(t, s);
      await helpers.click(t, 'Kasa & Ödemeler');
      await helpers.click(t, 'Kalan 140,00 ₺');
      expect(find.text('Hesap ve Sipariş'), findsOneWidget);
      expect(find.text('Ürünleri Düzenle'), findsOneWidget);
      expect(find.text('Masayı Taşı'), findsOneWidget);
      await helpers.click(t, 'Masayı Taşı');
      await t.tap(find.byType(DropdownButtonFormField<String>).last);
      await t.pumpAndSettle();
      await t.tap(find.text('4').last);
      await t.pumpAndSettle();
      await helpers.click(t, 'Kaydet');
      final db = PosStore(databaseFile: file);
      expect(mutableOrder(db.read().data, 1200)!['table'], 4);
      expect(db.read().data['settings']['receiptPolicy'], 'onPayment');
      db.dispose();
      expect(t.takeException(), isNull);
    },
  );
}
