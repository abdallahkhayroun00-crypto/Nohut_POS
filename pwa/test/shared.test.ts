// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest';
import { addDays, delta, inRange, peakHours, periodRange, previousRange, series, sum, toCsv } from '../src/shared/analytics';
import { probe, readConfig } from '../src/shared/cloud';
import { cartTotalCents, changeCents, orderAction, orderRequest, paymentAction, paymentProblem } from '../src/shared/commands';
import { asCents, money, normalize, orderLines, searchProducts } from '../src/shared/format';
import { freshness } from '../src/shared/freshness';
import { iconNames } from '../src/shared/icons';
import type { DailySales, Order, Product } from '../src/shared/model';
import { canPerform, findOperation, operations, operationsFor, windowsOnlySections } from '../src/shared/permissions';
import { parseRoute } from '../src/shared/runtime';
import { personel } from '../src/personel/app';
import { yonetici } from '../src/yonetici/app';
import { fixtureSource } from '../src/fixtures/source';
import type { Ctx } from '../src/shared/ui';
import { actionButton, makeCan } from '../src/shared/ui';

const ctxOf = async (app: 'personel' | 'yonetici'): Promise<Ctx> => {
  const s = await fixtureSource(app).load();
  if (s.kind !== 'ready') throw new Error('fixture');
  const client = app;
  return {
    snap: s.snapshot,
    client,
    now: new Date(),
    fixtures: true,
    can: makeCan(s.snapshot, client),
    go: () => undefined,
    rerender: () => undefined,
    send: async () => ({ state: 'unavailable', message: '' }),
  };
};

describe('owner correction §22: Bulut and Yedek are Windows-only', () => {
  it('catalogue marks every sync/backup operation windows-only', () => {
    expect([...windowsOnlySections].sort()).toEqual(['backup', 'sync']);
    for (const op of operations.filter((o) => o.section === 'sync' || o.section === 'backup')) expect(op.clients).toEqual(['windows']);
  });
  it('remote clients cannot perform them, even the owner with a stored grant', () => {
    for (const id of ['sync.manual', 'sync.initial.start', 'backup.manual', 'backup.restore', 'backup.verify']) {
      for (const client of ['personel', 'yonetici'] as const) {
        expect(canPerform(id, new Set([id]), { isOwner: true }, client)).toBe(false);
      }
    }
    expect(canPerform('backup.manual', new Set(['backup.manual']), { isOwner: false }, 'windows')).toBe(true);
  });
  it('no route or nav entry for sync/backup in either app', async () => {
    for (const [app, def] of [['personel', personel], ['yonetici', yonetici]] as const) {
      const ctx = await ctxOf(app);
      const ids = def.nav(ctx).map((n) => n.id);
      expect(ids.join(' ')).not.toMatch(/bulut|yedek|sync|backup/i);
      for (const r of ['bulut', 'yedek', 'sync', 'backup', 'senkronizasyon', 'yedekleme']) expect(def.screen(r, new URLSearchParams(), ctx)).toBeNull();
      for (const id of [...ids, 'daha']) {
        const screen = def.screen(id, new URLSearchParams(), ctx)!;
        expect(screen.body.textContent ?? '').not.toMatch(/Şimdi Yedekle|Şimdi Senkronize Et|Geri Yükle|İlk Senkronizasyon/);
      }
    }
  });
});

