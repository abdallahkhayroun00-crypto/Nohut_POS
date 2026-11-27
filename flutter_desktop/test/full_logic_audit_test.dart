import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/operations.dart';
import 'package:nohut_falafel_desktop/operations_ui.dart';
import 'package:nohut_falafel_desktop/order_reporting.dart';
import 'package:nohut_falafel_desktop/receipt_printer.dart';
import 'package:nohut_falafel_desktop/staff_commands.dart';
import 'package:nohut_falafel_desktop/lan_server.dart';

Json row({int qty = 1}) => {
  'productId': 0,
  'name': 'Falafel',
  'price': 140,
  'qty': qty,
  'removed': <String>[],
  'note': 'Sos ayrı',
};
Json state() => {
  ...emptyPosState(),
  'localMenu': [
    {'id': 0, 'name': 'Falafel', 'category': 'wrap', 'price': 140},
  ],
  'settings': {'autoPrint': true, 'printerName': 'fake'},
};

void main() {
  test(
    'requeue rejects cancelled originals and platform jobs but allows correction notices',
    () {
      final s = state();
      final o = newLocalOrder(
        state: s,
        source: 'Masa',
        table: 1,
        productLines: [row()],
      );
      final original = asMaps(s['printJobs']).first;
      expect(canRequeueLocalKitchen(s, original), isTrue);
      cancelLocalOrder(s, o['id'] as int, 'Vazgeçti');
      expect(canRequeueLocalKitchen(s, asMaps(s['printJobs']).first), isFalse);
      expect(canRequeueLocalKitchen(s, asMaps(s['printJobs']).last), isTrue);
      o['source'] = 'Trendyol Go';
      expect(canRequeueLocalKitchen(s, asMaps(s['printJobs']).last), isFalse);
    },
  );

  test(
    'cash input conserves cents and rejects overflow, scientific, negative and malformed input',
    () {
      expect(parseMoney(' 1234,56 '), 123456);
      expect(parseMoney('0.01'), 1);
      expect(parseMoney('20,5'), 2050);
      for (final bad in ['-1', 'NaN', '1e4', '2.999', '1,2,3', '', '9' * 500]) {
        expect(() => parseMoney(bad), throwsFormatException, reason: bad);
      }
      expect(formatTry(123456), '1.234,56 ₺');
      expect(formatTry(-1), '-0,01 ₺');
    },
  );
  test(
    'date filters reject normalized impossible dates and reversed ranges',
    () {
      expect(validBusinessRange('2024-02-29', '2024-03-01'), isTrue);
      for (final bad in ['2026-02-29', '2026-02-31', '2026-13-01', '2026-1-01'])
        expect(validBusinessDate(bad), isFalse);
      expect(validBusinessRange('2026-11-15', '2026-11-14'), isFalse);
      expect(validBusinessRange('', ''), isTrue);
    },
  );
  test(
    'cashier refresh is required after price, availability or product identity changes',
    () {
      final s = state(), lines = [row()];
      validateCashierDraft(s, lines);
      ((s['localMenu'] as List).first as Map)['price'] = 150;
      expect(() => validateCashierDraft(s, lines), throwsFormatException);
      expect(
        lines.first['price'],
        140,
        reason: 'do not silently reprice a draft',
      );
      ((s['localMenu'] as List).first as Map)['price'] = 140;
      ((s['localMenu'] as List).first as Map)['active'] = false;
      expect(() => validateCashierDraft(s, lines), throwsFormatException);
      expect(
        () => validateProductLines([row(qty: 1001)]),
        throwsFormatException,
      );
      expect(
        () => validateProductLines([
          {...row(), 'note': 'x' * 501},
        ]),
        throwsFormatException,
      );
    },
  );
  test(
    'adding products to served table returns it to preparation and records worker in frozen ticket',
    () {
      final s = state(),
          o = newLocalOrder(
            state: state(),
            source: 'Masa',
            table: 1,
            productLines: [row()],
          );
      s['orders'] = [o];
      s['nextId'] = 1201;
      setLocalService(o, 'Hazır');
      setLocalService(o, 'Teslim Edildi');
      addOrderBatch(s, 1200, [row()], cashier: 'Test Personel B', staffId: 3);
      expect(o['serviceStatus'], 'Hazırlanıyor');
      final job = asMaps(s['printJobs']).last;
      expect(receiptText(s, job), contains('Test Personel B'));
      expect(receiptText(s, job), contains('Sos ayrı'));
    },
  );
  test(
    'partial cancellation cannot rewrite original kitchen slip; reprints preserve original content',
    () {
      final s = state();
      final o = newLocalOrder(
        state: s,
        source: 'Masa',
        table: 1,
        productLines: [row(qty: 2)],
      );
      final job = asMaps(s['printJobs']).first;
      final original = receiptText(s, job);
      cancelProduct(s, o['id'] as int, '1:0', 1, 'Bir ürün iptal');
      expect(receiptText(s, job), original);
      expect(original, contains('2 × Falafel'));
      expect(receiptText(s, asMaps(s['printJobs']).last), contains('İPTAL'));
      expect(orderTotalCents(o), 14000);
    },
  );
  test(
    'fully cancelled local order still prints its cancellation notice exactly once',
    () async {
      final dir = Directory.systemTemp.createTempSync('nohut-cancel-');
      final store = PosStore(databaseFile: '${dir.path}/db.sqlite3');
      final s = state();
      final o = newLocalOrder(
        state: s,
        source: 'Masa',
        table: 1,
        productLines: [row()],
      );
      cancelLocalOrder(s, o['id'] as int, 'Vazgeçti');
      store.replace(s, 0);
      final texts = <String>[];
      final printer = ReceiptPrinter(
        store,
        transport: (text, name) async {
          texts.add(text);
        },
      );
      try {
        await printer.pump();
        await printer.pump();
        expect(texts, hasLength(1));
        expect(texts.single, contains('İPTAL'));
        expect(asMaps(store.read().data['printJobs']).first['state'], 'İptal');
      } finally {
        printer.dispose();
        store.dispose();
        dir.deleteSync(recursive: true);
      }
    },
  );
  test(
    'staff addition ticket retains staff identity rather than default PC attribution',
    () {
      final dir = Directory.systemTemp.createTempSync('nohut-staff-');
      final store = PosStore(databaseFile: '${dir.path}/db.sqlite3');
      final s = state();
      newLocalOrder(state: s, source: 'Masa', table: 1, productLines: [row()]);
      store.replace(s, 0);
      try {
        submitStaffOrder(store, {
          'requestId': 'staff_add_0001',
          'expectedRevision': store.read().revision,
          'staffId': 2,
          'source': 'Masa',
          'table': 1,
          'lines': [
            {'productId': 0, 'qty': 1},
          ],
        });
        final current = store.read().data;
        expect(
          receiptText(current, asMaps(current['printJobs']).last),
          contains('Test Personel A'),
        );
      } finally {
        store.dispose();
        dir.deleteSync(recursive: true);
      }
    },
  );
  test(
    'LAN state exposes only ordering information and server start-stop is reusable',
    () async {
      final dir = Directory.systemTemp.createTempSync('nohut-projection-');
      final store = PosStore(databaseFile: '${dir.path}/db.sqlite3');
      final s = state();
      final o = newLocalOrder(
        state: s,
        source: 'Masa',
        table: 1,
        productLines: [row()],
      );
      recordPayment(o, 14000, 'Kart');
      closeLocalTable(o);
      openCash(s, 5000);
      s['settings']['privateTest'] = 'do not expose';
      store.replace(s, 0);
      final server = PosLanServer(
        store,
        port: 0,
        staffHtml: '<h1>Personel</h1>',
      );
      final client = HttpClient();
      try {
        await server.start();
        expect(server.running, isTrue, reason: server.error);
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/api/bootstrap'),
        );
        final body =
            jsonDecode(
                  await (await request.close()).transform(utf8.decoder).join(),
                )
                as Map;
        final exposed = body['state'] as Map;
        expect(exposed['orders'], isEmpty);
        expect(exposed.containsKey('cashBook'), isFalse);
        expect(exposed.containsKey('settings'), isFalse);
        await server.stop();
        expect(server.running, isFalse);
        await server.start();
        expect(server.running, isTrue);
      } finally {
        client.close(force: true);
        await server.stop();
        server.dispose();
        store.dispose();
        dir.deleteSync(recursive: true);
      }
    },
  );
}
