// SYNTHETIC development fixtures — ÖRNEK VERİ. Never part of a production
// bundle (only reachable when `import.meta.env.MODE === 'fixtures'`; CI greps
// the production build for the fixture order numbers TG-90412 / YS-55120).
// Names, amounts and orders are invented; they are not restaurant data.

import type { CommandChannel } from '../shared/commands';
import type { DailySales, Order, Product, Snapshot } from '../shared/model';
import type { DataSource } from '../shared/source';

const NOW = new Date();
const iso = (minsAgo: number) => new Date(NOW.getTime() - minsAgo * 60000).toISOString();
const DAY = new Date(NOW.getTime() + 3 * 3600000).toISOString().slice(0, 10);

const menu: Product[] = [
  { id: 1000000001, name: 'Falafel Dürüm + Ayran', category: 'campaign', price: 185, description: { tr: 'Falafel Dürüm + Ayran' }, campaignId: 'c1' },
  { id: 1000000002, name: 'İkili Tabak Menü', category: 'campaign', price: 390, description: { tr: '2 Falafel Tabak + 2 İçecek' }, campaignId: 'c2' },
  { id: 11, name: 'Falafel Dürüm', category: 'wrap', price: 150, ingredients: ['Turşu', 'Domates', 'Soğan', 'Acı sos'] },
  { id: 12, name: 'Humuslu Falafel Dürüm', category: 'wrap', price: 170, ingredients: ['Turşu', 'Domates', 'Maydanoz'] },
  { id: 13, name: 'Sebzeli Dürüm', category: 'wrap', price: 140, ingredients: ['Mantar', 'Biber', 'Soğan'] },
  { id: 21, name: 'Falafel Tabak', category: 'plate', price: 210, ingredients: ['Humus', 'Salata', 'Turşu'] },
  { id: 22, name: 'Humus Tabak', category: 'plate', price: 160 },
  { id: 31, name: 'Patates Kızartması', category: 'side', price: 80 },
  { id: 32, name: 'Falafel (6 adet)', category: 'side', price: 95, soldOut: true },
  { id: 2000000000, name: 'Ek Lavaş', category: 'side', price: 10 },
  { id: 41, name: 'Ayran', category: 'drink', price: 35 },
  { id: 42, name: 'Limonata', category: 'drink', price: 55 },
  { id: 43, name: 'Su', category: 'drink', price: 15 },
  { id: 51, name: 'Baklava (2 dilim)', category: 'dessert', price: 90 },
];

const line = (p: Product, qty: number, key: string, extra: Partial<Order['batches'][0]['lines'][0]> = {}) => ({
  key,
  productId: p.id,
  name: p.name,
  qty,
  price: p.price,
  ...extra,
});
const P = (id: number) => menu.find((p) => p.id === id)!;

const orders: Order[] = [
  {
    id: 501, dailyNumber: 14, source: 'Masa', table: 1, createdAt: iso(38), serviceStatus: 'Serviste',
    batches: [
      { id: 1, at: iso(38), staff: 'Deniz', lines: [line(P(11), 2, 'a1', { removed: ['Soğan'] }), line(P(41), 2, 'a2')] },
      { id: 2, at: iso(12), staff: 'Deniz', lines: [line(P(31), 1, 'a3'), line(P(2000000000), 2, 'a4')] },
    ],
    totalCents: 47000, paidCents: 0, dueCents: 47000, guestChecks: [],
  },
  {
    id: 502, dailyNumber: 15, source: 'Masa', table: 3, createdAt: iso(22), serviceStatus: 'Hazırlanıyor',
    batches: [{ id: 1, at: iso(22), staff: 'Ece', lines: [line(P(1000000002), 1, 'b1'), line(P(51), 1, 'b2', { note: 'Paket olsun' })] }],
    totalCents: 48000, paidCents: 20000, dueCents: 28000,
    guestChecks: [{ id: 1, name: 'Kişi 1', balanceCents: 8000 }, { id: 2, name: 'Kişi 2', balanceCents: 20000 }],
  },
  {
    id: 503, dailyNumber: 16, source: 'Masa', table: 4, createdAt: iso(55), serviceStatus: 'Serviste',
    batches: [{ id: 1, at: iso(55), staff: 'Deniz', lines: [line(P(21), 2, 'c1'), line(P(42), 2, 'c2')] }],
    totalCents: 53000, paidCents: 53000, dueCents: 0, guestChecks: [],
  },
  {
    id: 504, dailyNumber: 17, source: 'Gel-Al', createdAt: iso(9), serviceStatus: 'Hazırlanıyor',
    customer: { name: 'Örnek Müşteri', channel: 'Telefon', time: '13:30', phone: '0500 000 00 00' },
    batches: [{ id: 1, at: iso(9), staff: 'Ece', lines: [line(P(12), 3, 'd1', { removed: ['Turşu'] }), line(P(43), 3, 'd2')] }],
    totalCents: 55500, paidCents: 0, dueCents: 55500, guestChecks: [],
  },
  {
    id: 505, dailyNumber: 18, source: 'Gel-Al', createdAt: iso(4), serviceStatus: 'Yeni',
    customer: { name: 'Tezgah 2', channel: 'Tezgahtan', time: '13:15' },
    batches: [{ id: 1, at: iso(4), staff: 'Deniz', lines: [line(P(1000000001), 2, 'e1')] }],
    totalCents: 37000, paidCents: 37000, dueCents: 0, guestChecks: [],
  },
];

