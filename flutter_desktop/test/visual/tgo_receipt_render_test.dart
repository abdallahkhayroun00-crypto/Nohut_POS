// Side-by-side receipt previews for owner review (relay 7237018573):
// previous Trendyol GO ticket vs the same ticket with Kurye / Tel / Adres.
// Both columns use the production renderer at the default 57 mm paper /
// 48 mm print width and identical synthetic priced orders. Writes PNGs only
// when NOHUT_RENDER_DIR is set; the layout assertions always run.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/brand.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/receipt_layout.dart';
import 'package:nohut_falafel_desktop/trendyol_go_readonly.dart';

const _longAddress =
    'Çiğdem Sokak Güneşli Apartmanı No: 12/4 İç Kapı Zil Üçüncü Kat Sağdaki Daire Bahçe Girişi';

Json _order({required String delivery, bool pickup = false}) => {
  'dailyNumber': 17,
  ...normalizeTgoPackage({
    'id': 'pkg-preview',
    'orderNumber': '1094482217',
    'orderCode': 'A7K2',
    'packageStatus': 'Picking',
    'packageCreationDate': 1764320340000,
    'deliveryType': delivery,
    if (pickup) 'storePickupSelected': true,
    'customer': {'firstName': 'Test', 'lastName': 'Müşteri'},
    'customerNote': 'Zili çalmayın, kapıya bırakın',
    'totalPrice': 545.0,
    'payment': {'paymentType': 'PAY_WITH_CARD'},
    'address': {
      'phone': '05550000000',
      'address1': _longAddress,
      'district': 'Şişli',
      'city': 'İstanbul',
    },
    'lines': [
      {
        'name': 'Falafel Dürüm',
        'unitSellingPrice': 160.0,
        'items': [{'isCancelled': false}, {'isCancelled': false}],
        'removedIngredients': [{'name': 'Soğan'}],
        'extraIngredients': [{'name': 'Humus'}],
      },
      {
        'name': 'Falafel Menü',
        'unitSellingPrice': 225.0,
        'items': [{'isCancelled': false}],
        'modifierProducts': [
          {'name': 'Patates (Büyük)', 'removedIngredients': [{'name': 'Ketçap'}]},
          {'name': 'Ayran'},
        ],
      },
    ],
  }),
};

/// The ticket as it printed before 6a52c1d: the same text without the three
/// added lines (the renderer draws every other line exactly as before).
String _previous(String ticket) => ticket
    .split('\n')
    .where((l) => !RegExp(r'^(Kurye|Tel|Adres): ').hasMatch(l))
    .join('\n');

Future<ui.Image> _decode(Uint8List png) async =>
    (await (await ui.instantiateImageCodec(png)).getNextFrame()).image;

Future<Uint8List> _sideBySide(ReceiptArtwork a, ReceiptArtwork b) async {
  const gap = 40.0, pad = 24.0;
  final left = await _decode(a.png), right = await _decode(b.png);
  final w = (pad * 2 + left.width + gap + right.width).ceil();
  final h = (pad * 2 + (left.height > right.height ? left.height : right.height)).ceil();
  final rec = ui.PictureRecorder(), c = Canvas(rec);
  c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = const Color(0xffE6E6E6));
  c.drawImage(left, const Offset(pad, pad), Paint());
  c.drawImage(right, Offset(pad + left.width + gap, pad), Paint());
  final img = await rec.endRecording().toImage(w, h);
  final out = (await img.toByteData(format: ui.ImageByteFormat.png))!;
  return out.buffer.asUint8List();
}

void main() {
  testWidgets('Trendyol GO receipt: previous vs with delivery block', (t) async {
    await t.runAsync(() async {
      final body = FontLoader(NohutBrand.bodyFont)
        ..addFont(rootBundle.load('assets/brand/fonts/Barlow-Regular.ttf'))
        ..addFont(rootBundle.load('assets/brand/fonts/Barlow-Bold.ttf'));
      final heading = FontLoader(NohutBrand.headingFont)
        ..addFont(rootBundle.load('assets/brand/fonts/BreeSerif-Regular.ttf'));
      await Future.wait([body.load(), heading.load()]);
    });
    final dir = Platform.environment['NOHUT_RENDER_DIR'];
    final cases = {
      'store': _order(delivery: 'STORE'),
      'go': _order(delivery: 'GO'),
      'gel-al': _order(delivery: 'STORE', pickup: true),
    };
    for (final MapEntry(key: name, value: order) in cases.entries) {
      final ticket = tgoKitchenTicket(order);
      // Nothing from the original receipt is lost on a priced order.
      for (final kept in [
        'MALİ FİŞ DEĞİLDİR', 'Platform no: 1094482217 · Kod: A7K2',
        'Müşteri: Test Müşteri', '2 × Falafel Dürüm · 320,00 ₺',
        '  2 × 160,00 ₺', '  Çıkar: Soğan', '  Ekstra: Humus',
        '1 × Falafel Menü · 225,00 ₺', '  + Patates (Büyük) · Çıkar: Ketçap',
        '  + Ayran', 'Not: Zili çalmayın, kapıya bırakın',
        'Toplam 545,00 ₺', 'Ödeme: Kart',
      ]) {
        expect(ticket, contains(kept), reason: '$name keeps "$kept"');
      }
      expect(RegExp('^Kurye:', multiLine: true).allMatches(ticket).length,
          name == 'gel-al' ? 0 : 1, reason: 'printed once, never duplicated');
      expect(ticket.contains('Adres:'), name == 'store');
      final before = (await t.runAsync(() => renderReceipt(_previous(ticket))))!;
      final after = (await t.runAsync(() => renderReceipt(ticket)))!;
      expect(after.width, before.width, reason: 'same 48 mm print width');
      expect(after.width, ReceiptDimensions(null).dots);
      if (name == 'gel-al') {
        expect(after.png, before.png, reason: 'Gel-Al receipt is unchanged');
      } else {
        expect(after.height, greaterThan(before.height));
      }
      if (dir != null) {
        final png = (await t.runAsync(() => _sideBySide(before, after)))!;
        File('$dir/tgo-receipt-$name-before-after.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(png);
      }
    }
  });
}
