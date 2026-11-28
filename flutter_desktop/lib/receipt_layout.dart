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
    : paper = (settings?['paperWidthMm'] as num? ?? 57).toDouble(),
      width = (settings?['printableWidthMm'] as num? ?? 48).toDouble(),
      margin = (settings?['receiptMarginMm'] as num? ?? 4).toDouble(),
      offset = (settings?['receiptOffsetMm'] as num? ?? 0).toDouble(),
      logo = (settings?['receiptLogoMm'] as num? ?? 18).toDouble(),
      side = (settings?['receiptSidePaddingMm'] as num? ?? 3).toDouble() {
    if (![paper, width, margin, offset, logo, side].every((v) => v.isFinite) ||
        side < 0 ||
        side > 8 ||
        width - 2 * side < 28 ||
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
        'XP-237B: baskı 30–48 mm olmalı, kağıda sığmalı; sol/sağ boşluk 0–8 mm',
      );
    }
  }
  final double paper, width, margin, offset, logo;

  /// White space kept inside the print width on the left and right, so text
  /// never runs to the paper edge (57 mm rolls, XP-237B 48 mm head).
  final double side;
  int get dots => (width * 8).round();
}

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

/// The slip title comes from the first line ("NOHUT FALAFEL · MUTFAK").
String receiptTitle(String text) {
  final first = text.split('\n').first.trim();
  const prefix = 'NOHUT FALAFEL · ';
  if (first.startsWith(prefix) && first.length > prefix.length) {
    return first.substring(prefix.length);
  }
  return 'HESAP ÖZETİ';
}

final _priced = RegExp(r'^(\d+) × (.*?) · (-?[\d.,]+ ₺)$');
final _plainItem = RegExp(r'^(\d+) × (.+)$');
final _total = RegExp(r'^(Toplam|Net tahsilat|Ödenen|Kalan) (-?[\d.,]+ ₺)$');
final _amountRow = RegExp(r'^(.*\S) (-?[\d.,]+ ₺)$');
final _deliveryInfo = RegExp(r'^(Kurye|Tel|Adres): (.+)$');

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
    cfg.side,
  ]);
  if (key != _cachedKey || _cachedArtwork == null) {
    _cachedKey = key;
    _cachedArtwork = _renderReceipt(text, settings: settings);
  }
  return _cachedArtwork!;
}

