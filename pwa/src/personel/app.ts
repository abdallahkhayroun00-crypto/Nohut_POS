// Nohut Personel — daily restaurant operations (spec §10.1, §22.2).
// Default screen: Masalar. Bulut/Yedek do not exist here (§22.3).
import type { CartLine, OrderTarget } from '../shared/commands';
import { newRequestId } from '../shared/commands';
import { duration, hhmm, minutesBetween, money, orderLabel, shortDay } from '../shared/format';
import { menuScreen } from '../shared/menu';
import type { Order } from '../shared/model';
import { composer, openOrder, openReceipt, tableNumbers } from '../shared/orders';
import { profileScreen } from '../shared/profile';
import type { AppDef } from '../shared/runtime';
import { type Ctx, actionButton, empty, h, ic, kpi, report, section, segmented } from '../shared/ui';

const cart: CartLine[] = [];
let cartKey = '';
const composerState = { q: '', cat: 'Tümü' };
const menuState = { q: '' };
let orderFilter: 'all' | 'Masa' | 'Gel-Al' | 'due' = 'all';
let pickupTarget: OrderTarget | null = null;

function masalar(ctx: Ctx) {
  const orders = ctx.snap.staff.orders;
  const byTable = new Map(orders.filter((o) => o.source === 'Masa').map((o) => [o.table, o]));
  const pickups = orders.filter((o) => o.source === 'Gel-Al' && !o.deliveredAt);
  const tables = tableNumbers(ctx);
  const busy = tables.filter((n) => byTable.has(n)).length;
  return h(
    'div',
    {},
    h(
      'div',
      { class: 'summary' },
      h('span', {}, h('strong', {}, String(busy)), ' dolu'),
      h('span', {}, h('strong', {}, String(tables.length - busy)), ' boş'),
      h('button', { type: 'button', class: 'link', onclick: () => ctx.go('siparisler') }, h('strong', {}, String(pickups.length)), ' Gel-Al'),
    ),
    floorPlan(ctx, byTable),
    pickups.length
      ? section(
          'Bekleyen Gel-Al',
          h('div', { class: 'list' }, ...pickups.map((o) => orderRow(ctx, o))),
        )
      : null,
  );
}

// Same floor plan as the Windows POS and the old staff page
// (flutter_desktop/assets/staff.html renderFloor): table positions come from
// the Windows `floorPlan` (fractions of the room), with the same fallback,
// wall, door ("KAPI") and chairs, and the same free / occupied / paid colours.
const FALLBACK: [number, number, number, number][] = [
  [0.456, 0.13, 0.143, 0.135],
  [0.255, 0.165, 0.13, 0.113],
  [0.265, 0.424, 0.343, 0.174],
  [0.261, 0.71, 0.346, 0.178],
  [0.032, 0.676, 0.076, 0.148],
];

export function floorPositions(plan: Record<string, { x: number; y: number; width: number; height: number }>) {
  return FALLBACK.map((f, i) => {
    const saved = plan[String(i + 1)];
    return saved ? ([saved.x, saved.y, saved.width, saved.height] as [number, number, number, number]) : f;
  });
}