function days(n: number): DailySales[] {
  const out: DailySales[] = [];
  for (let i = n - 1; i >= 0; i--) {
    const d = new Date(`${DAY}T00:00:00Z`);
    d.setUTCDate(d.getUTCDate() - i);
    const wd = (d.getUTCDay() + 6) % 7;
    const base = 9000 + 2600 * Math.sin(i / 5) + (wd >= 4 ? 4200 : 0);
    const gross = Math.round(base * 100 * (i === 0 ? 0.55 : 1));
    const platform = Math.round(gross * 0.22);
    const cash = Math.round((gross - platform) * 0.38);
    const orderCount = Math.round(gross / 21000);
    out.push({
      day: d.toISOString().slice(0, 10), grossCents: gross, platformCents: platform, cashCents: cash,
      cardCents: gross - platform - cash, refundCents: i % 9 === 0 ? 8500 : 0, orderCount,
      masaCount: Math.round(orderCount * 0.48), gelalCount: Math.round(orderCount * 0.3),
      onlineCount: orderCount - Math.round(orderCount * 0.48) - Math.round(orderCount * 0.3),
    });
  }
  return out;
}

const hourly = Array.from({ length: 24 }, (_, h) => (h < 11 || h > 22 ? 0 : Math.round(3 + 9 * Math.exp(-((h - 13) ** 2) / 3) + 7 * Math.exp(-((h - 19.5) ** 2) / 2.5))));

