/// Shared navigation contract for Windows and the owner Android application.
const managementSections = <(String, String)>[
  ('dashboard', 'Genel Bakış'),
  ('tables', 'Masalar & Siparişler'),
  ('online', 'Online Siparişler'),
  ('reviews', 'Geri Bildirimler'),
  ('google', 'Google İşletme Profili'),
  ('qr-menu', 'QR Menü Yönetimi'),
  ('open-accounts', 'Açık Hesaplar'),
  ('payments', 'Kasa & Ödemeler'),
  ('reports', 'Raporlar'),
  ('finance', 'Finans'),
  ('market-prices', 'Market Fiyat Takibi'),
  ('settings', 'Ayarlar'),
];
/// Legacy only: installs paired before owner accounts existed identified the
/// owner profile by this exact name. Never displayed; the owner's name always
/// comes from the Windows employee profile linked to the owner account.
const legacyManagementOwnerName = 'Ömer Yılmaz';