function floorPlan(ctx: Ctx, byTable: Map<number | undefined, Order>): HTMLElement {
  const positions = floorPositions(ctx.snap.staff.floorPlan);
  const rightEdge = Math.max(...positions.map(([x, , w]) => x + w + 0.035));
  const narrow = Math.min(1.42, 0.94 / rightEdge);
  const mx = (x: number) => `${(0.025 + x * narrow) * 100}%`;
  const pc = (v: number) => `${v * 100}%`;
  const floor = h('div', {
    class: 'floor',
    style: `--door-start:11.8%;--door-end:22.1%;--door-center:16.95%;--m-door-start:${mx(0.118)};--m-door-end:${mx(0.221)};--m-door-center:${mx(0.1695)}`,
  });
  floor.append(h('div', { class: 'wall', 'aria-hidden': 'true' }), h('span', { class: 'door', 'aria-hidden': 'true' }, 'KAPI'));
  const chair = (x: number, y: number) => h('span', { class: 'chair', 'aria-hidden': 'true', style: `--chair-x:${pc(x)};top:${pc(y)};--m-x:${mx(x)}` });
  positions.forEach(([x, y, w, hh], i) => {
    const table = i + 1;
    const o = byTable.get(table);
    const cx = x + w / 2;
    const cy = y + hh / 2;
    const chairs =
      table <= 2
        ? [chair(x - 0.016, cy), chair(x + w + 0.016, cy)]
        : table === 5
          ? [chair(cx, y - 0.018), chair(cx, y + hh + 0.024)]
          : [chair(x + w * 0.19, y - 0.018), chair(x + w * 0.76, y - 0.018), chair(x + w + 0.035, cy), chair(x + w * 0.19, y + hh + 0.024), chair(x + w * 0.76, y + hh + 0.024)];
    const paid = Boolean(o) && o!.dueCents <= 0;
    const mins = o ? minutesBetween(o.createdAt, ctx.now) : null;
    const label = o ? (paid ? 'Ödendi · Masa açık' : `Dolu · ${money(o.dueCents)}`) : 'Boş';
    floor.append(
      ...chairs,
      h(
        'button',
        {
          type: 'button',
          class: `table-tile ${paid ? 'paid' : o ? 'occupied' : ''}`,
          'data-table': table,
          'aria-label': `Masa ${table}, ${label}${mins !== null ? `, ${mins} dk` : ''}`,
          style: `--table-x:${pc(x)};top:${pc(y)};--table-width:${pc(w)};height:${pc(hh)};--m-x:${mx(x)};--m-width:${pc(w * narrow)}`,
          onclick: () => (o ? openOrder(ctx, o) : ctx.go(`siparis?table=${table}`)),
        },
        h('strong', {}, `Masa ${table}`),
        h('small', {}, o ? (paid ? 'Ödendi' : money(o.dueCents)) : 'Boş', paid ? h('span', { class: 'state-detail' }, ' · Masa açık') : null),
        mins !== null ? h('small', {}, `${mins} dk`) : null,
      ),
    );
  });
  return floor;
}

function orderRow(ctx: Ctx, o: Order): HTMLElement {
  return h(
    'button',
    { type: 'button', class: 'list-row', onclick: () => openOrder(ctx, o) },
    h('span', { class: `src ${o.source === 'Masa' ? 'masa' : 'gelal'}` }, o.source === 'Masa' ? String(o.table) : 'GA'),
    h(
      'span',
      { class: 'grow' },
      h('strong', {}, orderLabel(o)),
      h(
        'small',
        {},
        hhmm(o.createdAt),
        o.source === 'Gel-Al' && o.customer?.name ? ` · ${o.customer.name}` : '',
        o.source === 'Gel-Al' && o.customer?.time ? ` · teslim ${o.customer.time}` : '',
        o.serviceStatus ? ` · ${o.serviceStatus}` : '',
      ),
    ),
    h('span', { class: 'amt' }, money(o.totalCents), o.dueCents > 0 ? h('small', { class: 'due' }, `Kalan ${money(o.dueCents)}`) : h('small', { class: 'paid' }, 'Ödendi')),
  );
}

function siparisler(ctx: Ctx) {
  const all = ctx.snap.staff.orders;
  const list = all.filter((o) =>
    orderFilter === 'all' ? true : orderFilter === 'due' ? o.dueCents > 0 : o.source === orderFilter,
  );
  return h(
    'div',
    {},
    segmented(
      [
        { id: 'all', label: `Tümü ${all.length}` },
        { id: 'Masa', label: 'Masa' },
        { id: 'Gel-Al', label: 'Gel-Al' },
        { id: 'due', label: 'Ödeme bekleyen' },
      ],
      orderFilter,
      (v) => {
        orderFilter = v;
        ctx.rerender();
      },
    ),
    list.length ? h('div', { class: 'list' }, ...list.map((o) => orderRow(ctx, o))) : empty('Açık sipariş yok.', 'order'),
  );
}

const platformClass: Record<string, string> = { 'Trendyol Go': 'tgo', Yemeksepeti: 'ys', 'Migros Yemek': 'mg' };
const printLabels: Record<string, string> = { printed: 'Basıldı', failed: 'Basılamadı', pending: 'Bekliyor', queued: 'Sırada' };
const printLabel = (s?: string) => (s ? (printLabels[s] ?? s) : '—');

const statusLabels: Record<string, string> = {
  created: 'Yeni',
  picking: 'Hazırlanıyor',
  invoiced: 'Hazır',
  shipped: 'Yolda',
  delivered: 'Teslim edildi',
  cancelled: 'İptal',
};

