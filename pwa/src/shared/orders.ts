// Order account, payment, table transfer and the Sipariş Al composer.
// Every write is a command; the UI reports only what the channel confirms.
import {
  type CartLine,
  type PayMethod,
  cartTotalCents,
  changeCents,
  newRequestId,
  orderAction,
  orderRequest,
  type OrderTarget,
  paymentAction,
  paymentProblem,
} from './commands';
import { asCents, categoryLabel, duration, hhmm, minutesBetween, money, orderLabel, orderLines, searchProducts } from './format';
import type { Order, Product } from './model';
import { type Ctx, actionButton, closeSheet, h, ic, openSheet, report, segmented } from './ui';

function cmdCtx(ctx: Ctx) {
  return { requestId: newRequestId(), expectedRevision: ctx.snap.revision, staffId: ctx.snap.session.employeeId };
}

function parseTl(v: string): number {
  const n = Number(v.replace(/\./g, '').replace(',', '.'));
  return Number.isFinite(n) ? Math.round(n * 100) : NaN;
}

const tlInput = (value: number) => (value / 100).toFixed(2).replace('.', ',');

export function lineRows(order: Order): HTMLElement {
  return h(
    'div',
    { class: 'lines' },
    ...order.batches.map((b, i) =>
      h(
        'div',
        { class: 'batch' },
        h('div', { class: 'batch-head' }, i === 0 ? 'İlk sipariş' : `Ek sipariş ${i}`, ' · ', hhmm(b.at), b.staff ? ` · ${b.staff}` : ''),
        ...b.lines
          .filter((l) => !l.voided && !l.correction)
          .map((l) =>
            h(
              'div',
              { class: 'line' },
              h('span', { class: 'qty' }, `${l.qty}×`),
              h(
                'span',
                { class: 'name' },
                l.name,
                l.removed?.length ? h('small', { class: 'mod' }, `− ${l.removed.join(', ')}`) : null,
                l.note ? h('small', { class: 'note-line' }, l.note) : null,
              ),
              h('span', { class: 'amt' }, money(l.qty * asCents(l.price))),
            ),
          ),
      ),
    ),
  );
}

export function totals(order: Order): HTMLElement {
  return h(
    'div',
    { class: 'totals' },
    h('div', {}, h('span', {}, 'Toplam'), h('strong', {}, money(order.totalCents))),
    h('div', {}, h('span', {}, 'Ödenen'), h('strong', {}, money(order.paidCents))),
    h('div', { class: order.dueCents > 0 ? 'due' : 'paid' }, h('span', {}, 'Kalan'), h('strong', {}, money(order.dueCents))),
  );
}

