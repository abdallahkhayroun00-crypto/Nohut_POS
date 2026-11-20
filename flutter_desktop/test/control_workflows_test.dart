import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/brand.dart';
import 'package:nohut_falafel_desktop/order_reporting.dart';
import 'package:nohut_falafel_desktop/operations_ui.dart';
import 'package:nohut_falafel_desktop/operations.dart';
import 'package:nohut_falafel_desktop/platform_ui.dart';
import 'package:nohut_falafel_desktop/platform_workflows.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/payment_dialog.dart';
import 'package:nohut_falafel_desktop/qr_menu_sync.dart';

import 'qr_catalog_fixtures.dart';

Json fixture() {
  final s = emptyPosState();
  s['localMenu'] = [
    {'id': 0, 'name': 'Falafel', 'price': 140, 'category': 'wrap'},
    {'id': 1, 'name': 'Ayran', 'price': 45, 'category': 'drink'},
  ];
  seedPlatformMenu(s, asMaps(s['localMenu']));
  return s;
}

Json line() => {
  'productId': 0,
  'name': 'Falafel',
  'price': 140,
  'qty': 1,
  'note': '',
  'removed': <String>[],
};
typedef Panel = Widget Function(Json, EditState);

class Harness extends StatefulWidget {
  const Harness({super.key, required this.initial, required this.panel});
  final Json initial;
  final Panel panel;
  @override
  State<Harness> createState() => HarnessState();
}

