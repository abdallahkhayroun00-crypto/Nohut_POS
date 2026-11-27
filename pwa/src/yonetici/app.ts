// Nohut Yönetici — restaurant management (spec §10.2, §22.2).
// Default screen: Genel Bakış. Bulut/Yedek are Windows-only (§22.3).
import { type Period, delta, inRange, peakHours, periodRange, samePeriodBefore, series, sum, toCsv, toDate } from '../shared/analytics';
import { newRequestId } from '../shared/commands';
import { categoryLabel, duration, hhmm, money, shortDay } from '../shared/format';
import { menuScreen } from '../shared/menu';
import type { OverviewOrder } from '../shared/model';
import { findOperation, operations } from '../shared/permissions';
import { profileScreen } from '../shared/profile';
import type { AppDef } from '../shared/runtime';
import { type Ctx, actionButton, bars, closeSheet, columns, empty, h, ic, kpi, openSheet, report, section, segmented } from '../shared/ui';

let period: Exclude<Period, 'custom'> = 'week';
let staffTab: 'ekip' | 'mesai' | 'maas' = 'ekip';
let financeTab: 'ozet' | 'malzeme' | 'sabit' | 'diger' | 'platform' = 'ozet';
let reportPeriod: Exclude<Period, 'custom'> = 'month';
const menuState = { q: '' };

const pct = (d: number | null, what = 'önceki döneme') => (d === null ? 'karşılaştırma verisi yok' : `${d > 0 ? '+' : ''}${d.toLocaleString('tr-TR')}% ${what} göre`);
const tone = (d: number | null) => (d === null ? undefined : d >= 0 ? 'good' : 'bad');
const today = (ctx: Ctx) => ctx.snap.overview?.day ?? ctx.snap.asOf.slice(0, 10);

function genel(ctx: Ctx) {
  const o = ctx.snap.overview;
  if (!o) return empty('Genel bakış verisi henüz gelmedi.', 'dashboard');
  const day = o.day;
  const rows = ctx.snap.sales?.daily ?? [];
  const t = sum(inRange(rows, [day, day]));
  // Today is still in progress: show yesterday's full figure, not a % that
  // compares a partial day with a whole one.
  const prev = sum(inRange(rows, samePeriodBefore('day', [day, day])));
  const local = o.orders.filter((x) => !x.cancelled);
  const gross = rows.length ? t.grossCents : local.reduce((n, x) => n + x.totalCents, 0) + o.online.reduce((n, x) => n + x.totalCents, 0);
  const platform = o.online.reduce((n, x) => n + x.totalCents, 0);
  const outstanding = o.openAccounts.reduce((n, x) => n + (x.dueCents ?? 0), 0);
  const count = o.orderCount + o.online.length;
  const activeTables = ctx.snap.staff.orders.filter((x) => x.source === 'Masa').length;
  const pickups = ctx.snap.staff.orders.filter((x) => x.source === 'Gel-Al' && !x.deliveredAt).length;
  const peaks = peakHours(o.hourly);
  const est = ctx.snap.month?.summary.estimateCents;
  return h(
    'div',
    {},
    h(
      'div',
      { class: 'status-strip' },
      h('span', { class: `dot-label ${ctx.snap.posOnline ? 'ok' : 'off'}` }, ctx.snap.posOnline ? 'Restoran açık · kasa bağlı' : 'Kasa çevrimdışı'),
      h('span', { class: 'muted' }, `${shortDay(day)} · son senkronizasyon ${hhmm(ctx.snap.asOf)}`),
    ),
    h(
      'div',
      { class: 'kpis hero-kpis' },
      kpi('Brüt satış', money(gross), prev.grossCents ? `Dün: ${money(prev.grossCents)}` : undefined),
      kpi('Kasa tahsilatı', money(o.cashCents + o.cardCents), `Nakit ${money(o.cashCents)} · Kart ${money(o.cardCents)}`),
      kpi('Platform satışı', money(platform), `${o.online.length} sipariş`),
      kpi('Açık bakiye', money(outstanding), `${o.openAccounts.length} hesap`, outstanding ? 'gold' : undefined),
    ),
    h(
      'div',
      { class: 'kpis' },
      kpi('Sipariş', String(count), prev.orderCount ? `Dün: ${prev.orderCount}` : undefined),
      kpi('Ortalama sipariş', money(count ? Math.round(gross / count) : 0)),
      kpi('İade', money(t.refundCents)),
      kpi('Aktif masa / Gel-Al', `${activeTables} / ${pickups}`),
    ),
    est !== undefined
      ? h(
          'div',
          { class: 'card row-card' },
          ic('finance', 22),
          h('div', { class: 'grow' }, h('strong', {}, 'Bu ay tahmini faaliyet sonucu'), h('small', {}, 'Tahmini işletme sonucu — yasal muhasebe kârı değildir.')),
          h('strong', { class: est >= 0 ? 'pos' : 'neg' }, money(est)),
        )
      : null,
    section(
      'Saatlik yoğunluk',
      columns(o.hourly.slice(8, 24), Array.from({ length: 16 }, (_, i) => String(i + 8)), (v) => `${v} sipariş`, peaks[0] !== undefined ? peaks[0] - 8 : undefined),
      peaks.length ? h('p', { class: 'muted small' }, `En yoğun saatler: ${peaks.map((p) => `${p}:00`).join(', ')}`) : null,
    ),
    section(
      'Açık hesaplar',
      o.openAccounts.length ? h('div', { class: 'list' }, ...o.openAccounts.map((x) => accountRow(x))) : empty('Açık bakiye yok.', 'check'),
    ),
    section(
      'Personel performansı (bugün)',
      o.staff.length
        ? bars(o.staff.map((s) => ({ label: s.name, value: s.ownedCents, display: `${money(s.ownedCents)} · ${s.tableOrders + s.pickupOrders} sip.` })))
        : empty('Bugün personel kaydı yok.', 'people'),
    ),
  );
}

