import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/brand.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/receipt_layout.dart';
import 'package:nohut_falafel_desktop/receipt_printer.dart';
import 'package:nohut_falafel_desktop/trendyol_go_readonly.dart';

Json package({
  String number = '101',
  String status = 'Picking',
}) => normalizeTgoPackage({
  'id': 'pkg-$number',
  'orderNumber': number,
  'orderCode': '4D5AC',
  'packageStatus': status,
  'packageCreationDate': 1763503200000,
  'storePickupSelected': false,
  'isCourierNearby': true,
  'estimatedPickupTimeMin': 1700000000000,
  'customerNote': 'Soğansız',
  'lines': [
    {
      'name': 'Falafel Menü',
      'items': [
        {'isCancelled': false},
        {'isCancelled': false},
      ],
      'removedIngredients': [
        {'name': 'Domates'},
      ],
      'extraIngredients': ['Acı sos'],
      'modifierProducts': [
        {'name': 'Humus'},
        {
          'name': 'Patates (Büyük)',
          'removedIngredients': ['Ketçap'],
          'modifierProducts': [
            {'name': 'Baharatlı'},
          ],
        },
      ],
    },
  ],
});

void main() {
  late Directory dir;
  late PosStore store;
  late ReceiptPrinter printer;
  late List<(String, String)> sent;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nohut-tgo');
    store = PosStore(databaseFile: '${dir.path}/db');
    sent = [];
    printer = ReceiptPrinter(store, transport: (text, name) async {
      sent.add((text, name));
    });
  });
  tearDown(() {
    printer.dispose();
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<void> run(Map<String, dynamic> settings, List<Json> orders) async {
    final state = emptyPosState();
    state['settings'] = settings;
    state['trendyolGoOrders'] = orders;
    expect(store.replace(state, store.read().revision).ok, true);
    for (var attempt = 0; attempt < 5; attempt++) {
      await printer.pump();
    }
  }

  test('normalizes removed and extra ingredients and nested choices', () {
    final line = package()['lines'][0] as Map;
    expect(line['qty'], 2);
    expect(line['removed'], ['Domates']);
    expect(line['extras'], ['Acı sos']);
    expect(line['options'], [
      'Humus',
      'Patates (Büyük) (Baharatlı) · Çıkar: Ketçap',
    ]);
  });

  test('ticket uses the Masa layout plus platform name and number', () {
    final text = tgoKitchenTicket({...package(), 'dailyNumber': 17});
    final lines = text.split('\n');
    expect(lines[0], 'NOHUT FALAFEL · SİPARİŞ FİŞİ');
    expect(lines[1], 'MALİ FİŞ DEĞİLDİR');
    expect(lines[2], '#0017 · Trendyol Go · Paket Servis');
    expect(lines[3], 'Platform no: 101 · Kod: 4D5AC');
    expect(text, contains('2 × Falafel Menü'));
    expect(text, contains('  + Humus'));
    expect(text, contains('+ Patates (Büyük) (Baharatlı) · Çıkar: Ketçap'));
    expect(text, contains('Çıkar: Domates'));
    expect(text, contains('Ekstra: Acı sos'));
    expect(text, contains('Not: Soğansız'));
  });

  test('prints once on the main printer and skips cancelled and test orders',
      () async {
    await run({
      'printerName': 'XP-237B',
      'kitchenPrinterName': 'Eski mutfak',
      'autoPrint': true,
    }, [
      {...package(), 'kitchenPrintState': 'Bekliyor'},
      {...package(number: '102', status: 'Cancelled'),
        'kitchenPrintState': 'Bekliyor'},
      {...package(number: '103'), 'testPackage': true,
        'kitchenPrintState': 'Bekliyor'},
    ]);
    expect(sent, hasLength(1));
    expect(sent.single.$2, 'XP-237B');
    expect(sent.single.$1, allOf(contains('101'), contains('Trendyol Go')));
    expect(
      tgoOrders(store.read().data).map((order) => order['kitchenPrintState']),
      ['Kuyruğa gönderildi', 'Atlandı', 'Atlandı'],
    );
  });

  test('follows the Masa auto-print switch and payment-only policy', () async {
    await run({'printerName': 'XP-237B', 'autoPrint': false},
        [{...package(), 'kitchenPrintState': 'Bekliyor'}]);
    expect(sent, isEmpty);
    await run({'printerName': 'XP-237B', 'receiptPolicy': 'onPayment'},
        [{...package(), 'kitchenPrintState': 'Bekliyor'}]);
    expect(sent, isEmpty);
    expect(tgoOrders(store.read().data).single['kitchenPrintState'],
        'Bekliyor');
  });

  test('does not print tickets queued before auto-print was enabled',
      () async {
    await run({
      'printerName': 'XP-237B',
      'autoPrint': true,
      'autoPrintEnabledAt': '2026-11-26T12:00:00.000Z',
    }, [
      {...package(), 'kitchenPrintState': 'Bekliyor',
        'kitchenQueuedAt': '2026-11-26T11:00:00.000Z'},
      {...package(number: '104'), 'kitchenPrintState': 'Bekliyor',
        'kitchenQueuedAt': '2026-11-26T12:30:00.000Z'},
    ]);
    expect(sent, hasLength(1));
    expect(sent.single.$1, contains('104'));
  });

  test('kitchen timing is always on acceptance', () {
    expect(tgoKitchenTiming(null), 'accepted');
    expect(tgoKitchenTiming({'tgoKitchenTiming': 'arrival'}), 'accepted');
  });

  test('a write during printing cannot leave the outcome unrecorded (QA-13)', () {
    final dir = Directory.systemTemp.createTempSync('nohut-qa13');
    final store = PosStore(databaseFile: '${dir.path}/db');
    addTearDown(() { store.dispose(); dir.deleteSync(recursive: true); });
    final printer = ReceiptPrinter(store, transport: (_, _) async {});
    var calls = 0;
    final ok = printer.commitAfterPrint((next) {
      calls++;
      if (calls == 1) {
        // A phone order lands between the read and the write.
        final s = store.read();
        store.replace({...s.data, 'settings': {...(s.data['settings'] as Map? ?? {}), 'printerName': 'XP-237B'}}, s.revision);
      }
      ((next['settings'] ??= <String, dynamic>{}) as Map)['autoPrint'] = true;
    });
    expect(ok, true);
    expect(calls, 2);
    final data = store.read().data;
    expect((data['settings'] as Map)['autoPrint'], true);
    expect((data['settings'] as Map)['printerName'], 'XP-237B', reason: 'the concurrent write is preserved');
  });

  test('courier type always when known; contact only for restaurant delivery, never masked', () {
    Json order(Map<String, dynamic> extra) => normalizeTgoPackage({
      ...{'id': 'pkg-9', 'orderNumber': '9', 'packageStatus': 'Picking', 'packageCreationDate': 1763503200000,
        'customer': {'firstName': 'Test', 'lastName': 'Müşteri'}, 'lines': const []},
      ...extra,
    });
    const long = 'Atatürk Mahallesi Cumhuriyet Caddesi No: 128 Daire: 14 Kat: 5';
    final address = {'phone': '05550000000', 'address1': long, 'district': 'Kadıköy', 'city': 'İstanbul'};
    final store = tgoKitchenTicket(order({'deliveryType': 'STORE', 'address': address}));
    expect(store, contains('Kurye: Restoran Kuryesi'));
    expect(store, contains('Tel: 05550000000'));
    expect(store, contains('Adres: $long · Kadıköy · İstanbul'));
    final go = tgoKitchenTicket(order({'deliveryType': 'GO', 'address': address}));
    expect(go, contains('Kurye: Trendyol GO Kuryesi'));
    expect(go, isNot(contains('Tel:')));
    expect(go, isNot(contains('Adres:')));
    final pickup = tgoKitchenTicket(order({'deliveryType': 'STORE', 'storePickupSelected': true, 'address': address}));
    expect(pickup, contains('· Gel-Al'));
    expect(pickup, isNot(contains('Kurye:')));
    expect(pickup, isNot(contains('Tel:')));
    final masked = tgoKitchenTicket(order({'deliveryType': 'STORE',
      'address': {'phone': '0555***0000', 'address1': 'Atatürk Mah. ****'}}));
    expect(masked, contains('Kurye: Restoran Kuryesi'));
    expect(masked, isNot(contains('Tel:')));
    expect(masked, isNot(contains('Adres:')));
    final missing = tgoKitchenTicket(order({}));
    expect(missing, isNot(contains('Kurye:')), reason: 'unknown courier type is not invented');
    expect(missing, isNot(contains('Tel:')));
    expect(missing, isNot(contains('@')));
  });

  testWidgets('long Turkish address wraps inside the 56 mm receipt', (t) async {
    String ticket(String street) => tgoKitchenTicket({'dailyNumber': 17, ...normalizeTgoPackage({'id': 'p', 'orderNumber': '1',
      'packageStatus': 'Picking', 'deliveryType': 'STORE', 'customer': {'firstName': 'Test', 'lastName': 'Müşteri'},
      'lines': [{'name': 'Falafel Dürüm', 'items': [{'isCancelled': false}]}],
      'address': {'phone': '05550000000', 'address1': street, 'district': 'Şişli', 'city': 'İstanbul'}})});
    final settings = {'paperWidthMm': 58, 'printableWidthMm': 48};
    await t.runAsync(() async {
      final body = FontLoader(NohutBrand.bodyFont)
        ..addFont(rootBundle.load('assets/brand/fonts/Barlow-Regular.ttf'))
        ..addFont(rootBundle.load('assets/brand/fonts/Barlow-Bold.ttf'));
      final heading = FontLoader(NohutBrand.headingFont)
        ..addFont(rootBundle.load('assets/brand/fonts/BreeSerif-Regular.ttf'));
      await Future.wait([body.load(), heading.load()]);
    });
    final short = await t.runAsync(() => renderReceipt(ticket('Çiğdem Sk. 12'), settings: settings));
    final long = await t.runAsync(() => renderReceipt(ticket(
        'Çiğdem Sokak Güneşli Apartmanı No: 12/4 İç Kapı Zil Üçüncü Kat Sağdaki Daire Bahçe Girişi'), settings: settings));
    expect(long!.width, short!.width, reason: 'same printable width; nothing is cut or scaled');
    expect(long.height, greaterThan(short.height), reason: 'the long address wraps onto more lines');
    final out = Platform.environment['NOHUT_RENDER_DIR'];
    if (out != null) File('$out/tgo-store-delivery-receipt.png')..createSync(recursive: true)..writeAsBytesSync(long.png);
  });
}
