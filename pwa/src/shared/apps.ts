// Two separate applications, the same three shared sections (spec §20.1–2).
export type AppId = 'personel' | 'yonetici';

export interface Item {
  label: string;
  icon: string;
  hint: string;
}

export interface Section {
  id: 'home' | 'menu' | 'sync' | 'backup';
  title: string;
  tab: string;
  icon: string;
  subtitle: string;
  items: Item[];
}

export const sharedSections: Section[] = [
  {
    id: 'menu',
    title: 'Menü & Kampanya Yönetimi',
    tab: 'Menü',
    icon: 'menu',
    subtitle: 'Ürünler, fiyatlar ve QR menü yayını',
    items: [
      { label: 'Ürünler', icon: 'menu', hint: 'Ekle, düzenle, satıştan kaldır' },
      { label: 'Fiyat güncelleme', icon: 'price', hint: 'Eski siparişlerin fiyatı değişmez' },
      { label: 'Kategoriler', icon: 'category', hint: 'Menü düzeni' },
      { label: 'Kampanyalar', icon: 'campaign', hint: 'Menü ve indirim tanımları' },
      { label: 'Stok / satış durumu', icon: 'stock', hint: 'Tükendi / satışta' },
      { label: 'QR menü yayını', icon: 'qr', hint: 'Yayınlanan sürüm ve durum' },
    ],
  },
  {
    id: 'sync',
    title: 'Bulut & Senkronizasyon',
    tab: 'Bulut',
    icon: 'cloud',
    subtitle: 'Kasa ile bulut arasındaki veri akışı',
    items: [
      { label: 'Bağlantı Durumu', icon: 'cloud', hint: 'Bulut erişimi' },
      { label: 'İlk Senkronizasyon', icon: 'sync', hint: 'Yalnız sahip başlatır' },
      { label: 'Şimdi Senkronize Et', icon: 'sync', hint: 'Bekleyenleri hemen gönder' },
      { label: 'Otomatik Senkronizasyon', icon: 'auto', hint: 'Her değişiklikten sonra' },
      { label: 'Son Başarılı Senkronizasyon', icon: 'check', hint: 'Zaman ve revizyon' },
      { label: 'Bekleyen İşlemler', icon: 'queue', hint: 'Gönderilmeyi bekleyenler' },
      { label: 'Senkronizasyon Geçmişi', icon: 'history', hint: 'Önceki çalışmalar' },
      { label: 'Depolama Kullanımı', icon: 'storage', hint: 'Ücretsiz kota ölçümü' },
      { label: 'Hata Tanılama ve Tekrar Dene', icon: 'alert', hint: 'Sorunları gör, yeniden dene' },
    ],
  },
  {
    id: 'backup',
    title: 'Yedekleme & Geri Yükleme',
    tab: 'Yedek',
    icon: 'backup',
    subtitle: 'Şifreli yedekler · anahtar sizde',
    items: [
      { label: 'Şimdi Yedekle', icon: 'backup', hint: 'Kasada şifreli yedek' },
      { label: 'Otomatik Yedekleme', icon: 'auto', hint: 'Günde bir kez' },
      { label: 'Yedekleme Geçmişi', icon: 'history', hint: 'Tarih, boyut, durum' },
      { label: 'Yedek Doğrulama', icon: 'verify', hint: 'Şifre çözme ve bütünlük' },
      { label: 'Geri yükleme durumu', icon: 'restore', hint: 'Yalnız sahip · kasada onay' },
    ],
  },
];

export const apps: Record<AppId, { name: string; role: string; home: Section }> = {
  personel: {
    name: 'Nohut Personel',
    role: 'Personel',
    home: {
      id: 'home',
      title: 'Masalar',
      tab: 'Masalar',
      icon: 'table',
      subtitle: 'Salon, siparişler ve ödemeler',
      items: [
        { label: 'Masalar', icon: 'table', hint: 'Masa 1–5 durumu' },
        { label: 'Sipariş Al', icon: 'order', hint: 'Ek sipariş, notlar' },
        { label: 'Gel-Al', icon: 'pickup', hint: 'Teslim saati' },
        { label: 'Online Siparişler', icon: 'online', hint: 'Trendyol Go' },
        { label: 'Ödemeler', icon: 'payment', hint: 'Nakit, kart, bölme' },
        { label: 'Mesailerim', icon: 'clock', hint: 'Kendi mesai ve ücretim' },
      ],
    },
  },
  yonetici: {
    name: 'Nohut Yönetici',
    role: 'Yönetici',
    home: {
      id: 'home',
      title: 'Genel Bakış',
      tab: 'Genel',
      icon: 'dashboard',
      subtitle: 'Satış, finans ve ekip',
      items: [
        { label: 'Genel Bakış', icon: 'dashboard', hint: 'Bugünün satışı ve tahsilat' },
        { label: 'Satışlar & Yoğunluk', icon: 'chart', hint: 'Saat ve gün dağılımı' },
        { label: 'Finans', icon: 'finance', hint: 'Giderler, maaşlar' },
        { label: 'Raporlar', icon: 'report', hint: 'Günlük, aylık, PDF' },
        { label: 'Personel', icon: 'people', hint: 'Mesai ve ücretler' },
        { label: 'Kullanıcılar & Yetkiler', icon: 'shield', hint: 'İşlem bazında yetki' },
      ],
    },
  },
};

export function sectionsFor(app: AppId): Section[] {
  return [apps[app].home, ...sharedSections];
}

/** Setup steps shown until the cloud path is fully live (honest status). */
export type StepState = 'done' | 'waiting' | 'later';

export interface SetupStep {
  title: string;
  detail: string;
  state: StepState;
}

export function setupSteps(cloudReachable: boolean): SetupStep[] {
  return [
    {
      title: 'Bulut bağlantısı',
      detail: cloudReachable ? 'Supabase projesine erişiliyor.' : 'Bulut projesine şu an erişilemiyor.',
      state: cloudReachable ? 'done' : 'waiting',
    },
    {
      title: 'İlk Senkronizasyon',
      detail: 'Sahip, kasadan “İlk Senkronizasyonu Başlat” ile geçmiş verileri doğrulayarak aktarır.',
      state: 'waiting',
    },
    {
      title: 'Hesabınızla giriş',
      detail: 'Kullanıcı adı, şifre ve güvenilir cihaz PIN’i ile giriş açılacak.',
      state: 'later',
    },
  ];
}