describe('navigation (§22.2)', () => {
  it('Personel: Masalar first; Yönetici: Genel Bakış first', async () => {
    expect(personel.home).toBe('masalar');
    expect(yonetici.home).toBe('genel');
    expect(personel.nav(await ctxOf('personel')).map((n) => n.label)).toEqual(['Masalar', 'Siparişler', 'Online', 'Mesailerim', 'Daha Fazla']);
    expect(yonetici.nav(await ctxOf('yonetici')).map((n) => n.label)).toEqual(['Genel Bakış', 'Satışlar', 'Finans', 'Personel', 'Daha Fazla']);
  });
  it('every screen renders and every icon exists', async () => {
    const routes = {
      personel: ['masalar', 'siparisler', 'siparis', 'online', 'mesai', 'daha', 'maas', 'menu', 'fisler', 'bildirimler', 'profil'],
      yonetici: ['genel', 'satislar', 'finans', 'personel', 'daha', 'raporlar', 'hesaplar', 'menu', 'entegrasyonlar', 'kullanicilar', 'gecmis', 'profil'],
    };
    for (const [app, def] of [['personel', personel], ['yonetici', yonetici]] as const) {
      const ctx = await ctxOf(app);
      for (const n of def.nav(ctx)) expect(iconNames).toContain(n.icon);
      for (const r of routes[app]) {
        const s = def.screen(r, new URLSearchParams(r === 'siparis' ? 'table=2' : ''), ctx);
        expect(s, `${app}/${r}`).not.toBeNull();
        expect(s!.body.childNodes.length).toBeGreaterThan(0);
      }
    }
  });
  it('Menü & Kampanya is reachable in both apps', async () => {
    expect(personel.screen('menu', new URLSearchParams(), await ctxOf('personel'))!.title).toBe('Menü & Kampanya');
    expect(yonetici.screen('menu', new URLSearchParams(), await ctxOf('yonetici'))!.title).toBe('Menü & Kampanya');
  });
  it('parses hash routes with parameters', () => {
    const r = parseRoute('#/siparis?table=3&order=12', 'masalar');
    expect(r.route).toBe('siparis');
    expect(r.params.get('table')).toBe('3');
    expect(parseRoute('', 'genel').route).toBe('genel');
  });
});

describe('permissions catalogue', () => {
  it('unknown operations deny', () => {
    expect(canPerform('menu.delete_everything', new Set(['menu.delete_everything']), { isOwner: true }, 'yonetici')).toBe(false);
  });
  it('owner-only ignores stored grants for non-owners', () => {
    expect(canPerform('users.manage', new Set(['users.manage']), { isOwner: false }, 'yonetici')).toBe(false);
    expect(canPerform('users.manage', new Set(), { isOwner: true }, 'yonetici')).toBe(true);
  });
  it('manager-only operations are not available in Personel', () => {
    expect(canPerform('finance.view', new Set(['finance.view']), { isOwner: false }, 'personel')).toBe(false);
    expect(canPerform('finance.view', new Set(['finance.view']), { isOwner: false }, 'yonetici')).toBe(true);
  });
  it('operational grants follow the user', () => {
    expect(canPerform('payments.take', new Set(), { isOwner: false }, 'personel')).toBe(false);
    expect(canPerform('payments.take', new Set(['payments.take']), { isOwner: false }, 'personel')).toBe(true);
    expect(findOperation('payments.refund')!.sensitivity).toBe('elevated');
    expect(operationsFor('menu', 'personel').map((o) => o.id)).toContain('menu.price.edit');
  });
});

const prod = (id: number, price: number, category = 'wrap', extra: Partial<Product> = {}): Product => ({ id, name: `Ürün ${id}`, price, category, ...extra });