function online(ctx: Ctx) {
  const orders = ctx.snap.staff.onlineOrders;
  if (!orders.length) return empty('Aktif online sipariş yok.', 'online');
  return h(
    'div',
    { class: 'stack' },
    ...orders.map((o) => {
      const writable = ctx.snap.staff.platformWritable[o.platform] === true;
      const status = o.status.toLowerCase();
      const act = (label: string, op: string, icon: string, primary = false) =>
        writable
          ? actionButton(ctx, {
              label,
              op: 'online.act',
              icon,
              primary,
              onclick: async () =>
                report(await ctx.send('platform', { requestId: newRequestId(), platform: o.platform, packageId: o.packageId, orderNumber: o.orderNumber, operation: op })),
            })
          : null;
      return h(
        'article',
        { class: `card online-card ${status === 'created' ? 'new' : ''}` },
        h(
          'div',
          { class: 'oc-head' },
          h('span', { class: `platform ${platformClass[o.platform] ?? ''}` }, o.platform),
          h('strong', {}, `#${o.dailyNumber ?? o.orderNumber}`),
          h('span', { class: `tag ${status === 'created' ? 'gold' : ''}` }, statusLabels[status] ?? o.status),
          h('span', { class: 'muted grow right' }, hhmm(o.createdAt)),
        ),
        h(
          'div',
          { class: 'lines' },
          ...o.lines.map((l) =>
            h(
              'div',
              { class: 'line' },
              h('span', { class: 'qty' }, `${l.qty}×`),
              h(
                'span',
                { class: 'name' },
                l.name,
                l.options?.length ? h('small', {}, l.options.join(', ')) : null,
                l.removed?.length ? h('small', { class: 'mod' }, `− ${l.removed.join(', ')}`) : null,
                l.extras?.length ? h('small', {}, `+ ${l.extras.join(', ')}`) : null,
              ),
            ),
          ),
        ),
        o.customerNote ? h('p', { class: 'note-box' }, ic('alert', 16), o.customerNote) : null,
        h(
          'div',
          { class: 'oc-foot' },
          h('span', {}, money(o.totalCents), o.paymentType ? ` · ${o.paymentType}` : ''),
          o.kitchenPrintState ? h('span', { class: 'muted' }, `Mutfak fişi: ${printLabel(o.kitchenPrintState)}`) : null,
        ),
        writable
          ? h(
              'div',
              { class: 'action-grid' },
              status === 'created' ? act('Kabul Et', 'accept', 'check', true) : null,
              status === 'picking' ? act('Hazır', 'ready', 'check', true) : null,
            )
          : h('p', { class: 'muted small' }, 'Bu platform için işlem kasadan yapılır (entegrasyon salt okunur).'),
      );
    }),
  );
}

function mesai(ctx: Ctx) {
  const me = ctx.snap.session.employeeId;
  const mine = (ctx.snap.shifts ?? []).filter((s) => s.employeeId === me);
  const open = mine.find((s) => !s.end);
  const mins = (s: { start: string; end?: string }) =>
    Math.max(0, Math.floor(((s.end ? new Date(s.end) : ctx.now).getTime() - new Date(s.start).getTime()) / 60000));
  const today = ctx.now.toISOString().slice(0, 10);
  const weekAgo = new Date(ctx.now.getTime() - 7 * 86400000);
  const todayMin = mine.filter((s) => s.start.slice(0, 10) === today).reduce((n, s) => n + mins(s), 0);
  const weekMin = mine.filter((s) => new Date(s.start) >= weekAgo).reduce((n, s) => n + mins(s), 0);
  return h(
    'div',
    {},
    h(
      'div',
      { class: `card shift-card ${open ? 'on' : ''}` },
      h('span', { class: 'muted' }, open ? `Mesai ${hhmm(open.start)}'de başladı` : 'Mesai kapalı'),
      h('strong', { class: 'big' }, open ? duration(mins(open)) : '—'),
      actionButton(ctx, {
        label: open ? 'Mesai Bitir' : 'Mesai Başlat',
        op: 'shifts.self',
        icon: open ? 'stop' : 'play',
        primary: true,
        onclick: async () => report(await ctx.send('shift', { requestId: newRequestId(), action: open ? 'clockOut' : 'clockIn', employeeId: me })),
      }),
    ),
    h('div', { class: 'kpis' }, kpi('Bugün', duration(todayMin)), kpi('Son 7 gün', duration(weekMin))),
    section(
      'Mesai Geçmişim',
      mine.length
        ? h(
            'div',
            { class: 'list' },
            ...mine
              .slice()
              .reverse()
              .map((s) =>
                h(
                  'div',
                  { class: 'list-row static' },
                  h('span', { class: 'grow' }, h('strong', {}, shortDay(s.start.slice(0, 10))), h('small', {}, `${hhmm(s.start)} – ${s.end ? hhmm(s.end) : 'devam ediyor'}`)),
                  s.corrected ? h('span', { class: 'tag gold', title: 'Yönetici düzeltmesi (kayıtlı)' }, 'Düzeltildi') : null,
                  h('span', { class: 'amt' }, duration(mins(s))),
                ),
              ),
          )
        : empty('Mesai kaydı yok.', 'clock'),
    ),
  );
}