function accountRow(x: OverviewOrder): HTMLElement {
  return h(
    'div',
    { class: 'list-row static' },
    h('span', { class: `src ${x.source === 'Masa' ? 'masa' : 'gelal'}` }, x.source === 'Masa' ? String(x.table ?? '') : 'GA'),
    h('span', { class: 'grow' }, h('strong', {}, `#${x.dailyNumber ?? x.id} · ${x.source === 'Masa' ? `Masa ${x.table}` : x.source}`), h('small', {}, `${hhmm(x.createdAt)}${x.owner ? ` · ${x.owner}` : ''}`)),
    h('span', { class: 'amt' }, money(x.dueCents ?? 0), h('small', { class: 'due' }, `/ ${money(x.totalCents)}`)),
  );
}

const WEEKDAYS = ['Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt', 'Paz'];

function satislar(ctx: Ctx) {
  const s = ctx.snap.sales;
  if (!s) return empty('Satış geçmişi kasadan henüz gelmedi.', 'chart');
  const range = periodRange(period, today(ctx));
  const done = toDate(range, today(ctx));
  const cur = sum(inRange(s.daily, done));
  const prev = sum(inRange(s.daily, samePeriodBefore(period, done)));
  const vs = { day: 'düne', week: 'geçen haftanın aynı günlerine', month: 'geçen ayın aynı günlerine', year: 'geçen yılın aynı dönemine' }[period];
  const sr = series(s.daily, range);
  const maxHeat = Math.max(1, ...s.heatmap.flat());
  return h(
    'div',
    {},
    segmented(
      [
        { id: 'day', label: 'Gün' },
        { id: 'week', label: 'Hafta' },
        { id: 'month', label: 'Ay' },
        { id: 'year', label: 'Yıl' },
      ],
      period,
      (v) => {
        period = v;
        ctx.rerender();
      },
    ),
    h('p', { class: 'muted small' }, `${shortDay(range[0])} – ${shortDay(range[1])}`),
    h(
      'div',
      { class: 'kpis' },
      kpi('Brüt satış', money(cur.grossCents), pct(delta(cur.grossCents, prev.grossCents), vs), tone(delta(cur.grossCents, prev.grossCents))),
      kpi('Kasa tahsilatı', money(cur.collectedCents)),
      kpi('Sipariş', String(cur.orderCount), pct(delta(cur.orderCount, prev.orderCount), vs), tone(delta(cur.orderCount, prev.orderCount))),
      kpi('Ortalama', money(cur.avgCents)),
    ),
    period !== 'day' ? section('Satış grafiği', columns(sr.map((x) => x.value), sr.map((x) => x.label), money)) : null,
    section(
      'Kanallar',
      bars([
        { label: 'Masa', value: cur.masaCount, display: `${cur.masaCount} sip.` },
        { label: 'Gel-Al', value: cur.gelalCount, display: `${cur.gelalCount} sip.` },
        { label: 'Online', value: cur.onlineCount, display: `${cur.onlineCount} sip.` },
      ]),
      bars([
        { label: 'Nakit', value: cur.cashCents, display: money(cur.cashCents) },
        { label: 'Kart', value: cur.cardCents, display: money(cur.cardCents) },
        { label: 'Platform', value: cur.platformCents, display: money(cur.platformCents) },
      ]),
    ),
    section(
      'Haftalık yoğunluk (gün × saat)',
      h(
        'div',
        { class: 'heat', role: 'img', 'aria-label': 'Gün ve saate göre sipariş yoğunluğu' },
        h('span', {}),
        ...Array.from({ length: 14 }, (_, i) => h('span', { class: 'hh' }, String(i + 9))),
        ...s.heatmap.flatMap((row, d) => [
          h('span', { class: 'hd' }, WEEKDAYS[d]!),
          ...row.slice(9, 23).map((v, i) => h('span', { class: 'hc', style: `--a:${(v / maxHeat).toFixed(2)}`, title: `${WEEKDAYS[d]} ${i + 9}:00 · ${v} sipariş` })),
        ]),
      ),
    ),
    section(
      'En çok satanlar',
      bars(s.topProducts.slice(0, 8).map((p) => ({ label: p.name, value: p.qty, display: `${p.qty} · ${money(p.grossCents)}` }))),
    ),
    section(
      'Kategoriler',
      bars(
        [...s.topProducts.reduce((m, p) => m.set(p.category, (m.get(p.category) ?? 0) + p.grossCents), new Map<string, number>())]
          .sort((a, b) => b[1] - a[1])
          .map(([c, v]) => ({ label: categoryLabel(c), value: v, display: money(v) })),
      ),
    ),
    section('Platform performansı', bars(s.platforms.map((p) => ({ label: p.source, value: p.grossCents, display: `${money(p.grossCents)} · ${p.orders} sip.` })))),
  );
}

