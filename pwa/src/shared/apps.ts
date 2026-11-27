// Two separate applications, the same three shared sections (spec §20.1–2).
export type AppId = 'personel' | 'yonetici';

export interface Section {
  id: 'home' | 'menu' | 'sync' | 'backup';
  title: string;
  items: string[];
}

export const sharedSections: Section[] = [
  {
    id: 'menu',
    title: 'Menü & Kampanya Yönetimi',
    items: ['Ürünler', 'Fiyat güncelleme', 'Kategoriler', 'Kampanyalar', 'Stok / satış durumu', 'QR menü yayın durumu'],
  },
  {
    id: 'sync',
    title: 'Bulut & Senkronizasyon',
    items: ['Bağlantı Durumu', 'İlk Senkronizasyon', 'Şimdi Senkronize Et', 'Otomatik Senkronizasyon', 'Son Başarılı Senkronizasyon', 'Bekleyen İşlemler', 'Senkronizasyon Geçmişi', 'Depolama Kullanımı', 'Hata Tanılama ve Tekrar Dene'],
  },
  {
    id: 'backup',
    title: 'Yedekleme & Geri Yükleme',
    items: ['Şimdi Yedekle', 'Otomatik Yedekleme', 'Yedekleme Geçmişi', 'Yedek Doğrulama', 'Geri yükleme durumu'],
  },
];

export const apps: Record<AppId, { name: string; home: Section }> = {
  personel: {
    name: 'Nohut Personel',
    home: { id: 'home', title: 'Masalar', items: ['Masalar', 'Sipariş Al', 'Gel-Al', 'Online Siparişler', 'Ödemeler', 'Mesailerim'] },
  },
  yonetici: {
    name: 'Nohut Yönetici',
    home: { id: 'home', title: 'Genel Bakış', items: ['Genel Bakış', 'Satışlar & Yoğunluk', 'Finans', 'Raporlar', 'Personel', 'Kullanıcılar & Yetkiler'] },
  },
};

export function sectionsFor(app: AppId): Section[] {
  return [apps[app].home, ...sharedSections];
}
