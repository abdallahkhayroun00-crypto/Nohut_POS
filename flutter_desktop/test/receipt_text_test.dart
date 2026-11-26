import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/order_actions.dart';
import 'package:nohut_falafel_desktop/receipt_printer.dart';
import 'package:nohut_falafel_desktop/operations.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/receipt_layout.dart';

Json row(String name, int price, {int qty = 1, String note = ''}) => {
  'productId': name == 'Ayran' ? 1 : 0,
  'name': name,
  'price': price,
  'qty': qty,
  'removed': name == 'Falafel' ? <String>['Domates'] : <String>[],
  'note': note,
};

Json state() => {
  ...emptyPosState(),
  'localMenu': [
    {'id': 0, 'name': 'Falafel', 'category': 'wrap', 'price': 140},
    {'id': 1, 'name': 'Ayran', 'category': 'drink', 'price': 35},
  ],
  'settings': {'autoPrint': true, 'printerName': 'fake'},
};

void main() {
  test('order slip is one ticket with number, service, prices and total', () {
    final s = state();
    newLocalOrder(
      state: s,
      source: 'Masa',
      table: 3,
      productLines: [row('Falafel', 140, qty: 2, note: 'Acı'), row('Ayran', 35)],
    );
    final text = receiptText(s, asMaps(s['printJobs']).single);
    final lines = text.split('\n');
    expect(lines[0], 'NOHUT FALAFEL · SİPARİŞ FİŞİ');
    expect(receiptTitle(text), 'SİPARİŞ FİŞİ');
    expect(text, isNot(contains('MUTFAK')));
    expect(lines[2], endsWith(' · Masa 3'));
    expect(text, contains('2 × Falafel · 280,00 ₺'));
    expect(text, contains('  2 × 140,00 ₺'));
    expect(text, contains('  Çıkar: Domates'));
    expect(text, contains('  Not: Acı'));
    expect(text, contains('1 × Ayran · 35,00 ₺'));
    expect(lines.last, 'Toplam 315,00 ₺');
    expect(text, isNot(contains('!! ')));
  });

  test('additions are marked; pickup shows name and time but never phone', () {
    final s = state();
    final o = newLocalOrder(
      state: s,
      source: 'Gel-Al',
      productLines: [row('Ayran', 35)],
      pickupChannel: 'Telefon',
    );
    o['customer'] = {'name': 'Ayşe', 'phone': '05551234567', 'time': '13:15'};
    addOrderBatch(s, o['id'] as int, [row('Falafel', 140)], cashier: 'Elif');
    final job = asMaps(s['printJobs']).last;
    final text = receiptText(s, job);
    expect(text, contains(' · Gel-Al · Telefon'));
    expect(text, contains('Müşteri: Ayşe · Saat 13:15'));
    expect(text, contains('!! EK SİPARİŞ'));
    expect(text, isNot(contains('0555')));
    expect('${job['snapshot']}', isNot(contains('0555')));
  });

  test('cancelling a whole order prints one İPTAL slip, not one per product',
      () {
    final s = state();
    final o = newLocalOrder(
      state: s,
      source: 'Masa',
      table: 1,
      productLines: [row('Falafel', 140), row('Ayran', 35, qty: 2)],
    );
    cancelLocalOrder(s, o['id'] as int, 'Müşteri vazgeçti');
    final jobs = asMaps(s['printJobs']);
    expect(jobs, hasLength(2));
    expect(jobs.first['state'], 'İptal');
    final text = receiptText(s, jobs.last);
    expect(text, contains('!! İPTAL'));
    expect(text, contains('1 × İPTAL: Falafel'));
    expect(text, contains('2 × İPTAL: Ayran'));
    expect(text, contains('  Neden: Müşteri vazgeçti'));
    expect(text, isNot(contains('Toplam')));
    expect(asMaps(o['batches']), hasLength(2));
    PosStore.validate(s);
  });

  test('bill: clean service line, paid stamp, change and no dangling dots', () {
    final s = state();
    final o = newLocalOrder(
      state: s,
      source: 'Masa',
      table: 2,
      productLines: [row('Falafel', 140)],
    );
    expect(billText(o), isNot(contains('Ödenen')));
    expect(billText(o), contains('Kalan 140,00 ₺'));
    recordPayment(o, 10000, 'Nakit', receivedCents: 20000);
    recordPayment(o, 4000, 'Kart');
    final text = billText(o);
    expect(text.split('\n')[2], endsWith(' · Masa 2'));
    expect(text, contains('Ödenen 140,00 ₺'));
    expect(text, isNot(contains('Kalan')));
    expect(text, contains('!! ÖDENDİ'));
    expect(text, contains('Nakit 100,00 ₺'));
    expect(text, contains('  Alınan 200,00 ₺\n  Para üstü 100,00 ₺'));
    expect(text, contains('Kart 40,00 ₺'));
    expect(RegExp(r' · $', multiLine: true).hasMatch(text), isFalse);
  });

  test('receipt keeps left and right safety margins inside the print width',
      () {
    final cfg = ReceiptDimensions(null);
    expect(cfg.paper, 57);
    expect(cfg.side, 3);
    expect(ReceiptDimensions({'receiptSidePaddingMm': 0}).side, 0);
    expect(() => ReceiptDimensions({'receiptSidePaddingMm': 9}),
        throwsFormatException);
    expect(() => ReceiptDimensions({'printableWidthMm': 30,
      'receiptSidePaddingMm': 2}), throwsFormatException);
  });

  test('order slip follows the auto switch; Hesap Özeti always prints',
      () async {
    final dir = Directory.systemTemp.createTempSync('nohut-slip');
    final store = PosStore(databaseFile: '${dir.path}/db');
    final sent = <String>[];
    final printer = ReceiptPrinter(store, transport: (text, name) async {
      sent.add(text);
    });
    try {
      final s = state();
      (s['settings'] as Map)['autoPrint'] = false;
      final o = newLocalOrder(state: s, source: 'Masa', table: 1,
          productLines: [row('Ayran', 35)]);
      recordPayment(o, 3500, 'Kart');
      queuePaymentReceipt(s, o, requestId: 'r1');
      expect(store.replace(s, store.read().revision).ok, true);
      for (var i = 0; i < 4; i++) {
        await printer.pump();
      }
      expect(sent, hasLength(1));
      expect(sent.single, startsWith('NOHUT FALAFEL · HESAP ÖZETİ'));
      final next = store.read().data;
      (next['settings'] as Map)['autoPrint'] = true;
      store.replace(next, store.read().revision);
      for (var i = 0; i < 4; i++) {
        await printer.pump();
      }
      expect(sent, hasLength(2));
      expect(sent.last, startsWith('NOHUT FALAFEL · SİPARİŞ FİŞİ'));
    } finally {
      printer.dispose();
      store.dispose();
      dir.deleteSync(recursive: true);
    }
  });
}