export function openOrder(ctx: Ctx, order: Order) {
  const free = freeTables(ctx);
  const elapsed = minutesBetween(order.createdAt, ctx.now);
  const meta = h(
    'div',
    { class: 'meta' },
    h('span', {}, ic('clock', 16), `${hhmm(order.createdAt)} · ${duration(elapsed)}`),
    order.serviceStatus ? h('span', { class: 'tag' }, order.serviceStatus) : null,
    order.source === 'Gel-Al' && order.customer?.time ? h('span', { class: 'tag gold' }, `Teslim ${order.customer.time}`) : null,
  );
  const customer =
    order.source === 'Gel-Al' && order.customer
      ? h(
          'div',
          { class: 'customer' },
          ic('pickup', 18),
          h('span', {}, order.customer.name || 'İsimsiz', ' · ', order.customer.channel ?? 'Tezgahtan'),
          order.customer.phone && ctx.can('pickup.contact.view') ? h('a', { href: `tel:${order.customer.phone}`, class: 'tel' }, ic('phone', 16), order.customer.phone) : null,
        )
      : null;
  const guests = order.guestChecks.length
    ? h(
        'div',
        { class: 'guests' },
        ...order.guestChecks.map((g) => h('span', { class: 'tag' }, `${g.name ?? `Kişi ${g.id}`}: ${money(g.balanceCents)}`)),
      )
    : null;
  const actions = h(
    'div',
    { class: 'action-grid' },
    actionButton(ctx, {
      label: order.source === 'Masa' ? 'Ek Sipariş' : 'Ürün Ekle',
      op: 'orders.create',
      icon: 'plus',
      primary: true,
      onclick: () => {
        closeSheet();
        ctx.go(order.source === 'Masa' ? `siparis?table=${order.table}&order=${order.id}` : `siparis?gelal=${order.id}`);
      },
    }),
    order.dueCents > 0
      ? actionButton(ctx, { label: 'Ödeme Al', op: 'payments.take', icon: 'payment', onclick: () => openPayment(ctx, order) })
      : null,
    order.source === 'Masa'
      ? actionButton(ctx, {
          label: 'Masa Taşı',
          op: 'orders.move',
          icon: 'move',
          onclick: () => openMove(ctx, order, free),
        })
      : null,
    order.source === 'Masa' && order.dueCents === 0
      ? actionButton(ctx, {
          label: 'Masayı Kapat',
          op: 'orders.release',
          icon: 'check',
          onclick: async () => report(await ctx.send('action', orderAction(order.id, 'close', cmdCtx(ctx)))),
        })
      : null,
    order.source === 'Gel-Al' && !order.deliveredAt
      ? actionButton(ctx, {
          label: 'Teslim Edildi',
          op: 'orders.release',
          icon: 'check',
          onclick: async () => report(await ctx.send('action', orderAction(order.id, 'status', cmdCtx(ctx)))),
        })
      : null,
    actionButton(ctx, {
      label: 'Fiş',
      op: 'receipts.print',
      icon: 'receipt',
      needsPos: false,
      onclick: () => openReceipt(ctx, order),
    }),
  );
  openSheet(orderLabel(order), h('div', {}, meta, customer, lineRows(order), guests, totals(order)), actions);
}

export function freeTables(ctx: Ctx): number[] {
  const busy = new Set(ctx.snap.staff.orders.filter((o) => o.source === 'Masa').map((o) => o.table));
  return tableNumbers(ctx).filter((n) => !busy.has(n));
}

export function tableNumbers(ctx: Ctx): number[] {
  const keys = Object.keys(ctx.snap.staff.floorPlan).map(Number).filter(Number.isInteger);
  return (keys.length ? keys : [1, 2, 3, 4, 5]).sort((a, b) => a - b);
}

function openMove(ctx: Ctx, order: Order, free: number[]) {
  openSheet(
    `Masa ${order.table} → ?`,
    free.length
      ? h(
          'div',
          { class: 'pick-grid' },
          ...free.map((n) =>
            h(
              'button',
              {
                class: 'pick',
                type: 'button',
                onclick: async () => {
                  closeSheet();
                  report(await ctx.send('action', orderAction(order.id, 'move', cmdCtx(ctx), { table: n })));
                },
              },
              `Masa ${n}`,
            ),
          ),
        )
      : h('p', { class: 'muted' }, 'Boş masa yok.'),
  );
}

