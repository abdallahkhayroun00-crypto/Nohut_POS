// Small DOM toolkit + the application shell (app bar, status indicators,
// bottom bar on phones / sidebar on tablets and desktops, sheets, toasts).
import type { CommandKind, CommandResult } from './commands';
import { freshness } from './freshness';
import { icon } from './icons';
import type { Snapshot } from './model';
import { type Client, canPerform } from './permissions';

type Child = Node | string | null | undefined | false;

export function h<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs: Record<string, string | number | boolean | ((e: Event) => void) | undefined> = {},
  ...children: (Child | Child[])[]
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === undefined || v === false) continue;
    if (typeof v === 'function') node.addEventListener(k.replace(/^on/, ''), v);
    else if (k === 'class') node.className = String(v);
    else if (k === 'style')
      // CSSOM, not a style attribute: allowed by the strict CSP (style-src 'self').
      for (const decl of String(v).split(';')) {
        const i = decl.indexOf(':');
        if (i > 0) node.style.setProperty(decl.slice(0, i).trim(), decl.slice(i + 1).trim());
      }
    else if (v === true) node.setAttribute(k, '');
    else node.setAttribute(k, String(v));
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    node.append(typeof c === 'string' ? document.createTextNode(c) : c);
  }
  return node;
}

export const ic = icon;

export interface NavItem {
  id: string;
  label: string;
  icon: string;
  badge?: number;
}

export interface Screen {
  title: string;
  /** Optional action in the app bar (e.g. "+ Gel-Al"). */
  action?: HTMLElement;
  body: HTMLElement;
  back?: string;
}

export interface Ctx {
  snap: Snapshot;
  client: Client;
  now: Date;
  fixtures: boolean;
  can(op: string): boolean;
  go(route: string): void;
  rerender(): void;
  send(kind: CommandKind, payload: object): Promise<CommandResult>;
}

export function makeCan(snap: Snapshot, client: Client) {
  const grants = new Set(snap.session.grants);
  return (op: string) => canPerform(op, grants, { isOwner: snap.session.isOwner }, client);
}

/** Compact read-only indicators (§22.3) — no sync/backup controls. */
function statusChip(ctx: Ctx): HTMLElement {
  const f = freshness(ctx.snap.asOf, ctx.now, ctx.snap.posOnline);
  const cls = !ctx.snap.posOnline ? 'off' : f.level === 'fresh' ? 'ok' : 'warn';
  const text = !ctx.snap.posOnline ? 'Kasa çevrimdışı' : f.level === 'fresh' ? 'Kasa bağlı' : f.label;
  return h('span', { class: `chip ${cls}`, role: 'status', title: `Son senkronizasyon: ${f.label}` }, h('span', { class: 'dot' }), text);
}

export function shell(
  ctx: Ctx,
  appName: string,
  nav: NavItem[],
  current: string,
  screen: Screen,
): HTMLElement[] {
  const logo = h('img', { class: 'logo', src: '/icons/icon-192.png', alt: '' });
  const bar = h(
    'header',
    { class: 'appbar' },
    screen.back
      ? h('button', { class: 'icon-btn back', 'aria-label': 'Geri', onclick: () => ctx.go(screen.back!) }, ic('back', 22))
      : logo,
    h('div', { class: 'titles' }, h('span', { class: 'app' }, appName), h('h1', {}, screen.title)),
    screen.action ?? null,
    statusChip(ctx),
  );
  const banners: HTMLElement[] = [];
  if (ctx.fixtures)
    banners.push(h('div', { class: 'banner fixture' }, 'ÖRNEK VERİ — geliştirme ve test görünümü. Gerçek restoran verisi değildir.'));
  const f = freshness(ctx.snap.asOf, ctx.now, ctx.snap.posOnline);
  if (!ctx.snap.posOnline)
    banners.push(h('div', { class: 'banner off' }, ic('alert', 18), `${f.label}. Kasa gerektiren işlemler kapalı.`));
  else if (f.level === 'stale') banners.push(h('div', { class: 'banner warn' }, ic('clock', 18), `Veriler güncel olmayabilir — ${f.label}`));
  if (ctx.snap.pendingCommands > 0)
    banners.push(h('div', { class: 'banner info' }, ic('queue', 18), `${ctx.snap.pendingCommands} işlem kasanın onayını bekliyor`));

  const navEl = h(
    'nav',
    { class: 'nav', 'aria-label': 'Bölümler' },
    h('div', { class: 'brand' }, h('img', { src: '/icons/icon-192.png', alt: '' }), h('span', {}, appName)),
    ...nav.map((n) =>
      h(
        'button',
        { type: 'button', 'aria-current': n.id === current ? 'page' : undefined, onclick: () => ctx.go(n.id) },
        h('span', { class: 'nav-ic' }, ic(n.icon, 22), n.badge ? h('span', { class: 'badge' }, String(n.badge)) : null),
        h('span', { class: 'nav-label' }, n.label),
      ),
    ),
  );
  const main = h('main', { id: 'main' }, ...banners, screen.body);
  return [navEl, h('div', { class: 'content' }, bar, main)];
}

