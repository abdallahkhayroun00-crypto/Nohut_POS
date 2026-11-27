import 'dart:ui';

/// Some QR menu photos are shared atlases (several dishes on one canvas).
/// The public menu (`qr-menu/menu.js`) shows each dish by cropping its region;
/// these are the same regions, copied read-only so POS thumbnails show the one
/// dish instead of the whole sheet. Keyed by the exact image path AND the
/// Turkish product name, so a changed photo never gets a stale crop.
class QrAtlasCrop {
  const QrAtlasCrop(this.canvas, this.crop);
  final Size canvas;
  final Rect crop;
}

const _wraps = 'assets/wrap-cutouts/wraps-transparent.webp';
const _sides = 'assets/side-cutouts/sides.webp';
const _salads = 'assets/salad-cutouts/salads.webp';
const _fattePair = 'assets/platter-cutouts/fatte-pair-20261028.webp';
const _fatteThree = 'assets/platter-cutouts/fatte-selected-three-20261028.webp';

QrAtlasCrop _c(double w, double h, double x, double y, double cw, double ch) =>
    QrAtlasCrop(Size(w, h), Rect.fromLTWH(x, y, cw, ch));

final Map<String, Map<String, QrAtlasCrop>> qrAtlasCrops = {
  _wraps: {
    'Falafel Dürüm': _c(1536, 1024, 20, 76, 470, 362),
    'Patates Dürüm': _c(1536, 1024, 520, 76, 480, 362),
    'Nohut Özel Dürüm': _c(1536, 1024, 1030, 76, 486, 362),
    'Patatesli Patlıcanlı Falafel Dürüm': _c(1536, 1024, 172, 522, 530, 367),
    'Patatesli Falafel Dürüm': _c(1536, 1024, 810, 520, 534, 370),
  },
  _sides: {
    'Kıymalı Sembusek (4 Adet)': _c(1536, 1024, 538, 22, 470, 478),
    'Ispanaklı Sembusek (4 Adet)': _c(1536, 1024, 1028, 22, 476, 478),
    'Patates Kızartması': _c(1536, 1024, 1080, 493, 365, 480),
  },
  _salads: {
    'Falafel Salatası': _c(2156, 729, 22, 19, 674, 681),
    'Tabbule': _c(2156, 729, 729, 16, 692, 691),
    'Fettuş': _c(2156, 729, 1436, 16, 710, 693),
  },
  _fattePair: {
    'Tereyağlı Fatte': _c(1536, 1024, 0, 104, 768, 768),
    'Tereyağında Kuruyemişli Fatte': _c(1536, 1024, 768, 104, 768, 768),
  },
  _fatteThree: {
    'Patlıcanlı Fatte': _c(1536, 1024, 512, 215, 512, 512),
  },
};

/// The dish's region inside a shared atlas, or null for a normal photo.
QrAtlasCrop? qrAtlasCrop(String image, String turkishName) =>
    qrAtlasCrops[image]?[turkishName.trim()];

/// True when [image] is a known atlas: without a crop for this product the
/// thumbnail must not show the whole sheet.
bool isQrAtlas(String image) => qrAtlasCrops.containsKey(image);