export function openPayment(ctx: Ctx, order: Order) {
  let method: PayMethod = 'Nakit';
  let mode: 'full' | 'equal' | 'items' = 'full';
  let printReceipt = true;
  const shares: Record<string, number> = {};
  const body = h('div', { class: 'pay' });
  const foot = h('div', { class: 'pay-foot' });
  const amount = h('input', { inputmode: 'decimal', value: tlInput(order.dueCents), 'aria-label': 'Tutar (₺)' });
  const received = h('input', { inputmode: 'decimal', placeholder: 'Alınan nakit', 'aria-label': 'Alınan nakit (₺)' });
  const cashPart = h('input', { inputmode: 'decimal', placeholder: 'Nakit kısmı', 'aria-label': 'Nakit kısmı (₺)' });
  const people = h('input', { inputmode: 'numeric', value: '2', 'aria-label': 'Kişi sayısı' });
  const keyed = orderLines(order).filter((l) => l.key);

  const itemsCents = () => keyed.reduce((n, l) => n + (shares[l.key!] ?? 0) * asCents(l.price), 0);

  const draw = () => {
    if (mode === 'items') amount.value = tlInput(Math.min(itemsCents(), order.dueCents));
    const amt = parseTl(amount.value);
    const input = {
      method,
      amountCents: amt,
      receivedCents: received.value ? parseTl(received.value) : undefined,
      cashCents: cashPart.value ? parseTl(cashPart.value) : undefined,
    };
    const problem = mode === 'equal' ? null : paymentProblem(input, order.dueCents);
    body.replaceChildren(
      h('div', { class: 'due-line' }, 'Kalan bakiye', h('strong', {}, money(order.dueCents))),
      segmented(
        [
          { id: 'full', label: 'Tutar' },
          { id: 'items', label: 'Ürün bazında' },
          { id: 'equal', label: 'Eşit böl' },
        ],
        mode,
        (v) => {
          mode = v;
          draw();
        },
      ),
      mode === 'equal'
        ? h(
            'div',
            { class: 'field' },
            h('label', {}, 'Kişi sayısı'),
            people,
            h('p', { class: 'muted' }, 'Kasa hesabı kişilere eşit böler; her kişi ayrıca ödenir.'),
          )
        : h(
            'div',
            {},
            segmented(
              [
                { id: 'Nakit', label: 'Nakit' },
                { id: 'Kart', label: 'Kart' },
                { id: 'Karışık', label: 'Nakit + Kart' },
              ],
              method,
              (v) => {
                method = v;
                draw();
              },
            ),
            mode === 'items'
              ? h(
                  'div',
                  { class: 'item-pick' },
                  ...(keyed.length
                    ? keyed.map((l) =>
                        h(
                          'div',
                          { class: 'item-row' },
                          h('span', {}, l.name),
                          stepper(shares[l.key!] ?? 0, l.qty, (q) => {
                            shares[l.key!] = q;
                            draw();
                          }),
                        ),
                      )
                    : [h('p', { class: 'muted' }, 'Bu hesapta ürün bazında ödeme yapılamıyor.')]),
                )
              : null,
            h('div', { class: 'field' }, h('label', {}, 'Tutar (₺)'), amount),
            method === 'Nakit' ? h('div', { class: 'field' }, h('label', {}, 'Alınan nakit (₺)'), received) : null,
            method === 'Karışık' ? h('div', { class: 'field' }, h('label', {}, 'Nakit kısmı (₺)'), cashPart) : null,
            method === 'Nakit' && input.receivedCents ? h('div', { class: 'change' }, 'Para üstü', h('strong', {}, money(changeCents(input)))) : null,
            method === 'Karışık' && input.cashCents && input.cashCents < amt
              ? h('div', { class: 'change' }, 'Kart kısmı', h('strong', {}, money(amt - input.cashCents)))
              : null,
            h(
              'label',
              { class: 'check' },
              h('input', { type: 'checkbox', checked: printReceipt, onchange: (e: Event) => (printReceipt = (e.target as HTMLInputElement).checked) }),
              'Ödeme fişi yazdır',
            ),
            problem && amount.value ? h('p', { class: 'error' }, problem) : null,
          ),
    );
    const submit = h(
      'button',
      {
        class: 'btn primary wide',
        type: 'button',
        disabled: (mode !== 'equal' && Boolean(problem)) || !ctx.snap.posOnline,
        onclick: async () => {
          (submit as HTMLButtonElement).disabled = true; // one tap = one request (duplicate-payment guard)
          const payload =
            mode === 'equal'
              ? orderAction(order.id, 'splitEqual', cmdCtx(ctx), { count: Number(people.value) })
              : paymentAction(order.id, input, cmdCtx(ctx), {
                  printReceipt,
                  shares: mode === 'items' ? Object.fromEntries(Object.entries(shares).filter(([, q]) => q > 0)) : undefined,
                });
          const r = await ctx.send('action', payload);
          report(r);
          if (r.state === 'confirmed') closeSheet();
          else (submit as HTMLButtonElement).disabled = false;
        },
      },
      !ctx.snap.posOnline ? 'Kasa çevrimdışı' : mode === 'equal' ? 'Hesabı Böl' : `${money(Number.isNaN(amt) ? 0 : amt)} Tahsil Et`,
    );
    foot.replaceChildren(submit);
  };
  for (const i of [amount, received, cashPart]) i.addEventListener('input', draw);
  draw();
  openSheet(`Ödeme · ${orderLabel(order)}`, body, foot);
  setTimeout(() => amount.focus(), 0);
}

