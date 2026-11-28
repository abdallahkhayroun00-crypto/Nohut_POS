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

/// Ayarlar pages, reached from its own navigation.
const settingsPages = <(String, String)>[
  ('personel', 'Personel'),
  ('kullanicilar', 'Kullanıcılar & Güvenlik'),
  ('telefon', 'Telefon Bağlantısı'),
  ('yazici', 'Yazıcı & Fiş'),
  ('bildirim', 'Bildirimler & Sesler'),
  ('entegrasyon', 'Entegrasyonlar'),
  ('bulut', 'Bulut & Senkronizasyon'),
  ('yedek', 'Yedekleme & Geri Yükleme'),
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

  // Ayarlar has a long navigation; the 1280 layout lazily builds it, so the
  // pages are rendered at the main desktop size.
  for (final (name, size) in [('1536', const Size(1536, 864))]) {
    testWidgets('every Ayarlar page renders at $name', (t) async {
      await mount(t, size);
      await t.tap(find.text('Ayarlar').first);
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 250));
      }
      for (final (key, label) in settingsPages) {
        // The same label appears in the quick tiles; the nav entry is first.
        await t.ensureVisible(find.text(label).first);
        await t.tap(find.text(label).first);
        for (var i = 0; i < 6; i++) {
          await t.pump(const Duration(milliseconds: 250));
        }
        expect(t.takeException(), isNull, reason: '$label at $name');
        await shot(t, 'ayarlar-$name-$key');
      }
    });
  }

  // Windows Mesai and Maaş live in Finans, as tabs.
  for (final (name, size) in [
    ('1536', const Size(1536, 864)),
    ('1280', const Size(1280, 720)),
  ]) {
    testWidgets('every Finans tab renders at $name', (t) async {
      await mount(t, size);
      await t.tap(find.text('Finans').first);
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 250));
      }
      for (final (key, label) in const [
        ('maas', 'Haftalık Maaşlar'),
        ('malzeme', 'Günlük Malzeme'),
        ('sabit', 'Sabit Giderler'),
        ('diger', 'Diğer Giderler'),
      ]) {
        await t.tap(find.text(label).first);
        for (var i = 0; i < 6; i++) {
          await t.pump(const Duration(milliseconds: 250));
        }
        expect(t.takeException(), isNull, reason: '$label at $name');
        await shot(t, 'finans-$name-$key');
      }
    });
  }
}
