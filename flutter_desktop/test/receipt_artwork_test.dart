import 'package:flutter/services.dart';
import 'package:nohut_falafel_desktop/brand.dart';

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/receipt_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('XP-237B dimensions refuse over-wide or out-of-paper artwork', () {
    expect(ReceiptDimensions(null).dots, 384);
    expect(
      () => ReceiptDimensions({'printableWidthMm': 56}),
      throwsFormatException,
    );
    expect(
      () => ReceiptDimensions({'receiptOffsetMm': 8}),
      throwsFormatException,
    );
    expect(
      () => ReceiptDimensions({'paperWidthMm': double.nan}),
      throwsFormatException,
    );
  });
  test('raster bands retain every row, use MSB first and add no page cuts', () {
    final pixels = Uint8List(8 * 300 * 4)..fillRange(0, 8 * 300 * 4, 255);
    pixels[0] = pixels[1] = pixels[2] = 0;
    final last = (8 * 299 + 7) * 4;
    pixels[last] = pixels[last + 1] = pixels[last + 2] = 0;
    final art = ReceiptArtwork(Uint8List(0), pixels, 8, 300),
        bytes = escPosReceipt(art);
    expect(bytes.sublist(0, 5), [27, 64, 27, 97, 1]);
    var at = 5, rows = 0;
    final decoded = <int>[];
    while (at < bytes.length - 6) {
      expect(bytes.sublist(at, at + 4), [29, 118, 48, 0]);
      final width = bytes[at + 4] + bytes[at + 5] * 256,
          height = bytes[at + 6] + bytes[at + 7] * 256;
      expect(width, 1);
      expect(height, lessThanOrEqualTo(128));
      decoded.addAll(bytes.sublist(at + 8, at + 8 + width * height));
      rows += height;
      at += 8 + width * height;
    }
    expect(rows, 300);
    expect(decoded.first, 128);
    expect(decoded.last, 1);
    expect(decoded.sublist(1, 299), everyElement(0));
    expect(bytes.sublist(at), [27, 100, 3, 27, 97, 0]);
  });
  test('real logo and offline brand fonts render complete long Turkish receipt with white safety margins', () async {
    final body = FontLoader(NohutBrand.bodyFont)
      ..addFont(rootBundle.load('assets/brand/fonts/Barlow-Regular.ttf'))
      ..addFont(rootBundle.load('assets/brand/fonts/Barlow-Bold.ttf'));
    final heading = FontLoader(NohutBrand.headingFont)
      ..addFont(rootBundle.load('assets/brand/fonts/BreeSerif-Regular.ttf'));
    await Future.wait([body.load(), heading.load()]);
    final text =
        'NOHUT FALAFEL · HESAP ÖZETİ\nMALİ FİŞ DEĞİLDİR\n#0001 · Masa · 3\n16.11.2026 12:00\n1 × 2’li Menü · 300,00 ₺\n  Falafel Dürüm · Çıkar: Domates\n  Falafel Dürüm · Sos ayrı\n  Küçük Ayran\n  Küçük Ayran\n${List.generate(18, (i) => '1 × Ispanaklı Sembusek · 40,00 ₺').join('\n')}\nToplam 1020,00 ₺\nNet tahsilat 1020,00 ₺\nKalan 0,00 ₺';
    final art = await renderReceipt(text).timeout(const Duration(seconds: 30));
    expect(art, isNotNull);
    expect(art.width, 384);
    expect(art.height, greaterThan(960));
    expect(art.png.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(art.rgba.sublist(0, 384 * 24 * 4), everyElement(255));
    expect(art.rgba.sublist(art.rgba.length - 384 * 24 * 4), everyElement(255));
    var left = art.width, right = 0;
    for (var y = 190; y < 230; y++)
      for (var x = 0; x < art.width; x++) {
        final pixel = (y * art.width + x) * 4;
        if (art.rgba[pixel] < 128) {
          if (x < left) left = x;
          if (x > right) right = x;
        }
      }
    expect(right, greaterThan(left));
    expect(
      ((left + right) / 2 - (art.width - 1) / 2).abs(),
      lessThan(4),
      reason: 'HESAP ÖZETİ must be centered on the physical print width',
    );
    final file = File('build/receipt-brand-proof.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(art.png);
    expect(
      identical(await renderReceipt(text), art),
      true,
      reason: 'preview and spool reuse identical artwork',
    );
    final payload = escPosReceipt(art);
    expect(payload.length, greaterThan(art.width * art.height ~/ 8));
  });
  test('order slip draws banners, note box and totals within the paper',
      () async {
    final body = FontLoader(NohutBrand.bodyFont)
      ..addFont(rootBundle.load('assets/brand/fonts/Barlow-Regular.ttf'))
      ..addFont(rootBundle.load('assets/brand/fonts/Barlow-Bold.ttf'));
    final heading = FontLoader(NohutBrand.headingFont)
      ..addFont(rootBundle.load('assets/brand/fonts/BreeSerif-Regular.ttf'));
    await Future.wait([body.load(), heading.load()]);
    const text = 'NOHUT FALAFEL · SİPARİŞ FİŞİ\nMALİ FİŞ DEĞİLDİR\n'
        '#0017 · Trendyol Go · Paket Servis\nPlatform no: 1094 · Kod: 4D5AC\n'
        '26.11.2026 12:40\n!! EK SİPARİŞ\n'
        '2 × Falafel Menü · 420,00 ₺\n  2 × 210,00 ₺\n  + Humus\n'
        '  Çıkar: Domates\n  Ekstra: Acı sos\n1 × İPTAL: Ayran\n'
        '  Neden: Bitti\nNot: Zili çalmayın\nToplam 420,00 ₺\n!! ÖDENDİ\n'
        '---\nKart 420,00 ₺\nÖdeme: Kart';
    expect(receiptTitle(text), 'SİPARİŞ FİŞİ');
    final art = await renderReceipt(text).timeout(const Duration(seconds: 30));
    expect(art.width, 384);
    expect(art.height, greaterThan(900));
    expect(art.rgba.sublist(art.rgba.length - 384 * 24 * 4), everyElement(255));
    expect(escPosReceipt(art).length, greaterThan(art.width * art.height ~/ 8));
  });
}