function finans(ctx: Ctx) {
  const m = ctx.snap.month;
  if (!m) return empty('Finans verisi kasadan henüz gelmedi.', 'finance');
  const sm = m.summary;
  const paidIds = new Set(m.fixedPayments.map((p) => p.templateId));
  const body =
    financeTab === 'ozet'
      ? h(
          'div',
          {},
          h(
            'div',
            { class: 'kpis' },
            kpi('Kasa gelirleri', money(sm.localReceiptsCents)),
            kpi('Platform net', money(sm.onlineKnownNetCents), sm.onlineUnpricedGrossCents ? `${money(sm.onlineUnpricedGrossCents)} brüt komisyonsuz` : undefined),
            kpi('Toplam gider', money(sm.totalExpensesCents), undefined, 'bad'),
            kpi('Tahmini sonuç', money(sm.estimateCents), 'Yasal kâr değildir', sm.estimateCents >= 0 ? 'good' : 'bad'),
          ),
          section(
            'Gider dağılımı',
            bars([
              { label: 'Malzeme', value: sm.materialsCents, display: money(sm.materialsCents) },
              { label: 'Maaşlar', value: sm.payrollCents, display: money(sm.payrollCents) },
              { label: 'Sabit giderler', value: sm.fixedCents, display: money(sm.fixedCents) },
              { label: 'Diğer', value: sm.otherCents, display: money(sm.otherCents) },
            ]),
          ),
        )
      : financeTab === 'malzeme'
        ? list(
            m.materials.filter((x) => !x.voided),
            (x) => [x.title, `${shortDay(x.date)}${x.market ? ` · ${x.market}` : ''}${x.paymentMethod ? ` · ${x.paymentMethod}` : ''}`, money(x.totalCents)],
            'Bu ay malzeme alışı yok.',
          )
        : financeTab === 'sabit'
          ? list(
              m.monthlyFixed,
              (x) => [x.name, `${x.category}${x.dueDay ? ` · her ayın ${x.dueDay}'i` : ''}`, money(x.amountCents), paidIds.has(x.id) ? 'Ödendi' : 'Bekliyor'],
              'Sabit gider tanımı yok.',
            )
          : financeTab === 'diger'
            ? list(
                m.other.filter((x) => !x.voided),
                (x) => [x.name, `${shortDay(x.date)} · ${x.category}`, money(x.amountCents)],
                'Bu ay diğer gider yok.',
              )
            : list(
                m.platforms,
                (x) => [x.source, `Brüt ${money(x.grossCents)} · Kesinti ${money(x.deductionCents)} · ${x.automaticOrders} sip.`, money(x.netCents)],
                'Platform verisi yok.',
              );
  return h(
    'div',
    {},
    h('p', { class: 'muted small' }, `${m.month} ayı`),
    segmented(
      [
        { id: 'ozet', label: 'Özet' },
        { id: 'malzeme', label: 'Malzeme' },
        { id: 'sabit', label: 'Sabit' },
        { id: 'diger', label: 'Diğer' },
        { id: 'platform', label: 'Platform' },
      ],
      financeTab,
      (v) => {
        financeTab = v;
        ctx.rerender();
      },
    ),
    body,
  );
}

function list<T>(rows: T[], cols: (r: T) => [string, string, string, string?], none: string): HTMLElement {
  if (!rows.length) return empty(none, 'finance');
  return h(
    'div',
    { class: 'list' },
    ...rows.map((r) => {
      const [a, b, c, d] = cols(r);
      return h(
        'div',
        { class: 'list-row static' },
        h('span', { class: 'grow' }, h('strong', {}, a), h('small', {}, b)),
        h('span', { class: 'amt' }, c, d ? h('small', { class: d === 'Ödendi' ? 'paid' : 'due' }, d) : null),
      );
    }),
  );
}

function expenseSheet(ctx: Ctx) {
  const name = h('input', { placeholder: 'Açıklama', 'aria-label': 'Açıklama' }) as HTMLInputElement;
  const cat = h('input', { placeholder: 'Kategori (ör. Temizlik)', 'aria-label': 'Kategori' }) as HTMLInputElement;
  const amt = h('input', { inputmode: 'decimal', placeholder: 'Tutar (₺)', 'aria-label': 'Tutar' }) as HTMLInputElement;
  const date = h('input', { type: 'date', value: today(ctx), 'aria-label': 'Tarih' }) as HTMLInputElement;
  let method: 'Nakit' | 'Kart' = 'Nakit';
  const seg = segmented(
    [
      { id: 'Nakit', label: 'Nakit' },
      { id: 'Kart', label: 'Kart' },
    ],
    method,
    (v) => {
      method = v;
      seg.querySelectorAll('button').forEach((b) => b.setAttribute('aria-selected', b.textContent === v ? 'true' : 'false'));
    },
  );
  openSheet(
    'Günlük Gider',
    h('div', { class: 'form' }, name, cat, amt, date, seg),
    actionButton(ctx, {
      label: 'Kasaya Gönder',
      op: 'finance.edit',
      primary: true,
      onclick: async () => {
        const cents = Math.round(Number(amt.value.replace(',', '.')) * 100);
        if (!name.value.trim() || !(cents > 0)) return report({ state: 'rejected', message: 'Açıklama ve tutar girin' });
        closeSheet();
        report(
          await ctx.send('finance', {
            operation: 'managerWrite',
            action: 'other_create',
            requestId: newRequestId(),
            record: { date: date.value, category: cat.value.trim() || 'Diğer', name: name.value.trim(), amountCents: cents, paymentMethod: method },
          }),
        );
      },
    }),
  );
}

function personelScreen(ctx: Ctx) {
  const o = ctx.snap.overview;
  const m = ctx.snap.month;
  const shifts = ctx.snap.shifts ?? [];
  const mins = (s: { start: string; end?: string }) => Math.max(0, Math.floor(((s.end ? Date.parse(s.end) : ctx.now.getTime()) - Date.parse(s.start)) / 60000));
  let body: HTMLElement;
  if (staffTab === 'ekip') {
    const emps = o?.employees ?? ctx.snap.staff.employees;
    body = emps.length
      ? h(
          'div',
          { class: 'list' },
          ...emps.map((e) => {
            const perf = o?.staff.find((s) => s.name === e.name);
            const onShift = shifts.some((s) => s.employeeId === e.id && !s.end);
            return h(
              'div',
              { class: 'list-row static' },
              h('span', { class: 'avatar sm' }, e.name.slice(0, 1)),
              h('span', { class: 'grow' }, h('strong', {}, e.name), h('small', {}, ['role' in e ? (e.role as string) : '', onShift ? 'Mesaide' : '', perf ? `bugün ${perf.tableOrders + perf.pickupOrders} sipariş` : ''].filter(Boolean).join(' · '))),
              h('span', { class: `tag ${e.active === false ? 'bad' : 'good'}` }, e.active === false ? 'Pasif' : 'Aktif'),
            );
          }),
        )
      : empty('Personel kaydı yok.', 'people');
  } else if (staffTab === 'mesai') {
    body = shifts.length
      ? h(
          'div',
          { class: 'list' },
          ...shifts
            .slice()
            .reverse()
            .map((s) =>
              h(
                'div',
                { class: 'list-row static' },
                h('span', { class: 'grow' }, h('strong', {}, s.employeeName), h('small', {}, `${shortDay(s.start.slice(0, 10))} · ${hhmm(s.start)} – ${s.end ? hhmm(s.end) : 'devam ediyor'}`)),
                s.corrected ? h('span', { class: 'tag gold' }, 'Düzeltildi') : null,
                h('span', { class: 'amt' }, duration(mins(s))),
              ),
            ),
        )
      : empty('Mesai kaydı yok.', 'clock');
  } else {
    const rows = m?.weeklyPayroll ?? [];
    body = rows.length
      ? h(
          'div',
          {},
          h(
            'div',
            { class: 'kpis' },
            kpi('Toplam hak ediş', money(rows.reduce((n, r) => n + r.grossCents, 0))),
            kpi('Avanslar', money(rows.reduce((n, r) => n + r.advanceCents, 0))),
            kpi('Ödenecek', money(rows.filter((r) => !r.paid).reduce((n, r) => n + r.payableCents, 0)), undefined, 'gold'),
          ),
          list(
            rows,
            (r) => [r.employeeName, `${shortDay(r.weekStart)} – ${shortDay(r.weekEnd)} · ${duration(r.workedMinutes)}${r.bonusCents ? ` · prim ${money(r.bonusCents)}` : ''}${r.advanceCents ? ` · avans ${money(r.advanceCents)}` : ''}`, money(r.payableCents), r.paid ? 'Ödendi' : 'Bekliyor'],
            'Maaş kaydı yok.',
          ),
        )
      : empty('Bu ay maaş kaydı yok.', 'wallet');
  }
  return h(
    'div',
    {},
    segmented(
      [
        { id: 'ekip', label: 'Ekip' },
        { id: 'mesai', label: 'Mesai' },
        { id: 'maas', label: 'Maaş & Avans' },
      ],
      staffTab,
      (v) => {
        staffTab = v;
        ctx.rerender();
      },
    ),
    body,
  );
}

function raporlar(ctx: Ctx) {
  const rows = ctx.snap.sales?.daily ?? [];
  const range = periodRange(reportPeriod, today(ctx));
  const sel = inRange(rows, range);
  const t = sum(sel);
  const download = () => {
    const blob = new Blob([toCsv(sel)], { type: 'text/csv;charset=utf-8' });
    const a = h('a', { href: URL.createObjectURL(blob), download: `nohut-satis-${range[0]}_${range[1]}.csv` });
    a.click();
    URL.revokeObjectURL(a.href);
  };
  return h(
    'div',
    {},
    segmented(
      [
        { id: 'day', label: 'Günlük' },
        { id: 'week', label: 'Haftalık' },
        { id: 'month', label: 'Aylık' },
        { id: 'year', label: 'Yıllık' },
      ],
      reportPeriod,
      (v) => {
        reportPeriod = v;
        ctx.rerender();
      },
    ),
    h('p', { class: 'muted small' }, `${shortDay(range[0])} – ${shortDay(range[1])} · ${sel.length} gün veri`),
    h(
      'div',
      { class: 'kpis' },
      kpi('Brüt satış', money(t.grossCents)),
      kpi('Kasa tahsilatı', money(t.collectedCents)),
      kpi('Platform', money(t.platformCents)),
      kpi('İade', money(t.refundCents)),
    ),
    h(
      'div',
      { class: 'action-grid' },
      actionButton(ctx, { label: 'CSV İndir', op: 'reports.export', icon: 'report', needsPos: false, onclick: download }),
      actionButton(ctx, {
        label: 'Tam Rapor PDF',
        op: 'reports.export',
        icon: 'report',
        primary: true,
        onclick: async () => report(await ctx.send('finance', { operation: 'report', from: range[0], to: range[1], requestId: newRequestId() })),
      }),
    ),
    sel.length
      ? list(sel.slice().reverse(), (r) => [shortDay(r.day), `${r.orderCount} sipariş · nakit ${money(r.cashCents)} · kart ${money(r.cardCents)}`, money(r.grossCents)], '')
      : empty('Bu dönem için veri yok.', 'report'),
  );
}

function entegrasyonlar(ctx: Ctx) {
  const ints = ctx.snap.integrations ?? [];
  const reviews = ctx.snap.overview?.reviews ?? [];
  const avg = reviews.filter((r) => r.rating).reduce((n, r, _, a) => n + (r.rating ?? 0) / a.length, 0);
  return h(
    'div',
    {},
    ints.length
      ? h(
          'div',
          { class: 'list' },
          ...ints.map((i) =>
            h(
              'div',
              { class: 'list-row static' },
              h('span', { class: 'row-ic' }, ic('link', 20)),
              h('span', { class: 'grow' }, h('strong', {}, i.name), i.detail ? h('small', {}, i.detail) : null),
              h('span', { class: `tag ${i.state === 'Aktif' ? 'good' : i.state === 'Yapılandırılmadı' ? 'bad' : 'gold'}` }, i.state),
            ),
          ),
        )
      : empty('Entegrasyon durumu kasadan henüz gelmedi.', 'link'),
    section(
      `Müşteri yorumları${reviews.length ? ` · ort. ${avg.toFixed(1)} ★ (${reviews.length})` : ''}`,
      reviews.length
        ? h(
            'div',
            { class: 'list' },
            ...reviews.slice(0, 20).map((r) =>
              h(
                'div',
                { class: 'list-row static col' },
                h('span', { class: 'stars' }, '★'.repeat(Math.round(r.rating ?? 0)) + '☆'.repeat(5 - Math.round(r.rating ?? 0)), h('small', { class: 'muted' }, ` ${shortDay(r.createdAt.slice(0, 10))}`)),
                r.comment ? h('p', {}, r.comment) : null,
                actionButton(ctx, {
                  label: 'Yanıtla',
                  op: 'reviews.reply',
                  onclick: () => {
                    const text = h('textarea', { rows: 3, 'aria-label': 'Yanıt' }) as HTMLTextAreaElement;
                    openSheet(
                      'Yoruma yanıt',
                      text,
                      actionButton(ctx, {
                        label: 'Gönder',
                        op: 'reviews.reply',
                        primary: true,
                        onclick: async () => {
                          closeSheet();
                          report(await ctx.send('review', { operation: 'ownerGoogleReply', reviewId: r.reviewId, text: text.value, requestId: newRequestId() }));
                        },
                      }),
                    );
                  },
                }),
              ),
            ),
          )
        : empty('Yorum yok.', 'star'),
    ),
  );
}

function kullanicilar(ctx: Ctx) {
  const users = ctx.snap.users ?? [];
  if (!users.length) return empty('Kullanıcı listesi yalnız sahibe gösterilir.', 'shield');
  // Windows-only operations are not delegable from the apps and not shown (§22.3).
  const delegable = operations.filter((op) => op.sensitivity !== 'ownerOnly' && op.clients.some((c) => c !== 'windows'));
  return h(
    'div',
    { class: 'list' },
    ...users.map((u) =>
      h(
        'button',
        {
          type: 'button',
          class: 'list-row',
          onclick: () =>
            openSheet(
              u.name,
              h(
                'div',
                {},
                h('p', { class: 'muted' }, `${u.role} · ${u.devices} cihaz · ${u.active ? 'Aktif' : 'Pasif'}`),
                h(
                  'div',
                  { class: 'grants' },
                  ...delegable.map((op) =>
                    h(
                      'label',
                      { class: 'check' },
                      h('input', {
                        type: 'checkbox',
                        checked: u.grants.includes(op.id),
                        disabled: !ctx.can('users.manage'),
                        onchange: async (e: Event) => {
                          const on = (e.target as HTMLInputElement).checked;
                          (e.target as HTMLInputElement).checked = !on; // stays as-is until Windows confirms
                          report(await ctx.send('admin', { type: 'permission_update', userId: u.id, operation: op.id, granted: on, requestId: newRequestId() }));
                        },
                      }),
                      h('span', {}, op.id, findOperation(op.id)?.sensitivity === 'elevated' ? h('small', { class: 'tag gold' }, 'onaylı') : null),
                    ),
                  ),
                ),
              ),
              h(
                'div',
                { class: 'action-grid' },
                actionButton(ctx, { label: 'Şifre Sıfırla', op: 'users.manage', onclick: async () => report(await ctx.send('admin', { type: 'password_reset', userId: u.id, requestId: newRequestId() })) }),
                actionButton(ctx, { label: 'PIN Sıfırla', op: 'users.manage', onclick: async () => report(await ctx.send('admin', { type: 'pin_reset', userId: u.id, requestId: newRequestId() })) }),
                actionButton(ctx, { label: 'Cihazları Kapat', op: 'users.manage', onclick: async () => report(await ctx.send('admin', { type: 'devices_revoke', userId: u.id, requestId: newRequestId() })) }),
                actionButton(ctx, {
                  label: u.active ? 'Pasifleştir' : 'Etkinleştir',
                  op: 'users.manage',
                  onclick: async () => report(await ctx.send('admin', { type: 'user_active', userId: u.id, active: !u.active, requestId: newRequestId() })),
                }),
              ),
            ),
        },
        h('span', { class: 'avatar sm' }, u.name.slice(0, 1)),
        h('span', { class: 'grow' }, h('strong', {}, u.name), h('small', {}, `${u.role} · ${u.grants.length} yetki · ${u.devices} cihaz`)),
        h('span', { class: `tag ${u.active ? 'good' : 'bad'}` }, u.active ? 'Aktif' : 'Pasif'),
      ),
    ),
  );
}

function gecmis(ctx: Ctx) {
  const a = ctx.snap.audit ?? [];
  if (!a.length) return empty('İşlem kaydı yok.', 'history');
  return h(
    'div',
    { class: 'list' },
    ...a.map((x) =>
      h('div', { class: 'list-row static' }, h('span', { class: 'grow' }, h('strong', {}, x.action), h('small', {}, `${x.actor} · ${shortDay(x.at.slice(0, 10))} ${hhmm(x.at)}${x.detail ? ` · ${x.detail}` : ''}`))),
    ),
  );
}

function hesaplar(ctx: Ctx) {
  const o = ctx.snap.overview;
  if (!o?.openAccounts.length) return empty('Açık hesap yok.', 'check');
  return h(
    'div',
    {},
    h('div', { class: 'kpis' }, kpi('Toplam açık bakiye', money(o.openAccounts.reduce((n, x) => n + (x.dueCents ?? 0), 0)), `${o.openAccounts.length} hesap`, 'gold')),
    h('div', { class: 'list' }, ...o.openAccounts.map(accountRow)),
  );
}

function daha(ctx: Ctx) {
  const items: [string, string, string, string?][] = [
    ['raporlar', 'Raporlar', 'report', 'reports.view'],
    ['hesaplar', 'Açık Hesaplar', 'wallet', 'accounts.view'],
    ['menu', 'Menü & Kampanya', 'menu', 'menu.view'],
    ['entegrasyonlar', 'Entegrasyonlar', 'link', 'integrations.view'],
    ['kullanicilar', 'Kullanıcılar & Yetkiler', 'shield', 'users.manage'],
    ['gecmis', 'İşlem Geçmişi', 'history', 'audit.view'],
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

export const yonetici: AppDef = {
  name: 'Nohut Yönetici',
  client: 'yonetici',
  home: 'genel',
  nav: () => [
    { id: 'genel', label: 'Genel Bakış', icon: 'dashboard' },
    { id: 'satislar', label: 'Satışlar', icon: 'chart' },
    { id: 'finans', label: 'Finans', icon: 'finance' },
    { id: 'personel', label: 'Personel', icon: 'people' },
    { id: 'daha', label: 'Daha Fazla', icon: 'more' },
  ],
  navOf: (route) =>
    ({ raporlar: 'daha', hesaplar: 'daha', menu: 'daha', entegrasyonlar: 'daha', kullanicilar: 'daha', gecmis: 'daha', profil: 'daha' } as Record<string, string>)[route] ?? route,
  screen(route, _params, ctx) {
    switch (route) {
      case 'genel':
        return { title: 'Genel Bakış', body: genel(ctx) };
      case 'satislar':
        return { title: 'Satışlar & Yoğunluk', body: satislar(ctx) };
      case 'finans':
        return {
          title: 'Finans',
          action: ctx.can('finance.edit') ? h('button', { type: 'button', class: 'btn small gold', onclick: () => expenseSheet(ctx) }, ic('plus', 16), 'Gider') : undefined,
          body: finans(ctx),
        };
      case 'personel':
        return { title: 'Personel', body: personelScreen(ctx) };
      case 'daha':
        return { title: 'Daha Fazla', body: daha(ctx) };
      case 'raporlar':
        return { title: 'Raporlar', back: 'daha', body: raporlar(ctx) };
      case 'hesaplar':
        return { title: 'Açık Hesaplar', back: 'daha', body: hesaplar(ctx) };
      case 'menu':
        return { title: 'Menü & Kampanya', back: 'daha', body: menuScreen(ctx, menuState) };
      case 'entegrasyonlar':
        return { title: 'Entegrasyonlar', back: 'daha', body: entegrasyonlar(ctx) };
      case 'kullanicilar':
        return { title: 'Kullanıcılar & Yetkiler', back: 'daha', body: kullanicilar(ctx) };
      case 'gecmis':
        return { title: 'İşlem Geçmişi', back: 'daha', body: gecmis(ctx) };
      case 'profil':
        return { title: 'Profil', back: 'daha', body: profileScreen(ctx) };
      default:
        return null;
    }
  },
};