Future<ReceiptArtwork> _renderReceipt(String text, {Map? settings}) async {
  final cfg = ReceiptDimensions(settings);
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
  final side = cfg.side * 8;
  // Everything is drawn inside the left/right safety margins.
  final w = cfg.dots - 2 * side, gap = cfg.margin * 8;
  drawing.translate(side, 0);
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
  )..layout(minWidth: width, maxWidth: width);
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

  final ink = Paint()..color = Colors.black;
  TextPainter rich(
    List<(String, bool)> parts,
    double width, {
    double size = 22,
    TextAlign align = TextAlign.left,
    Color color = Colors.black,
    bool heading = false,
  }) => TextPainter(
    text: TextSpan(
      style: TextStyle(
        color: color,
        fontFamily: heading ? NohutBrand.headingFont : NohutBrand.bodyFont,
        fontSize: size,
        height: 1.16,
      ),
      children: [
        for (final (value, bold) in parts)
          TextSpan(
            text: value,
            style: TextStyle(
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
      ],
    ),
    textDirection: TextDirection.ltr,
    textAlign: align,
  )..layout(minWidth: width, maxWidth: width);
  double put(TextPainter p, double x) {
    p.paint(drawing, Offset(x, y));
    final h = p.height;
    p.dispose();
    return h;
  }

  void dashed() {
    y += 6;
    for (var x = 0.0; x < w; x += 12) {
      drawing.drawRect(Rect.fromLTWH(x, y, 6, 2), ink);
    }
    y += 14;
  }

  // Black band with white text (İPTAL / EK SİPARİŞ) or an outlined stamp
  // (ÖDENDİ): both survive the 1-bit ESC/POS threshold.
  void banner(String value) {
    final filled = value != 'ÖDENDİ';
    final p = rich(
      [(value, true)],
      w - 24,
      size: 28,
      align: TextAlign.center,
      color: filled ? Colors.white : Colors.black,
    );
    final box = Rect.fromLTWH(0, y + 4, w, p.height + 16);
    if (filled) {
      drawing.drawRRect(
        RRect.fromRectAndRadius(box, const Radius.circular(6)), ink);
    } else {
      drawing.drawRRect(
        RRect.fromRectAndRadius(box.deflate(1.5), const Radius.circular(6)),
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }
    p.paint(drawing, Offset(12, y + 12));
    p.dispose();
    y = box.bottom + 10;
  }

  // "Çıkar: Domates" → bold label, regular value.
  List<(String, bool)> labelled(String value) {
    final m = RegExp(r'^(Çıkar|Ekstra|Not|Neden|NOT):\s*(.*)$').firstMatch(value);
    if (m == null) return [(value, false)];
    return [('${m[1]}: ', true), (m[2]!, m[1] == 'Çıkar')];
  }

  final logoSize = cfg.logo * 8;
  drawing.drawImageRect(
    logo,
    Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
    Rect.fromLTWH((w - logoSize) / 2, y, logoSize, logoSize),
    Paint()..filterQuality = FilterQuality.high,
  );
  y += logoSize + 14;
  line(receiptTitle(text), size: 29, heading: true, align: TextAlign.center);
  rule();
  var header = true, first = true, infoBlock = false;
  for (final raw in receiptBody(text)) {
    if (raw.trim().isEmpty) continue;
    final priced = _priced.firstMatch(raw),
        total = _total.firstMatch(raw),
        amount = _amountRow.firstMatch(raw),
        plainItem = _plainItem.firstMatch(raw);
    final detail = raw.startsWith('  ');
    if (header &&
        (priced != null ||
            total != null ||
            amount != null ||
            plainItem != null ||
            detail ||
            raw == '---' ||
            raw.startsWith('Not:'))) {
      header = false;
      rule();
    }
    if (header) {
      if (raw.startsWith('!! ')) {
        banner(raw.substring(3));
      } else if (first && raw.startsWith('#')) {
        final split = raw.indexOf(' · ');
        final number = split < 0 ? raw : raw.substring(0, split);
        y += put(
          rich([(number, false)], w, size: 54, heading: true,
              align: TextAlign.center),
          0,
        );
        if (split >= 0) {
          y += put(
            rich([(raw.substring(split + 3), true)], w, size: 30,
                align: TextAlign.center),
            0,
          ) + 6;
        }
      } else if (_deliveryInfo.firstMatch(raw) case final info?) {
        // Delivery block (Trendyol GO): compact, left-aligned, the label in
        // its own column so a long address wraps under itself.
        if (!infoBlock) y += 6;
        infoBlock = true;
        const labelWidth = 72.0;
        final l = rich([('${info[1]}:', true)], labelWidth, size: 21),
            r = rich([(info[2]!, false)], w - labelWidth, size: 21);
        final h = math.max(l.height, r.height);
        put(l, 0);
        put(r, labelWidth);
        y += h + 3;
      } else {
        y += put(rich([(raw, false)], w, size: 21, align: TextAlign.center),
            0) + 4;
      }
      first = false;
      continue;
    }
    first = false;
    if (raw.startsWith('!! ')) {
      banner(raw.substring(3));
    } else if (raw == '---') {
      dashed();
    } else if (priced != null) {
      y += 6;
      final qty = rich([('${priced[1]}×', true)], 44, size: 25),
          name = rich([(priced[2]!, true)], w - 44 - 120, size: 25),
          price = rich([(priced[3]!, false)], 116, size: 22,
              align: TextAlign.right);
      final h = math.max(qty.height, math.max(name.height, price.height));
      put(qty, 0);
      put(name, 44);
      put(price, w - 116);
      y += h + 4;
    } else if (plainItem != null && !detail) {
      y += 6;
      final qty = rich([('${plainItem[1]}×', true)], 44, size: 25),
          name = rich([(plainItem[2]!, true)], w - 44, size: 25);
      final h = math.max(qty.height, name.height);
      put(qty, 0);
      put(name, 44);
      y += h + 4;
    } else if (detail) {
      final value = raw.trim();
      final unit = RegExp(r'^\d+ × -?[\d.,]+ ₺$').hasMatch(value);
      y += put(
        rich(labelled(value), w - 44, size: unit ? 19 : 22),
        44,
      ) + 3;
    } else if (raw.startsWith('Not:')) {
      y += 8;
      final p = rich(labelled('NOT: ${raw.substring(4).trim()}'), w - 20,
          size: 24);
      final box = Rect.fromLTWH(0, y, w, p.height + 16);
      drawing.drawRRect(
        RRect.fromRectAndRadius(box.deflate(1), const Radius.circular(6)),
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      p.paint(drawing, Offset(10, y + 8));
      p.dispose();
      y = box.bottom + 8;
    } else if (total != null) {
      final isTotal = total[1] == 'Toplam';
      if (isTotal) rule();
      final label = switch (total[1]) {
        'Toplam' => 'TOPLAM',
        'Net tahsilat' => 'Ödenen',
        final other => other!,
      };
      final strong = isTotal || total[1] == 'Kalan';
      final size = isTotal ? 32.0 : strong ? 26.0 : 23.0;
      final l = rich([(label, strong)], w * .44, size: size),
          r = rich([(total[2]!, strong)], w * .56, size: size,
              align: TextAlign.right);
      final h = math.max(l.height, r.height);
      put(l, 0);
      put(r, w * .44);
      y += h + 8;
    } else if (amount != null) {
      final l = rich([(amount[1]!, false)], w - 130, size: 22),
          r = rich([(amount[2]!, true)], 126, size: 22,
              align: TextAlign.right);
      final h = math.max(l.height, r.height);
      put(l, 0);
      put(r, w - 126);
      y += h + 6;
    } else {
      y += put(rich(labelled(raw), w, size: 21), 0) + 5;
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
    Rect.fromLTWH(0, 0, cfg.dots.toDouble(), y.ceilToDouble()),
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