export function stepper(value: number, max: number, onChange: (v: number) => void): HTMLElement {
  return h(
    'span',
    { class: 'stepper' },
    h('button', { type: 'button', 'aria-label': 'Azalt', disabled: value <= 0, onclick: () => onChange(Math.max(0, value - 1)) }, ic('minus', 18)),
    h('output', {}, String(value)),
    h('button', { type: 'button', 'aria-label': 'Artır', disabled: value >= max, onclick: () => onChange(Math.min(max, value + 1)) }, ic('plus', 18)),
  );
}

export function openReceipt(ctx: Ctx, order: Order) {
  const paper = h(
    'div',
    { class: 'paper' },
    h('div', { class: 'p-head' }, 'NOHUT FALAFEL', h('small', {}, 'SİPARİŞ FİŞİ')),
    h('div', { class: 'p-meta' }, orderLabel(order), h('span', {}, hhmm(order.createdAt))),
    order.source === 'Gel-Al' && order.customer?.time ? h('div', { class: 'p-meta' }, 'Teslim', h('span', {}, order.customer.time)) : null,
    ...orderLines(order).map((l) =>
      h(
        'div',
        { class: 'p-line' },
        h('span', {}, `${l.qty} ${l.name}`, l.removed?.length ? h('small', {}, ` (−${l.removed.join(', ')})`) : null),
        h('span', {}, money(l.qty * asCents(l.price))),
      ),
    ),
    h('div', { class: 'p-total' }, 'TOPLAM', h('span', {}, money(order.totalCents))),
    order.paidCents ? h('div', { class: 'p-meta' }, 'Ödenen', h('span', {}, money(order.paidCents))) : null,
    order.dueCents ? h('div', { class: 'p-meta' }, 'Kalan', h('span', {}, money(order.dueCents))) : null,
  );
  // Phone/customer contact never appears on a printed receipt (spec §10.1).
  openSheet(
    'Fiş Önizleme',
    h('div', {}, paper, h('p', { class: 'muted' }, 'Yazdırma kasadaki yazıcıdan yapılır. Aynı fiş otomatik olarak tekrar basılmaz.')),
    actionButton(ctx, {
      label: 'Kasaya Yazdırma İsteği',
      op: 'receipts.print',
      icon: 'receipt',
      primary: true,
      onclick: async () => report(await ctx.send('print', { action: 'reprint', orderId: order.id, ...cmdCtx(ctx) })),
    }),
  );
}