function maas(ctx: Ctx) {
  const me = ctx.snap.session.employeeId;
  const rows = (ctx.snap.month?.weeklyPayroll ?? []).filter((r) => r.employeeId === me);
  if (!rows.length) return empty('Bu ay için maaş kaydı yok.', 'wallet');
  const payable = rows.reduce((n, r) => n + r.payableCents, 0);
  const paid = rows.filter((r) => r.paid).reduce((n, r) => n + r.payableCents, 0);
  return h(
    'div',
    {},
    h(
      'div',
      { class: 'kpis' },
      kpi('Hak edilen', money(rows.reduce((n, r) => n + r.grossCents, 0))),
      kpi('Avans', money(rows.reduce((n, r) => n + r.advanceCents, 0))),
      kpi('Ödenen', money(paid), undefined, 'good'),
      kpi('Kalan', money(payable - paid), undefined, payable - paid > 0 ? 'gold' : undefined),
    ),
    section(
      'Haftalık',
      h(
        'div',
        { class: 'list' },
        ...rows.map((r) =>
          h(
            'div',
            { class: 'list-row static' },
            h(
              'span',
              { class: 'grow' },
              h('strong', {}, `${shortDay(r.weekStart)} – ${shortDay(r.weekEnd)}`),
              h(
                'small',
                {},
                `${duration(r.workedMinutes)} · ${r.payType === 'hourly' ? `${money(r.rateCents)}/sa` : `${money(r.rateCents)}/hafta`}`,
                r.bonusCents ? ` · prim ${money(r.bonusCents)}` : '',
                r.advanceCents ? ` · avans ${money(r.advanceCents)}` : '',
              ),
            ),
            h('span', { class: 'amt' }, money(r.payableCents), h('small', { class: r.paid ? 'paid' : 'due' }, r.paid ? 'Ödendi' : 'Bekliyor')),
          ),
        ),
      ),
    ),
  );
}

function fisler(ctx: Ctx) {
  const orders = ctx.snap.staff.orders;
  return h(
    'div',
    {},
    orders.length
      ? h(
          'div',
          { class: 'list' },
          ...orders.map((o) =>
            h(
              'button',
              { type: 'button', class: 'list-row', onclick: () => openReceipt(ctx, o) },
              ic('receipt', 20),
              h('span', { class: 'grow' }, h('strong', {}, orderLabel(o)), h('small', {}, hhmm(o.createdAt))),
              h('span', { class: 'amt' }, money(o.totalCents)),
            ),
          ),
        )
      : empty('Açık hesap yok.', 'receipt'),
    section(
      'Online mutfak fişleri',
      ctx.snap.staff.onlineOrders.length
        ? h(
            'div',
            { class: 'list' },
            ...ctx.snap.staff.onlineOrders.map((o) =>
              h(
                'div',
                { class: 'list-row static' },
                h('span', { class: `platform ${platformClass[o.platform] ?? ''}` }, o.platform),
                h('span', { class: 'grow' }, `#${o.dailyNumber ?? o.orderNumber}`),
                h('span', { class: `tag ${o.kitchenPrintState === 'failed' ? 'bad' : ''}` }, printLabel(o.kitchenPrintState)),
              ),
            ),
          )
        : empty('Online sipariş yok.', 'online'),
    ),
  );
}

function bildirimler(ctx: Ctx) {
  const n = ctx.snap.staff.staffNotices;
  const newOnline = ctx.snap.staff.onlineOrders.filter((o) => o.status.toLowerCase() === 'created');
  if (!n.length && !newOnline.length) return empty('Bildirim yok.', 'bell');
  return h(
    'div',
    { class: 'list' },
    ...newOnline.map((o) =>
      h(
        'button',
        { type: 'button', class: 'list-row', onclick: () => ctx.go('online') },
        h('span', { class: `platform ${platformClass[o.platform] ?? ''}` }, o.platform),
        h('span', { class: 'grow' }, h('strong', {}, 'Yeni online sipariş'), h('small', {}, `#${o.dailyNumber ?? o.orderNumber} · ${hhmm(o.createdAt)}`)),
      ),
    ),
    ...n.map((x) =>
      h(
        'div',
        { class: 'list-row static' },
        ic('bell', 18),
        h('span', { class: 'grow' }, h('strong', {}, x.action), h('small', {}, [x.staff, x.table ? `Masa ${x.table}` : '', hhmm(x.at)].filter(Boolean).join(' · '))),
      ),
    ),
  );
}