describe('order and payment commands use the Windows payload shapes', () => {
  const ctx = { requestId: 'r1', expectedRevision: 7, staffId: 2 };
  it('orderRequest mirrors the Android request', () => {
    const cart = [{ product: prod(1, 150), qty: 2, note: 'az acılı', removed: ['Soğan'] }];
    const r = orderRequest({ source: 'Masa', table: 3, orderId: 9 }, cart, ctx);
    expect(r).toMatchObject({ requestId: 'r1', expectedRevision: 7, staffId: 2, source: 'Masa', table: 3, orderId: 9 });
    expect(r.lines[0]).toEqual({ productId: 1, qty: 2, expectedPriceCents: 15000, note: 'az acılı', removed: ['Soğan'] });
    const g = orderRequest({ source: 'Gel-Al', pickupChannel: 'Telefon', customer: { name: 'A', phone: '1', time: '13:00' } }, cart, ctx);
    expect(g.table).toBeNull();
    expect(g).toMatchObject({ pickupChannel: 'Telefon', customer: { name: 'A', time: '13:00' } });
    expect(() => orderRequest({ source: 'Masa', table: 1 }, [], ctx)).toThrow('Sepet boş');
    expect(cartTotalCents(cart)).toBe(30000);
  });
  it('payment actions match pay / payMixed / payProducts handlers', () => {
    expect(paymentAction(5, { method: 'Nakit', amountCents: 1000, receivedCents: 2000 }, ctx, { printReceipt: true })).toMatchObject({
      action: 'pay', method: 'Nakit', amountCents: 1000, receivedCents: 2000, printReceipt: true, confirmed: true, orderId: 5,
    });
    expect(paymentAction(5, { method: 'Karışık', amountCents: 1000, cashCents: 400 }, ctx, { printReceipt: false })).toMatchObject({
      action: 'payMixed', amountCents: 1000, cashCents: 400, printReceipt: false,
    });
    expect(paymentAction(5, { method: 'Kart', amountCents: 300 }, ctx, { printReceipt: false, shares: { a1: 1 } })).toMatchObject({
      action: 'payProducts', method: 'Kart', shares: { a1: 1 },
    });
    expect(orderAction(5, 'move', ctx, { table: 4 })).toMatchObject({ action: 'move', table: 4, orderId: 5 });
  });
  it('validates payments and calculates change for display only', () => {
    expect(paymentProblem({ method: 'Nakit', amountCents: 0 }, 1000)).toBe('Tutar girin');
    expect(paymentProblem({ method: 'Kart', amountCents: 1200 }, 1000)).toBe('Tutar kalan bakiyeden fazla');
    expect(paymentProblem({ method: 'Nakit', amountCents: 1000, receivedCents: 500 }, 1000)).toBe('Alınan nakit tutardan az');
    expect(paymentProblem({ method: 'Karışık', amountCents: 1000, cashCents: 1000 }, 1000)).toMatch(/Nakit kısmı/);
    expect(paymentProblem({ method: 'Karışık', amountCents: 1000, cashCents: 300 }, 1000)).toBeNull();
    expect(changeCents({ method: 'Nakit', amountCents: 4700, receivedCents: 5000 })).toBe(300);
    expect(changeCents({ method: 'Kart', amountCents: 4700, receivedCents: 5000 })).toBe(0);
  });
});

describe('formatting and search', () => {
  it('money and cents', () => {
    expect(asCents(12.5)).toBe(1250);
    expect(money(123456)).toMatch(/1\.234,56 ₺/);
  });
  it('Turkish-aware search, campaigns first, inactive hidden', () => {
    const list = [prod(1, 1, 'wrap', { name: 'Falafel Dürüm' }), prod(2, 1, 'campaign', { name: 'Dürüm Menü' }), prod(3, 1, 'wrap', { name: 'Dürüm Eski', active: false })];
    expect(searchProducts(list, 'durum').map((p) => p.id)).toEqual([2, 1]);
    expect(normalize('IĞDIR Şiş')).toBe('igdir sis');
  });
  it('hides voided and correction lines', () => {
    const o = { batches: [{ lines: [{ name: 'a', qty: 1, price: 1 }, { name: 'b', qty: 1, price: 1, voided: true }, { name: 'c', qty: 1, price: 1, correction: true }] }] } as unknown as Order;
    expect(orderLines(o).map((l) => l.name)).toEqual(['a']);
  });
});

const row = (day: string, gross: number, extra: Partial<DailySales> = {}): DailySales => ({
  day, grossCents: gross, cashCents: gross / 2, cardCents: gross / 4, platformCents: gross / 4, refundCents: 0, orderCount: 10, masaCount: 5, gelalCount: 3, onlineCount: 2, ...extra,
});

