// Aggregations over Windows-computed daily rows (no re-derivation of order
// totals). Pure and tested.
import type { DailySales } from './model';

export type Period = 'day' | 'week' | 'month' | 'year' | 'custom';

export function addDays(day: string, n: number): string {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

/** Inclusive [from, to] for a period ending on `day` (week = Monday-based). */
export function periodRange(period: Exclude<Period, 'custom'>, day: string): [string, string] {
  if (period === 'day') return [day, day];
  if (period === 'week') {
    const wd = (new Date(`${day}T00:00:00Z`).getUTCDay() + 6) % 7;
    const from = addDays(day, -wd);
    return [from, addDays(from, 6)];
  }
  if (period === 'month') {
    const from = `${day.slice(0, 7)}-01`;
    const next = new Date(`${from}T00:00:00Z`);
    next.setUTCMonth(next.getUTCMonth() + 1);
    return [from, addDays(next.toISOString().slice(0, 10), -1)];
  }
  return [`${day.slice(0, 4)}-01-01`, `${day.slice(0, 4)}-12-31`];
}

/** The part of a period that has happened: [from, min(to, today)]. */
export function toDate([from, to]: [string, string], today: string): [string, string] {
  return [from, to < today ? to : today];
}

function shiftMonths(day: string, n: number): string {
  const [y, m, d] = day.split('-').map(Number) as [number, number, number];
  const target = new Date(Date.UTC(y, m - 1 + n, 1));
  const last = new Date(Date.UTC(target.getUTCFullYear(), target.getUTCMonth() + 1, 0)).getUTCDate();
  target.setUTCDate(Math.min(d, last));
  return target.toISOString().slice(0, 10);
}

/** The same days one period earlier (week −7 d, month −1 mo, year −1 y), so
 *  a period in progress is compared like-for-like. */
export function samePeriodBefore(period: Exclude<Period, 'custom'>, [from, to]: [string, string]): [string, string] {
  if (period === 'day') return [addDays(from, -1), addDays(to, -1)];
  if (period === 'week') return [addDays(from, -7), addDays(to, -7)];
  const months = period === 'month' ? -1 : -12;
  return [shiftMonths(from, months), shiftMonths(to, months)];
}

/** The same-length period immediately before [from, to]. */
export function previousRange([from, to]: [string, string]): [string, string] {
  const len = Math.round((Date.parse(to) - Date.parse(from)) / 86400000) + 1;
  return [addDays(from, -len), addDays(from, -1)];
}

export function inRange(rows: DailySales[], [from, to]: [string, string]): DailySales[] {
  return rows.filter((r) => r.day >= from && r.day <= to);
}

export interface Totals {
  grossCents: number;
  collectedCents: number;
  cashCents: number;
  cardCents: number;
  platformCents: number;
  refundCents: number;
  orderCount: number;
  masaCount: number;
  gelalCount: number;
  onlineCount: number;
  avgCents: number;
}

export function sum(rows: DailySales[]): Totals {
  const t = rows.reduce(
    (a, r) => ({
      grossCents: a.grossCents + r.grossCents,
      cashCents: a.cashCents + r.cashCents,
      cardCents: a.cardCents + r.cardCents,
      platformCents: a.platformCents + r.platformCents,
      refundCents: a.refundCents + r.refundCents,
      orderCount: a.orderCount + r.orderCount,
      masaCount: a.masaCount + r.masaCount,
      gelalCount: a.gelalCount + r.gelalCount,
      onlineCount: a.onlineCount + r.onlineCount,
    }),
    { grossCents: 0, cashCents: 0, cardCents: 0, platformCents: 0, refundCents: 0, orderCount: 0, masaCount: 0, gelalCount: 0, onlineCount: 0 },
  );
  // Collections = money actually received at the till (cash + card); gross
  // sales and collections are never mixed (§22, owner rule).
  return { ...t, collectedCents: t.cashCents + t.cardCents, avgCents: t.orderCount ? Math.round(t.grossCents / t.orderCount) : 0 };
}

/** Percentage change, or null when there is no baseline. */
export function delta(current: number, previous: number): number | null {
  if (!previous) return null;
  return Math.round(((current - previous) / previous) * 1000) / 10;
}

/** Buckets for a chart: days for week/month/custom ≤ 62 days, months for longer. */
export function series(rows: DailySales[], [from, to]: [string, string]): { label: string; value: number }[] {
  const days = Math.round((Date.parse(to) - Date.parse(from)) / 86400000) + 1;
  if (days <= 62) {
    const out: { label: string; value: number }[] = [];
    for (let d = from; d <= to; d = addDays(d, 1)) {
      out.push({ label: d.slice(8, 10), value: rows.find((r) => r.day === d)?.grossCents ?? 0 });
    }
    return out;
  }
  const byMonth = new Map<string, number>();
  for (const r of rows) byMonth.set(r.day.slice(0, 7), (byMonth.get(r.day.slice(0, 7)) ?? 0) + r.grossCents);
  const out: { label: string; value: number }[] = [];
  for (let m = from.slice(0, 7); m <= to.slice(0, 7); ) {
    out.push({ label: m.slice(5, 7), value: byMonth.get(m) ?? 0 });
    const d = new Date(`${m}-01T00:00:00Z`);
    d.setUTCMonth(d.getUTCMonth() + 1);
    m = d.toISOString().slice(0, 7);
  }
  return out;
}

export function peakHours(hourly: number[], n = 3): number[] {
  return hourly
    .map((v, h) => [v, h] as const)
    .filter(([v]) => v > 0)
    .sort((a, b) => b[0] - a[0] || a[1] - b[1])
    .slice(0, n)
    .map(([, h]) => h);
}

export function toCsv(rows: DailySales[]): string {
  const head = ['Tarih', 'Brüt satış', 'Nakit', 'Kart', 'Platform', 'İade', 'Sipariş', 'Masa', 'Gel-Al', 'Online'];
  const tl = (c: number) => (c / 100).toFixed(2).replace('.', ',');
  const lines = rows.map((r) =>
    [r.day, tl(r.grossCents), tl(r.cashCents), tl(r.cardCents), tl(r.platformCents), tl(r.refundCents), r.orderCount, r.masaCount, r.gelalCount, r.onlineCount].join(';'),
  );
  return `﻿${[head.join(';'), ...lines].join('\r\n')}\r\n`;
}
