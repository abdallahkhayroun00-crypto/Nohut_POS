// Presentation helpers only — no business rules.
import type { Order, OrderLine, Product } from './model';

const tl = new Intl.NumberFormat('tr-TR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

export function money(cents: number): string {
  return `${tl.format(cents / 100)} ₺`;
}

/** Same conversion as Windows `asCents`: TL value → integer kuruş. */
export function asCents(tlValue: number | undefined): number {
  return Math.round((tlValue ?? 0) * 100);
}

const two = (n: number) => String(n).padStart(2, '0');

/** Europe/Istanbul (UTC+3, no DST) wall-clock HH:MM. */
export function hhmm(iso: string | undefined): string {
  if (!iso) return '—';
  const t = new Date(iso);
  if (Number.isNaN(t.getTime())) return '—';
  const l = new Date(t.getTime() + 3 * 3600 * 1000);
  return `${two(l.getUTCHours())}:${two(l.getUTCMinutes())}`;
}

export function minutesBetween(fromIso: string | undefined, now: Date): number {
  if (!fromIso) return 0;
  return Math.max(0, Math.floor((now.getTime() - new Date(fromIso).getTime()) / 60000));
}

export function duration(minutes: number): string {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return h ? `${h} sa ${m} dk` : `${m} dk`;
}

/** Same filter as Android `orderLines`: voided and correction lines hidden. */
export function orderLines(order: Order): OrderLine[] {
  return order.batches.flatMap((b) => b.lines.filter((l) => !l.voided && !l.correction));
}

export function orderLabel(order: Order): string {
  const n = order.dailyNumber ?? order.id;
  return order.source === 'Masa' ? `#${n} · Masa ${order.table ?? '—'}` : `#${n} · Gel-Al`;
}

/** Turkish-aware, accent-insensitive search used by the composer. */
export function normalize(s: string): string {
  return s
    .toLocaleLowerCase('tr-TR')
    .replace(/ı/g, 'i')
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '');
}

export function searchProducts(products: Product[], query: string): Product[] {
  const q = normalize(query.trim());
  const active = products.filter((p) => p.active !== false);
  const hits = q ? active.filter((p) => normalize(`${p.name} ${p.description?.tr ?? ''}`).includes(q)) : active;
  // Campaigns first, then menu order (spec §22.2).
  return [...hits.filter((p) => p.category === 'campaign'), ...hits.filter((p) => p.category !== 'campaign')];
}

export const categoryLabels: Record<string, string> = {
  campaign: 'Kampanyalar',
  wrap: 'Dürümler',
  plate: 'Tabaklar',
  side: 'Yan Ürünler',
  drink: 'İçecekler',
  dessert: 'Tatlılar',
};

export function categoryLabel(id: string): string {
  return categoryLabels[id] ?? id.charAt(0).toLocaleUpperCase('tr-TR') + id.slice(1);
}

export function shortDay(day: string): string {
  const [y, m, d] = day.split('-');
  return `${d}.${m}.${y}`;
}
