// Full-shell renders of every Windows sidebar section at the two desktop
// sizes the owner uses, for the Premium UI before/after review. Set
// NOHUT_RENDER_DIR to write PNGs; without it this is a smoke test that no
// section throws or overflows.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pos_flow_render_test.dart' show mount, shot;

const sections = <(String, String)>[
  ('genel', 'Genel Bakış'),
  ('online', 'Online Siparişler'),
  ('platform', 'Platform Yönetimi'),
  ('geri-bildirim', 'Geri Bildirimler'),
  ('google', 'Google İşletme Profili'),
  ('qr-menu', 'QR Menü Yönetimi'),
  ('acik-hesap', 'Açık Hesaplar'),
  ('raporlar', 'Raporlar'),
  ('finans', 'Finans'),
  ('market', 'Market Fiyat Takibi'),
  ('ayarlar', 'Ayarlar'),
];

void main() {
  for (final (name, size) in [
    ('1536', const Size(1536, 864)),
    ('1280', const Size(1280, 720)),
  ]) {
    testWidgets('every sidebar section renders at $name', (t) async {
      await mount(t, size);
      for (final (key, label) in sections) {
        // Some sections poll or animate forever, so settle for a bounded time.
        await t.ensureVisible(find.text(label).first);
        await t.tap(find.text(label).first);
        for (var i = 0; i < 6; i++) {
          await t.pump(const Duration(milliseconds: 250));
        }
        expect(t.takeException(), isNull, reason: '$label at $name');
        await shot(t, 'section-$name-$key');
      }
    });
  }
}