function snapshot(app: 'personel' | 'yonetici'): Snapshot {
  const month = DAY.slice(0, 7);
  return {
    asOf: iso(0.5), revision: 4821, posOnline: true, pendingCommands: 0,
    session:
      app === 'personel'
        ? { name: 'Deniz', employeeId: 2, isOwner: false, grants: ['tables.view', 'orders.create', 'orders.move', 'orders.release', 'pickup.contact.view', 'payments.take', 'receipts.print', 'online.view', 'online.act', 'shifts.self', 'payroll.self.view', 'menu.view', 'menu.stock.toggle'] }
        : { name: 'Sahip', employeeId: null, isOwner: true, grants: [] },
    staff: {
      floorPlan: {}, // Windows default layout (same fallback as the POS)
      employees: [{ id: 1, name: 'Ece', active: true }, { id: 2, name: 'Deniz', active: true }, { id: 3, name: 'Mert', active: true }],
      localMenu: menu,
      orders,
      onlineOrders: [
        { platform: 'Trendyol Go', orderNumber: 'TG-90412', dailyNumber: 7, status: 'created', createdAt: iso(2), totalCents: 41000, paymentType: 'Online', customerNote: 'Zile basmayın lütfen', lines: [{ name: 'Falafel Dürüm', qty: 2, removed: ['Acı sos'] }, { name: 'Ayran', qty: 2 }] },
        { platform: 'Yemeksepeti', orderNumber: 'YS-55120', dailyNumber: 3, status: 'picking', createdAt: iso(14), totalCents: 21000, lines: [{ name: 'Falafel Tabak', qty: 1, extras: ['Ek humus'] }], kitchenPrintState: 'printed' },
        { platform: 'Migros Yemek', orderNumber: 'MY-1207', dailyNumber: 2, status: 'picking', createdAt: iso(19), totalCents: 16500, lines: [{ name: 'Humus Tabak', qty: 1 }], kitchenPrintState: 'failed' },
      ],
      staffNotices: [
        { id: 1, staff: 'Ece', action: 'Ek sipariş eklendi', table: 1, at: iso(12) },
        { id: 2, staff: 'Deniz', action: 'Masa 2 → Masa 4 taşındı', table: 4, at: iso(30) },
      ],
      platformWritable: { 'Trendyol Go': true },
    },
    shifts: [
      { employeeId: 2, employeeName: 'Deniz', start: iso(60 * 24 * 2 + 300), end: iso(60 * 24 * 2 - 180) },
      { employeeId: 2, employeeName: 'Deniz', start: iso(60 * 24 + 310), end: iso(60 * 24 - 170), corrected: true },
      { employeeId: 1, employeeName: 'Ece', start: iso(260) },
      { employeeId: 2, employeeName: 'Deniz', start: iso(205) },
    ],
    menuStatus: { qrState: 'published', qrVersion: '2026.11.27-1', qrPublishedAt: iso(300) },
    integrations: [
      { name: 'Trendyol Go by Uber Eats', state: 'Aktif', detail: 'Sipariş ve durum güncellemesi' },
      { name: 'Yemeksepeti', state: 'Salt Okunur', detail: 'Siparişler kasada görünür' },
      { name: 'Migros Yemek', state: 'Onay Bekliyor', detail: 'API erişimi bekleniyor' },
      { name: 'Google Business Profile', state: 'Aktif', detail: 'Yorumlar ve yanıtlar' },
    ],
    overview: {
      day: DAY, cashCents: 214000, cardCents: 386500, orderCount: 31,
      orders: orders.map((o) => ({ id: o.id, dailyNumber: o.dailyNumber, source: o.source, table: o.table, createdAt: o.createdAt, totalCents: o.totalCents, paidCents: o.paidCents, dueCents: o.dueCents, owner: o.batches[0]?.staff })),
      openAccounts: orders.filter((o) => o.dueCents > 0).map((o) => ({ id: o.id, dailyNumber: o.dailyNumber, source: o.source, table: o.table, createdAt: o.createdAt, totalCents: o.totalCents, paidCents: o.paidCents, dueCents: o.dueCents, owner: o.batches[0]?.staff })),
      online: [
        { orderNumber: 'TG-90412', source: 'Trendyol Go', status: 'created', createdAt: iso(2), totalCents: 41000 },
        { orderNumber: 'YS-55120', source: 'Yemeksepeti', status: 'picking', createdAt: iso(14), totalCents: 21000 },
        { orderNumber: 'MY-1207', source: 'Migros Yemek', status: 'picking', createdAt: iso(19), totalCents: 16500 },
      ],
      staff: [
        { name: 'Deniz', tableOrders: 11, pickupOrders: 6, ownedCents: 352000, items: 64, distinctTables: 5 },
        { name: 'Ece', tableOrders: 8, pickupOrders: 6, ownedCents: 271500, items: 49, distinctTables: 4 },
      ],
      hourly,
      reviews: [
        { reviewId: 'r1', rating: 5, createdAt: iso(600), comment: 'Dürüm çok taze, servis hızlıydı.' },
        { reviewId: 'r2', rating: 4, createdAt: iso(2000), comment: 'Lezzetli, ama paket biraz geç geldi.' },
      ],
      employees: [{ id: 1, name: 'Ece', role: 'Müdür', active: true }, { id: 2, name: 'Deniz', role: 'Personel', active: true }, { id: 3, name: 'Mert', role: 'Personel', active: true }, { id: 4, name: 'Selin', role: 'Personel', active: false }],
    },
    month: {
      month,
      summary: { localReceiptsCents: 18452000, onlineKnownNetCents: 3910000, onlineUnpricedGrossCents: 420000, materialsCents: 6230000, payrollCents: 5400000, fixedCents: 3850000, otherCents: 610000, totalExpensesCents: 16090000, estimateCents: 6272000 },
      platforms: [
        { source: 'Trendyol Go', grossCents: 3120000, deductionCents: 780000, netCents: 2340000, automaticOrders: 148 },
        { source: 'Yemeksepeti', grossCents: 1860000, deductionCents: 520000, netCents: 1340000, automaticOrders: 91 },
        { source: 'Migros Yemek', grossCents: 420000, deductionCents: 0, netCents: 230000, automaticOrders: 0 },
      ],
      materials: [
        { id: 1, date: `${month}-25`, title: 'Nohut 25 kg', market: 'Toptancı', totalCents: 187500, paymentMethod: 'Nakit' },
        { id: 2, date: `${month}-24`, title: 'Lavaş 400 adet', market: 'Fırın', totalCents: 160000, paymentMethod: 'Kart' },
        { id: 3, date: `${month}-22`, title: 'Ayçiçek yağı 18 L', market: 'Market', totalCents: 129000, paymentMethod: 'Kart' },
      ],
      weeklyPayroll: [
        { id: 1, employeeId: 2, employeeName: 'Deniz', weekStart: `${month}-17`, weekEnd: `${month}-23`, payType: 'hourly', rateCents: 15000, workedMinutes: 2580, bonusCents: 50000, advanceCents: 100000, grossCents: 695000, payableCents: 595000, paid: true },
        { id: 2, employeeId: 1, employeeName: 'Ece', weekStart: `${month}-17`, weekEnd: `${month}-23`, payType: 'weekly', rateCents: 650000, workedMinutes: 2700, bonusCents: 0, advanceCents: 0, grossCents: 650000, payableCents: 650000, paid: true },
        { id: 3, employeeId: 2, employeeName: 'Deniz', weekStart: `${month}-24`, weekEnd: `${month}-30`, payType: 'hourly', rateCents: 15000, workedMinutes: 1260, bonusCents: 0, advanceCents: 0, grossCents: 315000, payableCents: 315000, paid: false },
      ],
      monthlyFixed: [
        { id: 1, category: 'Kira', name: 'Dükkan kirası', dueDay: 5, amountCents: 2500000 },
        { id: 2, category: 'Fatura', name: 'Elektrik', dueDay: 15, amountCents: 620000 },
        { id: 3, category: 'Fatura', name: 'Doğalgaz', dueDay: 20, amountCents: 410000 },
        { id: 4, category: 'Fatura', name: 'İnternet', dueDay: 28, amountCents: 32000 },
      ],
      fixedPayments: [{ templateId: 1, month, paidAt: `${month}-05`, amountCents: 2500000 }, { templateId: 2, month, paidAt: `${month}-14`, amountCents: 620000 }],
      other: [{ id: 1, date: `${month}-21`, category: 'Temizlik', name: 'Deterjan ve peçete', amountCents: 84000 }],
    },
    sales: {
      daily: days(400),
      topProducts: [
        { name: 'Falafel Dürüm', category: 'wrap', qty: 412, grossCents: 6180000 },
        { name: 'Falafel Dürüm + Ayran', category: 'campaign', qty: 233, grossCents: 4310500 },
        { name: 'Falafel Tabak', category: 'plate', qty: 154, grossCents: 3234000 },
        { name: 'Humuslu Falafel Dürüm', category: 'wrap', qty: 131, grossCents: 2227000 },
        { name: 'Ayran', category: 'drink', qty: 388, grossCents: 1358000 },
        { name: 'Patates Kızartması', category: 'side', qty: 120, grossCents: 960000 },
        { name: 'Limonata', category: 'drink', qty: 96, grossCents: 528000 },
        { name: 'Baklava (2 dilim)', category: 'dessert', qty: 41, grossCents: 369000 },
      ],
      heatmap: Array.from({ length: 7 }, (_, d) => hourly.map((v) => Math.round(v * (d >= 4 ? 1.5 : 1) * (0.8 + ((d * 7) % 5) / 10)))),
      platforms: [
        { source: 'Trendyol Go', orders: 148, grossCents: 3120000 },
        { source: 'Yemeksepeti', orders: 91, grossCents: 1860000 },
        { source: 'Migros Yemek', orders: 22, grossCents: 420000 },
      ],
    },
    audit: [
      { at: iso(45), actor: 'Ece', action: 'Fiyat güncellendi', detail: 'Limonata 50 → 55 ₺' },
      { at: iso(130), actor: 'Sahip', action: 'Yetki verildi', detail: 'Ece · menu.product.edit' },
      { at: iso(300), actor: 'Deniz', action: 'Masa taşındı', detail: 'Masa 2 → Masa 4' },
    ],
    users: [
      { id: 1, name: 'Ece', role: 'Müdür', active: true, grants: ['orders.create', 'orders.edit', 'payments.take', 'payments.correct', 'menu.view', 'menu.product.edit', 'staff.view', 'shifts.manage'], devices: 2 },
      { id: 2, name: 'Deniz', role: 'Personel', active: true, grants: ['orders.create', 'payments.take', 'menu.view', 'shifts.self'], devices: 1 },
      { id: 4, name: 'Selin', role: 'Personel', active: false, grants: [], devices: 0 },
    ],
  };
}

/** Fixture commands never report success: they show the payload was valid
 *  and that nothing was executed. */
const fixtureChannel: CommandChannel = {
  async send(kind) {
    return { state: 'unavailable', message: `ÖRNEK VERİ: "${kind}" komutu doğrulandı ama gönderilmedi (kasa bağlantısı yok).` };
  },
};

export function fixtureSource(app: 'personel' | 'yonetici'): DataSource {
  return { commands: fixtureChannel, load: async () => ({ kind: 'ready', snapshot: snapshot(app), fixtures: true }) };
}