/** Sipariş Al / Ek Sipariş composer (full screen). */
export function composer(ctx: Ctx, target: OrderTarget, cart: CartLine[], state: { q: string; cat: string }): HTMLElement {
  const products = ctx.snap.staff.localMenu;
  const cats = ['Tümü', ...new Set(products.filter((p) => p.active !== false).map((p) => p.category))];
  const hits = searchProducts(products, state.q).filter((p) => state.cat === 'Tümü' || p.category === state.cat);
  const add = (p: Product) => {
    if (p.soldOut) return;
    const same = cart.find((l) => l.product.id === p.id && !l.note && !l.removed.length);
    if (same) same.qty++;
    else cart.push({ product: p, qty: 1, note: '', removed: [] });
    ctx.rerender();
  };
  const search = h('input', {
    type: 'search',
    placeholder: 'Ürün ara…',
    value: state.q,
    'aria-label': 'Ürün ara',
    oninput: (e: Event) => {
      state.q = (e.target as HTMLInputElement).value;
      ctx.rerender();
      const el = document.querySelector<HTMLInputElement>('.composer input[type=search]');
      el?.focus();
      el?.setSelectionRange(state.q.length, state.q.length);
    },
  });
  const list = h(
    'div',
    { class: 'products' },
    ...hits.map((p) =>
      h(
        'button',
        { type: 'button', class: `product ${p.category === 'campaign' ? 'camp' : ''}`, disabled: p.soldOut, onclick: () => add(p) },
        h('span', { class: 'p-name' }, p.name, p.description?.tr ? h('small', {}, p.description.tr) : null),
        h('span', { class: 'p-price' }, p.soldOut ? 'Tükendi' : money(asCents(p.price))),
        cart.some((l) => l.product.id === p.id) ? h('span', { class: 'in-cart' }, String(cart.filter((l) => l.product.id === p.id).reduce((n, l) => n + l.qty, 0))) : null,
      ),
    ),
    hits.length ? null : h('p', { class: 'muted' }, 'Ürün bulunamadı.'),
  );
  const cartEl = h(
    'div',
    { class: 'cart' },
    h('div', { class: 'cart-head' }, ic('order', 18), target.source === 'Masa' ? `Masa ${target.table}${target.orderId ? ' · Ek sipariş' : ''}` : 'Gel-Al'),
    target.source === 'Gel-Al' ? pickupFields(target, ctx) : null,
    ...cart.map((l, i) =>
      h(
        'div',
        { class: 'cart-line' },
        h(
          'button',
          { type: 'button', class: 'cl-name', onclick: () => editLine(ctx, l, () => ctx.rerender()) },
          l.product.name,
          l.removed.length ? h('small', { class: 'mod' }, `− ${l.removed.join(', ')}`) : null,
          l.note ? h('small', { class: 'note-line' }, l.note) : h('small', { class: 'hint' }, 'Not / malzeme'),
        ),
        stepper(l.qty, 99, (q) => {
          if (q === 0) cart.splice(i, 1);
          else l.qty = q;
          ctx.rerender();
        }),
        h('span', { class: 'amt' }, money(l.qty * asCents(l.product.price))),
      ),
    ),
    cart.length ? null : h('p', { class: 'muted' }, 'Ürün seçin.'),
    h(
      'div',
      { class: 'cart-foot' },
      h('div', { class: 'sum' }, h('span', {}, 'Tahmini toplam'), h('strong', {}, money(cartTotalCents(cart)))),
      h(
        'button',
        {
          class: 'btn primary wide',
          type: 'button',
          disabled: !cart.length || !ctx.snap.posOnline || !ctx.can('orders.create'),
          onclick: async (e: Event) => {
            const b = e.currentTarget as HTMLButtonElement;
            b.disabled = true;
            try {
              const r = await ctx.send('order', orderRequest(target, cart, cmdCtx(ctx)));
              report(r);
              if (r.state === 'confirmed') {
                cart.length = 0;
                ctx.go(target.source === 'Masa' ? 'masalar' : 'siparisler');
              } else b.disabled = false;
            } catch (err) {
              report({ state: 'rejected', message: (err as Error).message });
              b.disabled = false;
            }
          },
        },
        !ctx.snap.posOnline ? 'Kasa çevrimdışı' : 'Siparişi Kasaya Gönder',
      ),
      h('p', { class: 'muted small' }, 'Fiyatlar kasada yeniden hesaplanır; sipariş kasa onayından sonra kesinleşir.'),
    ),
  );
  const count = cart.reduce((n, l) => n + l.qty, 0);
  // Phones: the cart is below the catalog, so a fixed bar keeps the total and
  // the way to the send button one tap away.
  const cartBar = count
    ? h(
        'button',
        { type: 'button', class: 'cart-bar', onclick: () => cartEl.scrollIntoView({ behavior: 'smooth', block: 'start' }) },
        h('span', { class: 'cb-count' }, String(count)),
        h('span', { class: 'grow' }, 'Sepeti gör ve gönder'),
        h('strong', {}, money(cartTotalCents(cart))),
      )
    : null;
  return h(
    'div',
    { class: 'composer' },
    cartBar,
    h(
      'div',
      { class: 'catalog' },
      h('div', { class: 'search' }, ic('search', 18), search),
      h(
        'div',
        { class: 'cats' },
        ...cats.map((c) =>
          h(
            'button',
            {
              type: 'button',
              class: 'cat',
              'aria-pressed': c === state.cat ? 'true' : 'false',
              onclick: () => {
                state.cat = c;
                ctx.rerender();
              },
            },
            c === 'Tümü' ? c : categoryLabel(c),
          ),
        ),
      ),
      list,
    ),
    cartEl,
  );
}

