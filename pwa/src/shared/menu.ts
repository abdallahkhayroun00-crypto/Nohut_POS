// Menü & Kampanya Yönetimi — the one section shared by both apps (§22.3).
// Edits are versioned commands executed by the Windows POS; historical order
// prices never change (§19.3).
import { newRequestId } from './commands';
import { asCents, categoryLabel, hhmm, money, searchProducts } from './format';
import type { Product } from './model';
import { type Ctx, actionButton, closeSheet, empty, h, ic, openSheet, report, section } from './ui';

const qrLabels = { published: 'Yayında', pending: 'Yayın bekliyor', failed: 'Yayın hatası', unknown: 'Bilinmiyor' } as const;

export function menuScreen(ctx: Ctx, state: { q: string }): HTMLElement {
  const products = ctx.snap.staff.localMenu;
  const hits = searchProducts(products, state.q);
  const groups = new Map<string, Product[]>();
  for (const p of hits) groups.set(p.category, [...(groups.get(p.category) ?? []), p]);
  const status = ctx.snap.menuStatus;
  const search = h('input', {
    type: 'search',
    placeholder: 'Menüde ara…',
    value: state.q,
    'aria-label': 'Menüde ara',
    oninput: (e: Event) => {
      state.q = (e.target as HTMLInputElement).value;
      ctx.rerender();
      const el = document.querySelector<HTMLInputElement>('.menu-search input');
      el?.focus();
      el?.setSelectionRange(state.q.length, state.q.length);
    },
  });
  return h(
    'div',
    {},
    h(
      'div',
      { class: 'card row-card' },
      ic('qr', 22),
      h(
        'div',
        { class: 'grow' },
        h('strong', {}, 'QR menü'),
        h('small', {}, status ? `${qrLabels[status.qrState]}${status.qrVersion ? ` · sürüm ${status.qrVersion}` : ''}${status.qrPublishedAt ? ` · ${hhmm(status.qrPublishedAt)}` : ''}` : 'Durum kasadan henüz gelmedi'),
      ),
      actionButton(ctx, {
        label: 'Yayınla',
        op: 'menu.qr.publish',
        onclick: async () => report(await ctx.send('menu', { type: 'qr_publish', requestId: newRequestId(), expectedRevision: ctx.snap.revision })),
      }),
    ),
    h('div', { class: 'search menu-search' }, ic('search', 18), search),
    ...[...groups.entries()].map(([cat, items]) =>
      section(
        categoryLabel(cat),
        h(
          'div',
          { class: 'list' },
          ...items.map((p) =>
            h(
              'button',
              { type: 'button', class: 'list-row', onclick: () => openProduct(ctx, p) },
              h('span', { class: 'grow' }, h('strong', {}, p.name), p.description?.tr ? h('small', {}, p.description.tr) : null),
              p.soldOut || p.active === false ? h('span', { class: 'tag bad' }, p.active === false ? 'Pasif' : 'Tükendi') : h('span', { class: 'tag good' }, 'Satışta'),
              h('span', { class: 'amt' }, money(asCents(p.price))),
            ),
          ),
        ),
      ),
    ),
    hits.length ? null : empty('Ürün bulunamadı.', 'search'),
  );
}

function openProduct(ctx: Ctx, p: Product) {
  const price = h('input', { inputmode: 'decimal', value: String(p.price).replace('.', ','), 'aria-label': 'Yeni fiyat (₺)' }) as HTMLInputElement;
  const isCampaign = p.category === 'campaign';
  const send = async (payload: object) => {
    closeSheet();
    report(await ctx.send('menu', { requestId: newRequestId(), expectedRevision: ctx.snap.revision, productId: p.id, ...payload }));
  };
  openSheet(
    p.name,
    h(
      'div',
      { class: 'form' },
      h('div', { class: 'due-line' }, 'Güncel fiyat', h('strong', {}, money(asCents(p.price)))),
      ctx.can(isCampaign ? 'menu.campaign.edit' : 'menu.price.edit')
        ? h('div', { class: 'field' }, h('label', {}, 'Yeni fiyat (₺)'), price, h('p', { class: 'muted small' }, 'Eski siparişlerin fiyatı değişmez; yeni sürüm oluşturulur.'))
        : h('p', { class: 'muted' }, 'Fiyat değiştirme yetkiniz yok.'),
    ),
    h(
      'div',
      { class: 'action-grid' },
      actionButton(ctx, {
        label: p.soldOut ? 'Satışa Aç' : 'Tükendi Yap',
        op: 'menu.stock.toggle',
        icon: 'stock',
        onclick: () => send({ type: 'stock_update', soldOut: !p.soldOut }),
      }),
      actionButton(ctx, {
        label: 'Fiyatı Kaydet',
        op: isCampaign ? 'menu.campaign.edit' : 'menu.price.edit',
        icon: 'price',
        primary: true,
        onclick: () => {
          const cents = Math.round(Number(price.value.replace(',', '.')) * 100);
          if (!Number.isFinite(cents) || cents <= 0) return report({ state: 'rejected', message: 'Geçerli bir fiyat girin' });
          if (!confirm(`${p.name}: ${money(asCents(p.price))} → ${money(cents)} olsun mu?`)) return;
          void send({ type: 'menu_update', field: 'price', beforeCents: asCents(p.price), afterCents: cents });
        },
      }),
    ),
  );
}
