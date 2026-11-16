import 'dart:math' as math;
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand.dart';

/// One offline artwork is used by preview, Windows and ESC/POS.
class ReceiptArtwork {
  const ReceiptArtwork(this.png, this.rgba, this.width, this.height);
  final Uint8List png, rgba;
  final int width, height;
}

class ReceiptDimensions {
  ReceiptDimensions(Map? settings)
    : paper = (settings?['paperWidthMm'] as num? ?? 56).toDouble(),
      width = (settings?['printableWidthMm'] as num? ?? 48).toDouble(),
      margin = (settings?['receiptMarginMm'] as num? ?? 4).toDouble(),
      offset = (settings?['receiptOffsetMm'] as num? ?? 0).toDouble(),
      logo = (settings?['receiptLogoMm'] as num? ?? 18).toDouble() {
    if (![paper, width, margin, offset, logo].every((v) => v.isFinite) ||
        paper < 40 ||
        paper > 80 ||
        width < 30 ||
        width > 48 ||
        width > paper ||
        margin < 2 ||
        margin > 10 ||
        offset.abs() > 10 ||
        logo < 10 ||
        logo > 25 ||
        (paper - width) / 2 + offset < 0 ||
        (paper - width) / 2 + offset + width > paper) {
      throw const FormatException(
        'XP-237B: baskı 30–48 mm olmalı ve kağıda sığmalı',
      );
    }
  }
  final double paper, width, margin, offset, logo;
  int get dots => (width * 8).round();
}

Future<void>? _fonts;
Future<void> _loadReceiptFonts() => _fonts ??= () async {
  final body = FontLoader(NohutBrand.bodyFont)
    ..addFont(rootBundle.load('assets/brand/fonts/Barlow-Regular.ttf'))
    ..addFont(rootBundle.load('assets/brand/fonts/Barlow-Bold.ttf'));
  final heading = FontLoader(NohutBrand.headingFont)
    ..addFont(rootBundle.load('assets/brand/fonts/BreeSerif-Regular.ttf'));
  await Future.wait([body.load(), heading.load()]);
}();

List<String> receiptBody(String text) => text.split('\n').where((line) {
  final normal = line
      .toUpperCase()
      .replaceAll('İ', 'I')
      .replaceAll('Ş', 'S')
      .replaceAll('Ğ', 'G');
  return !normal.startsWith('NOHUT FALAFEL') &&
      !normal.startsWith('MALI FIS DEGILDIR') &&
      normal.trim() != 'AFIYET OLSUN!';
}).toList();

String? _cachedKey;
Future<ReceiptArtwork>? _cachedArtwork;
Future<ReceiptArtwork> renderReceipt(String text, {Map? settings}) {
  final cfg = ReceiptDimensions(settings);
  final key = jsonEncode([
    text,
    cfg.paper,
    cfg.width,
    cfg.margin,
    cfg.offset,
    cfg.logo,
  ]);
  if (key != _cachedKey || _cachedArtwork == null) {
    _cachedKey = key;
    _cachedArtwork = _renderReceipt(text, settings: settings);
  }
  return _cachedArtwork!;
}