function daha(ctx: Ctx) {
  const items: [string, string, string, string?][] = [
    ['maas', 'Maaş & Avans', 'wallet', 'payroll.self.view'],
    ['menu', 'Menü & Kampanya', 'menu', 'menu.view'],
    ['fisler', 'Fişler', 'receipt', 'receipts.print'],
    ['bildirimler', 'Bildirimler', 'bell'],
    ['profil', 'Profil', 'user'],
  ];
  return h(
    'div',
    { class: 'list' },
    ...items
      .filter(([, , , op]) => !op || ctx.can(op))
      .map(([id, label, icon]) =>
        h('button', { type: 'button', class: 'list-row', onclick: () => ctx.go(id) }, h('span', { class: 'row-ic' }, ic(icon, 20)), h('span', { class: 'grow' }, h('strong', {}, label)), ic('move', 18)),
      ),
  );
}

export const personel: AppDef = {
  name: 'Nohut Personel',
  client: 'personel',
  home: 'masalar',
  nav(ctx) {
    const newOnline = ctx.snap.staff.onlineOrders.filter((o) => o.status.toLowerCase() === 'created').length;
    return [
      { id: 'masalar', label: 'Masalar', icon: 'table' },
      { id: 'siparisler', label: 'Siparişler', icon: 'order', badge: ctx.snap.staff.orders.filter((o) => o.source === 'Gel-Al' && !o.deliveredAt).length },
      { id: 'online', label: 'Online', icon: 'online', badge: newOnline },
      { id: 'mesai', label: 'Mesailerim', icon: 'clock' },
      { id: 'daha', label: 'Daha Fazla', icon: 'more' },
    ];
  },
  navOf(route) {
    return ({ siparis: 'siparisler', maas: 'daha', menu: 'daha', fisler: 'daha', bildirimler: 'daha', profil: 'daha' } as Record<string, string>)[route] ?? route;
  },
  screen(route, params, ctx) {
    switch (route) {
      case 'masalar':
        return { title: 'Masalar', body: masalar(ctx) };
      case 'siparisler':
        return {
          title: 'Siparişler',
          action: h(
            'button',
            {
              type: 'button',
              class: 'btn small gold',
              disabled: !ctx.can('orders.create'),
              onclick: () => {
                pickupTarget = null;
                ctx.go('siparis?gelal=new');
              },
            },
            ic('plus', 16),
            'Gel-Al',
          ),
          body: siparisler(ctx),
        };
      case 'siparis': {
        const table = Number(params.get('table')) || undefined;
        const orderId = Number(params.get('order')) || undefined;
        const gelal = params.get('gelal');
        const key = `${table ?? ''}|${orderId ?? ''}|${gelal ?? ''}`;
        if (key !== cartKey) {
          cart.length = 0;
          cartKey = key;
          composerState.q = '';
          composerState.cat = 'Tümü';
          pickupTarget = null;
        }
        const target: OrderTarget = table
          ? { source: 'Masa', table, orderId }
          : (pickupTarget ??= { source: 'Gel-Al', pickupChannel: 'Tezgahtan' });
        if (gelal && gelal !== 'new') {
          const existing = ctx.snap.staff.orders.find((o) => o.id === Number(gelal));
          if (existing) target.customer ??= { name: existing.customer?.name ?? '', phone: '', time: existing.customer?.time ?? '' };
        }
        return {
          title: table ? (orderId ? `Masa ${table} · Ek Sipariş` : `Masa ${table} · Sipariş Al`) : 'Gel-Al Siparişi',
          back: table ? 'masalar' : 'siparisler',
          body: composer(ctx, target, cart, composerState),
        };
      }
      case 'online':
        return { title: 'Online Siparişler', body: online(ctx) };
      case 'mesai':
        return { title: 'Mesailerim', body: mesai(ctx) };
      case 'daha':
        return { title: 'Daha Fazla', body: daha(ctx) };
      case 'maas':
        return { title: 'Maaş & Avans', back: 'daha', body: maas(ctx) };
      case 'menu':
        return { title: 'Menü & Kampanya', back: 'daha', body: menuScreen(ctx, menuState) };
      case 'fisler':
        return { title: 'Fişler', back: 'daha', body: fisler(ctx) };
      case 'bildirimler':
        return { title: 'Bildirimler', back: 'daha', body: bildirimler(ctx) };
      case 'profil':
        return { title: 'Profil', back: 'daha', body: profileScreen(ctx) };
      default:
        return null;
    }
  },
};