let sheetEl: HTMLElement | null = null;

export function closeSheet() {
  sheetEl?.remove();
  sheetEl = null;
  document.body.classList.remove('sheet-open');
}

export function openSheet(title: string, body: HTMLElement, footer?: HTMLElement) {
  closeSheet();
  const panel = h(
    'div',
    { class: 'sheet', role: 'dialog', 'aria-modal': 'true', 'aria-label': title },
    h('div', { class: 'sheet-head' }, h('h2', {}, title), h('button', { class: 'icon-btn', 'aria-label': 'Kapat', onclick: closeSheet }, ic('close', 22))),
    h('div', { class: 'sheet-body' }, body),
    footer ? h('div', { class: 'sheet-foot' }, footer) : null,
  );
  sheetEl = h('div', { class: 'scrim', onclick: (e: Event) => e.target === sheetEl && closeSheet() }, panel);
  document.body.append(sheetEl);
  document.body.classList.add('sheet-open');
  panel.querySelector<HTMLElement>('input,button:not(.icon-btn)')?.focus();
}

export function toast(message: string, kind: 'ok' | 'warn' | 'err' = 'ok') {
  const t = h('div', { class: `toast ${kind}`, role: 'status' }, message);
  document.body.append(t);
  setTimeout(() => t.remove(), 4200);
}

/** Shows a command result honestly: only `confirmed` reads as success. */
export function report(r: CommandResult) {
  toast(r.message, r.state === 'confirmed' ? 'ok' : r.state === 'pending' ? 'warn' : 'err');
}

export function empty(text: string, iconName = 'check'): HTMLElement {
  return h('div', { class: 'empty' }, ic(iconName, 28), h('p', {}, text));
}

export function section(title: string, ...children: (Child | Child[])[]): HTMLElement {
  return h('section', { class: 'block' }, h('h2', { class: 'block-title' }, title), ...children);
}

export function kpi(label: string, value: string, sub?: string, tone?: 'good' | 'bad' | 'gold'): HTMLElement {
  return h('div', { class: `kpi ${tone ?? ''}` }, h('span', { class: 'kpi-label' }, label), h('strong', {}, value), sub ? h('small', {}, sub) : null);
}

/** A button that needs a grant and (optionally) the live Windows POS. */
export function actionButton(
  ctx: Ctx,
  opts: { label: string; op: string; needsPos?: boolean; icon?: string; primary?: boolean; onclick: () => void },
): HTMLElement {
  const allowed = ctx.can(opts.op);
  const posBlocked = opts.needsPos !== false && !ctx.snap.posOnline;
  const reason = !allowed ? 'Bu işlem için yetkiniz yok' : posBlocked ? 'Kasa çevrimdışı' : undefined;
  return h(
    'button',
    {
      type: 'button',
      class: `btn ${opts.primary ? 'primary' : ''}`,
      disabled: Boolean(reason),
      title: reason,
      onclick: reason ? undefined : opts.onclick,
    },
    opts.icon ? ic(opts.icon, 18) : null,
    opts.label,
    reason ? h('small', { class: 'why' }, reason) : null,
  );
}

export function segmented<T extends string>(options: { id: T; label: string }[], value: T, onChange: (v: T) => void): HTMLElement {
  return h(
    'div',
    { class: 'seg', role: 'tablist' },
    ...options.map((o) =>
      h('button', { type: 'button', role: 'tab', 'aria-selected': o.id === value ? 'true' : 'false', onclick: () => onChange(o.id) }, o.label),
    ),
  );
}

/** Horizontal bar list (accessible: numbers are printed). */
export function bars(rows: { label: string; value: number; display: string }[]): HTMLElement {
  const max = Math.max(1, ...rows.map((r) => r.value));
  return h(
    'div',
    { class: 'bars' },
    ...rows.map((r) =>
      h(
        'div',
        { class: 'bar-row' },
        h('span', { class: 'bar-label' }, r.label),
        h('span', { class: 'bar-track' }, h('span', { class: 'bar-fill', style: `width:${(r.value / max) * 100}%` })),
        h('span', { class: 'bar-value' }, r.display),
      ),
    ),
  );
}

/** Vertical column chart for hourly / daily series. */
export function columns(values: number[], labels: string[], format: (v: number) => string, highlight?: number): HTMLElement {
  const max = Math.max(1, ...values);
  return h(
    'div',
    { class: 'cols', role: 'img', 'aria-label': values.map((v, i) => `${labels[i]}: ${format(v)}`).join(', ') },
    ...values.map((v, i) =>
      h(
        'div',
        { class: `col ${i === highlight ? 'hi' : ''}`, title: `${labels[i]} · ${format(v)}` },
        h('span', { class: 'col-fill', style: `height:${Math.max(v ? 4 : 0, (v / max) * 100)}%` }),
        h('span', { class: 'col-label' }, labels[i] ?? ''),
      ),
    ),
  );
}