Future<ReceiptArtwork> _renderReceipt(String text, {Map? settings}) async {
  final cfg = ReceiptDimensions(settings);
  await _loadReceiptFonts();
  final logoData = await rootBundle.load(
    'assets/printing/nohut-receipt-logo.png',
  );
  final codec = await ui.instantiateImageCodec(
    logoData.buffer.asUint8List(logoData.offsetInBytes, logoData.lengthInBytes),
  );
  final logo = (await codec.getNextFrame()).image;
  final recorder = ui.PictureRecorder();
  // Build on a separate recorder so the final white background has exact height.
  final drawing = Canvas(recorder);
  final w = cfg.dots.toDouble(), gap = cfg.margin * 8;
  var y = gap;
  TextPainter painter(
    String value,
    double width, {
    double size = 23,
    bool bold = false,
    bool heading = false,
    TextAlign align = TextAlign.left,
  }) => TextPainter(
    text: TextSpan(
      text: value,
      style: TextStyle(
        color: Colors.black,
        fontFamily: heading ? NohutBrand.headingFont : NohutBrand.bodyFont,
        fontSize: size,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        height: 1.16,
      ),
    ),
    textDirection: TextDirection.ltr,
    textAlign: align,
  )..layout(maxWidth: width);
  void line(
    String value, {
    double size = 23,
    bool bold = false,
    bool heading = false,
    TextAlign align = TextAlign.left,
  }) {
    final p = painter(
      value,
      w,
      size: size,
      bold: bold,
      heading: heading,
      align: align,
    );
    p.paint(drawing, Offset(0, y));
    y += p.height + 7;
    p.dispose();
  }

  void rule() {
    y += 7;
    drawing.drawLine(
      Offset(0, y),
      Offset(w, y),
      Paint()
        ..color = Colors.black
        ..strokeWidth = 1,
    );
    y += 13;
  }

  final logoSize = cfg.logo * 8;
  drawing.drawImageRect(
    logo,
    Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
    Rect.fromLTWH((w - logoSize) / 2, y, logoSize, logoSize),
    Paint()..filterQuality = FilterQuality.high,
  );
  y += logoSize + 14;
  line(
    text.contains('MUTFAK') ? 'MUTFAK' : 'HESAP ÖZETİ',
    size: 29,
    heading: true,
    align: TextAlign.center,
  );
  rule();
  for (final raw in receiptBody(text)) {
    if (raw.trim().isEmpty) continue;
    final item = RegExp(r'^(\d+) × (.*?) · ([\d.,]+ ₺)$').firstMatch(raw);
    final total = RegExp(r'^(Toplam|Net tahsilat|Kalan) ([\d.,]+ ₺)$')
        .firstMatch(raw);
    if (item != null) {
      final qty = painter(item[1]!, 30, bold: true),
          name = painter(item[2]!, w - 150, bold: true),
          price = painter(item[3]!, 112, size: 22, align: TextAlign.right);
      final h = math.max(qty.height, math.max(name.height, price.height));
      qty.paint(drawing, Offset(0, y));
      name.paint(drawing, Offset(34, y));
      price.paint(drawing, Offset(w - 112, y));
      y += h + 13;
      qty.dispose();
      name.dispose();
      price.dispose();
    } else if (total != null) {
      final isTotal = total[1] == 'Toplam';
      if (isTotal) rule();
      final label = total[1] == 'Toplam'
          ? 'TOPLAM'
          : total[1] == 'Net tahsilat'
          ? 'Ödenen'
          : 'Kalan';
      final l = painter(label, w * .44, size: isTotal ? 30 : 23, bold: isTotal),
          r = painter(
            total[2]!,
            w * .56,
            size: isTotal ? 30 : 23,
            bold: isTotal,
            align: TextAlign.right,
          );
      l.paint(drawing, Offset(0, y));
      r.paint(drawing, Offset(w * .44, y));
      y += math.max(l.height, r.height) + 9;
      l.dispose();
      r.dispose();
    } else {
      line(raw, size: raw.startsWith('  ') ? 21 : 23);
    }
    if (y > 15000)
      throw const FormatException('Fiş çok uzun; daha kısa hesap dökümü seçin');
  }
  rule();
  line('Afiyet olsun!', size: 30, heading: true, align: TextAlign.center);
  line('Nohut Falafel', size: 22, align: TextAlign.center);
  line('MALİ FİŞ DEĞİLDİR', size: 17, align: TextAlign.center);
  y += gap;
  final picture = recorder.endRecording();
  final finalRecorder = ui.PictureRecorder(),
      finalCanvas = Canvas(finalRecorder);
  finalCanvas.drawRect(
    Rect.fromLTWH(0, 0, w, y.ceilToDouble()),
    Paint()..color = Colors.white,
  );
  finalCanvas.drawPicture(picture);
  final finalPicture = finalRecorder.endRecording();
  final image = await finalPicture.toImage(cfg.dots, y.ceil());
  final png = await image.toByteData(format: ui.ImageByteFormat.png),
      rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (png == null || rgba == null)
    throw const FormatException('Fiş görseli oluşturulamadı');
  final result = ReceiptArtwork(
    png.buffer.asUint8List(),
    rgba.buffer.asUint8List(),
    cfg.dots,
    y.ceil(),
  );
  image.dispose();
  logo.dispose();
  codec.dispose();
  picture.dispose();
  finalPicture.dispose();
  return result;
}

/// Raster bands avoid label page-height limits and printer buffer-sized images.
Uint8List escPosReceipt(ReceiptArtwork art, {int bandHeight = 128}) {
  if (art.width < 1 ||
      art.width > 384 ||
      art.height < 1 ||
      art.height > 16000 ||
      bandHeight < 1 ||
      bandHeight > 256 ||
      art.rgba.length != art.width * art.height * 4)
    throw const FormatException('Geçersiz fiş rasteri');
  final out = BytesBuilder()..add([27, 64, 27, 97, 1]);
  final rowBytes = (art.width + 7) ~/ 8;
  for (var top = 0; top < art.height; top += bandHeight) {
    final h = math.min(bandHeight, art.height - top),
        data = Uint8List(rowBytes * h);
    for (var y = 0; y < h; y++)
      for (var x = 0; x < art.width; x++) {
        final i = ((top + y) * art.width + x) * 4;
        final luminance =
            (art.rgba[i] * 299 +
                art.rgba[i + 1] * 587 +
                art.rgba[i + 2] * 114) ~/
            1000;
        if (art.rgba[i + 3] > 127 && luminance < 170)
          data[y * rowBytes + x ~/ 8] |= 128 >> (x % 8);
      }
    out.add([29, 118, 48, 0, rowBytes & 255, rowBytes >> 8, h & 255, h >> 8]);
    out.add(data);
  }
  out.add([27, 100, 3, 27, 97, 0]);
  return out.takeBytes();
}