function pickupFields(target: OrderTarget, ctx: Ctx): HTMLElement {
  target.customer ??= { name: '', phone: '', time: '' };
  const c = target.customer;
  const bind = (key: 'name' | 'phone' | 'time') => (e: Event) => (c[key] = (e.target as HTMLInputElement).value);
  return h(
    'div',
    { class: 'pickup' },
    segmented(
      [
        { id: 'Tezgahtan', label: 'Tezgahtan' },
        { id: 'Telefon', label: 'Telefon' },
      ],
      target.pickupChannel ?? 'Tezgahtan',
      (v) => {
        target.pickupChannel = v;
        ctx.rerender();
      },
    ),
    h('input', { placeholder: 'Müşteri adı', value: c.name, oninput: bind('name'), 'aria-label': 'Müşteri adı' }),
    target.pickupChannel === 'Telefon'
      ? h('input', { placeholder: 'Telefon (fişe basılmaz)', inputmode: 'tel', value: c.phone, oninput: bind('phone'), 'aria-label': 'Telefon' })
      : null,
    h('input', { type: 'time', value: c.time, oninput: bind('time'), 'aria-label': 'Teslim saati' }),
  );
}

function editLine(ctx: Ctx, line: CartLine, done: () => void) {
  const note = h('textarea', { rows: 2, placeholder: 'Not (ör. az acılı)', 'aria-label': 'Not' }) as HTMLTextAreaElement;
  note.value = line.note;
  const removed = new Set(line.removed);
  const free = h('input', { placeholder: 'Diğer çıkarılacak malzeme (virgülle)', 'aria-label': 'Çıkarılacak malzeme' }) as HTMLInputElement;
  free.value = line.removed.filter((r) => !line.product.ingredients?.includes(r)).join(', ');
  const chips = line.product.ingredients?.length
    ? h(
        'div',
        { class: 'chips' },
        ...line.product.ingredients.map((i) =>
          h(
            'button',
            {
              type: 'button',
              class: 'chip-toggle',
              'aria-pressed': removed.has(i) ? 'true' : 'false',
              onclick: (e: Event) => {
                if (removed.has(i)) removed.delete(i);
                else removed.add(i);
                (e.currentTarget as HTMLElement).setAttribute('aria-pressed', removed.has(i) ? 'true' : 'false');
              },
            },
            `− ${i}`,
          ),
        ),
      )
    : null;
  openSheet(
    line.product.name,
    h('div', { class: 'form' }, chips, free, note),
    h(
      'button',
      {
        class: 'btn primary wide',
        type: 'button',
        onclick: () => {
          const extra = free.value.split(',').map((s) => s.trim()).filter(Boolean);
          line.removed = [...[...removed].filter((r) => line.product.ingredients?.includes(r)), ...extra];
          line.note = note.value.trim();
          closeSheet();
          done();
        },
      },
      'Kaydet',
    ),
  );
  void ctx;
}