describe('sales analytics over Windows-computed daily rows', () => {
  it('period ranges (Monday weeks, calendar months, years)', () => {
    expect(periodRange('week', '2026-11-27')).toEqual(['2026-11-23', '2026-11-29']);
    expect(periodRange('month', '2026-02-10')).toEqual(['2026-02-01', '2026-02-28']);
    expect(periodRange('year', '2026-11-27')).toEqual(['2026-01-01', '2026-12-31']);
    expect(previousRange(['2026-11-23', '2026-11-29'])).toEqual(['2026-11-16', '2026-11-22']);
    expect(addDays('2026-12-31', 1)).toBe('2027-01-01');
  });
  it('gross sales and collections are kept apart', () => {
    const t = sum([row('2026-11-26', 10000), row('2026-11-27', 20000)]);
    expect(t.grossCents).toBe(30000);
    expect(t.collectedCents).toBe(t.cashCents + t.cardCents);
    expect(t.collectedCents).not.toBe(t.grossCents);
    expect(t.avgCents).toBe(1500);
  });
  it('comparisons and series', () => {
    expect(delta(120, 100)).toBe(20);
    expect(delta(5, 0)).toBeNull();
    const rows = [row('2026-11-01', 100), row('2026-11-03', 300)];
    expect(inRange(rows, ['2026-11-02', '2026-11-30']).length).toBe(1);
    expect(series(rows, ['2026-11-01', '2026-11-03']).map((s) => s.value)).toEqual([100, 0, 300]);
    expect(series(rows, ['2026-01-01', '2026-12-31']).length).toBe(12);
    expect(peakHours([0, 5, 9, 9, 1], 2)).toEqual([2, 3]);
  });
  it('CSV export uses Turkish decimals and a BOM', () => {
    const csv = toCsv([row('2026-11-27', 12345)]);
    expect(csv.startsWith('﻿Tarih;')).toBe(true);
    expect(csv).toContain('2026-11-27;123,45;');
  });
});

describe('freshness never calls stale data current', () => {
  const now = new Date('2026-11-27T12:00:00Z');
  it('levels', () => {
    expect(freshness(null, now, true).level).toBe('none');
    expect(freshness('2026-11-27T11:59:00Z', now, true).label).toBe('Güncel');
    expect(freshness('2026-11-27T11:30:00Z', now, true).label).toBe('30 dk önce · 14:30');
    expect(freshness('2026-11-27T09:05:00Z', now, false).label).toBe('Kasa Çevrimdışı — Son veri: 12:05');
  });
});

describe('cloud config only accepts the publishable key', () => {
  it('rejects missing or malformed config', () => {
    expect(readConfig({})).toBeNull();
    expect(readConfig({ VITE_SUPABASE_URL: 'http://x.supabase.co', VITE_SUPABASE_PUBLISHABLE_KEY: 'x'.repeat(30) })).toBeNull();
  });
  it('probe reports reachability honestly', async () => {
    const cfg = { url: 'https://abc.supabase.co', publishableKey: 'k'.repeat(30) };
    expect(await probe(cfg, (async () => new Response('', { status: 200 })) as typeof fetch)).toBe('reachable');
    expect(await probe(cfg, (async () => { throw new Error('down'); }) as typeof fetch)).toBe('unreachable');
    expect(await probe(null)).toBe('unconfigured');
  });
});

describe('fixtures never claim success', () => {
  it('fixture commands are not confirmed', async () => {
    const r = await fixtureSource('personel').commands.send('order', {});
    expect(r.state).not.toBe('confirmed');
  });
});

describe('Windows offline: authority-dependent actions are disabled (§22.4)', () => {
  it('disables with "Kasa çevrimdışı" and never runs the handler', async () => {
    const ctx = await ctxOf('personel');
    ctx.snap.posOnline = false;
    let ran = false;
    const b = actionButton(ctx, { label: 'Ödeme Al', op: 'payments.take', onclick: () => (ran = true) }) as HTMLButtonElement;
    expect(b.disabled).toBe(true);
    expect(b.textContent).toContain('Kasa çevrimdışı');
    b.click();
    expect(ran).toBe(false);
  });
  it('disables without the grant even when Windows is online', async () => {
    const ctx = await ctxOf('personel');
    const b = actionButton(ctx, { label: 'İade', op: 'payments.refund', onclick: () => undefined }) as HTMLButtonElement;
    expect(b.disabled).toBe(true);
    expect(b.textContent).toContain('yetkiniz yok');
  });
  it('the composer send button is disabled while Windows is offline', async () => {
    const ctx = await ctxOf('personel');
    ctx.snap.posOnline = false;
    const s = personel.screen('siparis', new URLSearchParams('table=2'), ctx)!;
    const send = [...s.body.querySelectorAll('button')].find((x) => x.textContent?.includes('Kasa çevrimdışı')) as HTMLButtonElement;
    expect(send?.disabled).toBe(true);
  });
});