class HarnessState extends State<Harness> {
  late Json data = copyJson(widget.initial);
  bool edit(void Function(Json) change) {
    try {
      final next = copyJson(data);
      change(next);
      PosStore.validate(next);
      setState(() => data = next);
      return true;
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      return false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.panel(data, edit);
}

Future<GlobalKey<HarnessState>> mount(
  WidgetTester tester,
  Json s,
  Panel panel,
) async {
  tester.view.physicalSize = const Size(1600, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final key = GlobalKey<HarnessState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: NohutBrand.theme(),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Harness(key: key, initial: s, panel: panel),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return key;
}

Future<void> tap(WidgetTester t, String label) async {
  final f = find.text(label).last;
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

Future<void> enter(WidgetTester t, String label, String value) async {
  await t.enterText(
    find
        .byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == label,
        )
        .last,
    value,
  );
}

Future<void> choice(WidgetTester t, String value) async {
  await t.tap(find.byType(DropdownButtonFormField<String>).last);
  await t.pumpAndSettle();
  await t.tap(find.text(value).last);
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'cash payment change, invalid input, card method and cancel keep correct intent',
    (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: NohutBrand.theme(),
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: ctx,
                  builder: (_) => const PaymentEntryDialog(
                    dueCents: 14000,
                    orderNumber: '0001',
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tap(t, 'Open');
      await enter(t, 'Tutar (₺)', '50,5');
      await enter(t, 'Alınan nakit (₺)', '100');
      await t.pump();
      expect(find.text('Para üstü: 49,50 ₺'), findsOneWidget);
      await enter(t, 'Tutar (₺)', '999');
      await tap(t, 'Ödemeyi Gözden Geçir');
      expect(find.byKey(const ValueKey('payment-error')), findsOneWidget);
      await enter(t, 'Tutar (₺)', '50');
      await enter(t, 'Alınan nakit (₺)', '1');
      await tap(t, 'Ödemeyi Gözden Geçir');
      expect(find.text('Alınan nakit tutarı yetersiz.'), findsOneWidget);
      await choice(t, 'Kart');
      expect(find.byKey(const ValueKey('payment-received')), findsNothing);
      await tap(t, 'Vazgeç');
      expect(find.byType(PaymentEntryDialog), findsNothing);
    },
  );
  testWidgets(
    'staff add, edit role, deactivate and duplicate validation preserve identity',
    (t) async {
      final key = await mount(
        t,
        fixture(),
        (s, edit) => StaffPanel(state: s, edit: edit),
      );
      await tap(t, 'Personel Ekle');
      await enter(t, 'Ad', 'Fatma');
      await choice(t, 'Yönetici');
      await tap(t, 'Kaydet');
      expect(
        asMaps(key.currentState!.data['employees']).last['role'],
        'Yönetici',
      );
      await tap(t, 'Fatma');
      await enter(t, 'Ad', 'Fatma Yeni');
      await choice(t, 'Personel');
      await tap(t, 'Kaydet');
      final id = asMaps(key.currentState!.data['employees']).last['id'];
      await t.ensureVisible(find.byType(Switch).last);
      await t.tap(find.byType(Switch).last);
      await t.pumpAndSettle();
      expect(
        asMaps(key.currentState!.data['employees']).last,
        containsPair('id', id),
      );
      expect(asMaps(key.currentState!.data['employees']).last['active'], false);
      await tap(t, 'Personel Ekle');
      await enter(t, 'Ad', 'Fatma Yeni');
      await tap(t, 'Kaydet');
      expect(asMaps(key.currentState!.data['employees']), hasLength(4));
      expect(find.textContaining('Bu ad zaten var'), findsOneWidget);
    },
  );
  testWidgets(
    'guest shares, equal assignment, refund preview, product cancellation and bill preview',
    (t) async {
      final s = fixture();
      final o = newLocalOrder(
        state: s,
        source: 'Masa',
        table: 1,
        productLines: [line()],
      );
      final key = await mount(
        t,
        s,
        (s, edit) =>
            OrderOperations(order: asMaps(s['orders']).single, edit: edit),
      );
      await tap(t, 'Hesap Özeti Önizle');
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              (w.properties.label ?? '').contains('Toplam 140,00 ₺'),
        ),
        findsOneWidget,
      );
      await tap(t, 'Kapat');
      await tap(t, 'Kişi Ekle');
      await enter(t, 'Ad', 'Ali');
      await tap(t, 'Kaydet');
      await t.ensureVisible(find.text('Ürünü Kişiye Ata ▾'));
      await t.tap(find.text('Ürünü Kişiye Ata ▾'));
      await t.pumpAndSettle();
      await tap(t, 'Ali · 140,00 ₺');
      await tap(t, 'Kaydet');
      expect(
        allocatedTo(asMaps(key.currentState!.data['orders']).single, '1:0'),
        14000,
      );
      await tap(t, 'Ali Düzenle');
      await enter(t, 'Ad', 'Ayşe');
      await tap(t, 'Kaydet');
      await tap(t, 'Kişi Paylarını Sıfırla');
      await tap(t, 'Vazgeç');
      expect(
        asMaps(key.currentState!.data['orders']).single['guestChecks'],
        isNotEmpty,
      );
      await tap(t, 'Kişi Paylarını Sıfırla');
      await tap(t, 'Onayla');
      expect(
        asMaps(key.currentState!.data['orders']).single['guestChecks'],
        isEmpty,
      );
      key.currentState!.edit(
        (s) => recordPayment(mutableOrder(s, o['id'] as int)!, 14000, 'Kart'),
      );
      await t.pumpAndSettle();
      await tap(t, 'Kısmi / Tam İade');
      await enter(t, 'Neden', 'Yanlış sipariş');
      await tap(t, 'Kaydet');
      expect(find.text('İade Yapıldı · Kaydet'), findsOneWidget);
      await tap(t, 'Vazgeç');
      expect(
        orderPaidCents(asMaps(key.currentState!.data['orders']).single),
        14000,
      );
      await tap(t, 'Kısmi / Tam İade');
      await enter(t, 'Neden', 'Yanlış sipariş');
      await tap(t, 'Kaydet');
      await tap(t, 'İade Yapıldı · Kaydet');
      expect(
        orderPaidCents(asMaps(key.currentState!.data['orders']).single),
        0,
      );
      await tap(t, 'Adet İptal');
      await enter(t, 'Neden', 'Stok yok');
      await tap(t, 'Kaydet');
      expect(
        orderTotalCents(asMaps(key.currentState!.data['orders']).single),
        0,
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'print preview and manual requeue require confirmation and respect busy state',
    (t) async {
      final s = fixture();
      newLocalOrder(state: s, source: 'Masa', table: 1, productLines: [line()]);
      (s['printJobs'] as List).first['state'] = 'Kuyruğa gönderildi';
      final key = await mount(
        t,
        s,
        (s, edit) => PrinterPanel(state: s, edit: edit),
      );
      await tap(t, 'Önizle');
      expect(find.text('Mutfak Önizleme'), findsOneWidget);
      await tap(t, 'Kapat');
      await tap(t, 'Kontrol Ettim · Yeniden Kuyruğa Al');
      await tap(t, 'Vazgeç');
      expect(
        asMaps(key.currentState!.data['printJobs']).single['state'],
        'Kuyruğa gönderildi',
      );
      await tap(t, 'Kontrol Ettim · Yeniden Kuyruğa Al');
      await tap(t, 'Kontrol Ettim · Yeniden Yazdır');
      expect(
        asMaps(key.currentState!.data['printJobs']).single['state'],
        'Bekliyor',
      );
    },
  );
  testWidgets(
    'report date presets, source filters and all four exports write requested CSV files',
    (t) async {
      final dir = Directory.systemTemp.createTempSync('nohut-export-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final s = fixture();
      final o = newLocalOrder(
        state: s,
        source: 'Masa',
        table: 1,
        productLines: [line()],
      );
      recordPayment(o, 14000, 'Nakit', receivedCents: 20000);
      await mount(t, s, (s, edit) => ReportsPanel(state: s, edit: edit));
      for (final label in ['Bugün', 'Son 7 Gün', 'Son 30 Gün'])
        await tap(t, label);
      await tap(t, 'Takvimden Seç');
      await t.tap(find.byTooltip('Close'));
      await t.pumpAndSettle();
      for (final e in [
        ('Tahsilat CSV', 'cash'),
        ('Ürün Satışları CSV', 'sales'),
        ('Mutabakat CSV', 'finance'),
        ('Yoğunluk CSV', 'hourly'),
      ]) {
        await tap(t, e.$1);
        await enter(t, 'Dosya yolu', '${dir.path}/${e.$2}.csv');
        await tap(t, 'Kaydet');
        expect(
          File('${dir.path}/${e.$2}.csv').readAsStringSync(),
          startsWith('\uFEFF'),
        );
        await t.pump(const Duration(seconds: 5));
        await t.pumpAndSettle();
      }
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'settings prevent sync-price conflicts, save printer cutoff and create readable SQLite backup',
    (t) async {
      final dir = Directory.systemTemp.createTempSync('nohut-settings-');
      final store = PosStore(databaseFile: '${dir.path}/source.sqlite3');
      final initial = fixture();
      initial['settings'] = {
        'autoPrint': false,
        'autoPrintEnabledAt': '2000-01-01T00:00:00Z',
      };
      store.replace(initial, 0);
      final sync = QrMenuAutoSync(store, reader: QrCatalogFixture.reader());
      addTearDown(() {
        sync.dispose();
        store.dispose();
        dir.deleteSync(recursive: true);
      });
      final key = await mount(
        t,
        initial,
        (s, edit) =>
            SettingsPanel(state: s, edit: edit, store: store, qrSync: sync),
      );
      await tap(t, 'Yerel Menü Fiyatları');
      expect(
        t
            .widget<OutlinedButton>(
              find.ancestor(
                of: find.text('Fiyat Düzenle').first,
                matching: find.byType(OutlinedButton),
              ),
            )
            .onPressed,
        isNull,
      );
      await t.tap(find.byType(Switch).first);
      await t.pumpAndSettle();
      await tap(t, 'Fiyat Düzenle');
      await enter(t, 'Fiyat ₺ (boş = satış dışı)', '47,50');
      await tap(t, 'Kaydet');
      expect(asMaps(key.currentState!.data['localMenu']).last['price'], 47.5);
      await tap(t, 'Yazıcı Ayarı');
      await enter(t, 'Windows termal yazıcısının tam adı', '');
      await tap(t, 'Kaydet');
      expect(find.text('Yazıcı adı gerekli'), findsOneWidget);
      await enter(t, 'Windows termal yazıcısının tam adı', 'XP-237B');
      await tap(t, 'Kaydet');
      expect(key.currentState!.data['settings']['autoPrint'], true);
      expect(
        key.currentState!.data['settings']['autoPrintEnabledAt'],
        isNot('2000-01-01T00:00:00Z'),
      );
      await tap(t, 'Tutarlı SQLite Yedeği Oluştur');
      await enter(t, 'Yeni yedek dosya yolu', '${dir.path}/backup.sqlite3');
      await tap(t, 'Kaydet');
      final backup = PosStore(databaseFile: '${dir.path}/backup.sqlite3');
      try {
        expect(backup.read().data, store.read().data);
      } finally {
        backup.dispose();
      }
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'all platform fixture types and all platform tabs retain sandbox-only state',
    (t) async {
      final key = await mount(
        t,
        fixture(),
        (s, edit) => PlatformPanel(state: s, edit: edit),
      );
      for (final label in [
        'Örnek Online Kart',
        'Örnek Teslimatta',
        'Örnek Yemek Kartı',
        'Örnek Platform Gel-Al',
      ])
        await tap(t, label);
      expect(asMaps(key.currentState!.data['orders']), hasLength(4));
      for (final tab in [
        'Mağaza',
        'Menü',
        'İade Talepleri',
        'Değerlendirmeler',
        'Faturalar',
        'Senkronizasyon',
        'Finans',
        'Siparişler',
      ]) {
        await tap(t, tab);
        expect(t.takeException(), isNull, reason: tab);
      }
      await tap(t, 'Mağaza');
      await tap(t, 'Kabul Akışı (Yerel Senaryo)');
      await choice(t, 'Platform uygulamasında onay');
      await tap(t, 'Kaydet');
      expect(
        storeConfig(key.currentState!.data, 'Trendyol Go')['acceptFlow'],
        'indirect',
      );
      await tap(t, 'Kabul Akışı (Yerel Senaryo)');
      await choice(t, 'Restoranda onay');
      await tap(t, 'Kaydet');
      await tap(t, 'Mağazayı Kapat İste');
      await tap(t, 'Senkronizasyon');
      await tap(t, 'Test: Başarılı Sonuç');
      expect(storeConfig(key.currentState!.data, 'Trendyol Go')['open'], false);
      await tap(t, 'Mağaza');
      await tap(t, 'Mağazayı Aç İste');
      await tap(t, 'Senkronizasyon');
      await tap(t, 'Test: Başarılı Sonuç');
      expect(storeConfig(key.currentState!.data, 'Trendyol Go')['open'], true);
      await tap(t, 'Değerlendirmeler');
      await tap(t, 'Örnek Yorum Al');
      await tap(t, 'Yanıtı Onaya Gönder');
      await enter(t, 'Restoran yanıtı', 'Teşekkür ederiz');
      await tap(t, 'Kaydet');
      await tap(t, 'Senkronizasyon');
      await tap(t, 'Test: Başarılı Sonuç');
      await tap(t, 'Değerlendirmeler');
      await tap(t, 'Test: APPROVED');
      expect(
        asMaps(platformHub(key.currentState!.data)['reviews'])
            .single['replyStatus'],
        'APPROVED',
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'platform menu availability, bulk price, hours, invoice, claim and finance controls resolve in sandbox',
    (t) async {
      final s = fixture();
      final o = importPlatform(s, platformFixture(s, 'Trendyol Go', 'card'))!;
      externalPlatformEvent(s, o['id'] as int, 'Delivered');
      sampleClaim(s, o['id'] as int, 'PAY_BACK');
      final key = await mount(
        t,
        s,
        (s, edit) => PlatformPanel(state: s, edit: edit),
      );
      await tap(t, 'Menü');
      await tap(t, 'Ürün Aç/Kapat İste');
      await tap(t, 'Senkronizasyon');
      await tap(t, 'Test: 429 Hata');
      expect(
        asMaps(platformHub(key.currentState!.data)['jobs']).first['status'],
        'Hata',
      );
      key.currentState!.edit(
        (s) => findRecord(
          s,
          'jobs',
          asMaps(platformHub(s)['jobs']).first['id'],
        )['retryAfter'] = 0,
      );
      await t.pumpAndSettle();
      await tap(t, 'Yeniden Dene');
      await tap(t, 'Test: Başarılı Sonuç');
      await tap(t, 'Menü');
      await t.ensureVisible(find.byType(CheckboxListTile).first);
      await t.tap(find.byType(CheckboxListTile).first);
      await t.pumpAndSettle();
      await tap(t, 'Seçili Fiyatları Gönder');
      await enter(t, 'Yeni fiyat ₺', '150');
      await tap(t, 'Kaydet');
      await tap(t, 'Senkronizasyon');
      await tap(t, 'Test: Başarılı Sonuç');
      expect(
        asMaps(platformHub(key.currentState!.data)['menu']['Trendyol Go'])
            .first['price'],
        150,
      );
      await tap(t, 'Mağaza');
      await tap(t, 'Saat İsteği');
      await enter(t, 'Başlangıç HH:mm', '12:00');
      await enter(t, 'Bitiş HH:mm', '21:00');
      await tap(t, 'Kaydet');
      await tap(t, 'Senkronizasyon');
      await tap(t, 'Test: Başarılı Sonuç');
      expect(
        asMaps(storeConfig(key.currentState!.data, 'Trendyol Go')['hours'])
            .last['start'],
        '12:00',
      );
      await tap(t, 'Faturalar');
      await tap(t, '#${displayOrderNumber(o)} Fatura Bağlantısı İste');
      await enter(t, 'HTTPS bağlantısı', 'https://example.test/invoice.pdf');
      await tap(t, 'Kaydet');
      await tap(t, 'Senkronizasyon');
      await tap(t, 'Test: Başarılı Sonuç');
      await tap(t, 'Faturalar');
      expect(find.text('https://example.test/invoice.pdf'), findsOneWidget);
      await tap(t, 'Silme İsteği');
      await tap(t, 'Senkronizasyon');
      await tap(t, 'Test: Başarılı Sonuç');
      expect(
        asMaps(platformHub(key.currentState!.data)['invoices'])
            .single['status'],
        'Silindi (demo)',
      );
      await tap(t, 'İade Talepleri');
      for (final f in find.byType(CheckboxListTile).evaluate().toList()) {
        await t.ensureVisible(find.byWidget(f.widget));
        await t.tap(find.byWidget(f.widget));
        await t.pumpAndSettle();
      }
      await tap(t, 'Seçili Kabul İste');
      await enter(t, 'Açıklama (itiraz 5000 · Diğer)', 'Örnek kabul');
      await tap(t, 'Kaydet');
      await tap(t, 'Senkronizasyon');
      await tap(t, 'Test: Başarılı Sonuç');
      expect(
        asMaps(platformHub(key.currentState!.data)['claims']).single['status'],
        'Accepted',
      );
      await tap(t, 'Finans');
      await tap(t, '#${displayOrderNumber(o)} Örnek Finans Kaydı Al');
      await tap(t, 'Örnek Ödeme Emri Eşleştir');
      expect(
        asMaps(platformHub(key.currentState!.data)['settlements'])
            .single['paymentStatus'],
        'Eşleşti (demo)',
      );
      expect(
        asMaps(key.currentState!.data['orders']).single['payments'],
        o['payments'],
      );
      expect(t.takeException(), isNull);
    },
  );
}
