// Remote commands (spec §11.2, §22.4). Payloads use exactly the fields the
// Windows POS already accepts from the Android apps (staff_commands.dart:
// submitStaffOrder / submitStaffAction). The Windows POS recalculates every
// price and balance; nothing here is authoritative.
//
// A command is shown as done ONLY when the channel reports `confirmed`
// (authoritative execution on Windows). Until the Phase 5 cloud command
// channel is live, the channel answers `unavailable` and the UI says so.
import type { Product } from './model';
import { asCents } from './format';

export interface CartLine {
  product: Product;
  qty: number;
  note: string;
  removed: string[];
}

export function cartTotalCents(cart: CartLine[]): number {
  return cart.reduce((n, l) => n + l.qty * asCents(l.product.price), 0);
}

export function newRequestId(): string {
  return crypto.randomUUID();
}

export interface OrderTarget {
  source: 'Masa' | 'Gel-Al';
  table?: number;
  orderId?: number;
  pickupChannel?: 'Tezgahtan' | 'Telefon';
  customer?: { name: string; phone: string; time: string };
}

export function orderRequest(
  target: OrderTarget,
  cart: CartLine[],
  ctx: { requestId: string; expectedRevision: number; staffId: number | null },
) {
  if (!cart.length) throw new Error('Sepet boş');
  if (target.source === 'Masa' && !target.table) throw new Error('Masa seçilmedi');
  return {
    requestId: ctx.requestId,
    expectedRevision: ctx.expectedRevision,
    staffId: ctx.staffId,
    source: target.source,
    table: target.source === 'Masa' ? target.table : null,
    ...(target.source === 'Masa' && target.orderId ? { orderId: target.orderId } : {}),
    pickupChannel: target.pickupChannel ?? 'Tezgahtan',
    ...(target.source === 'Gel-Al' ? { customer: target.customer ?? { name: '', phone: '', time: '' } } : {}),
    lines: cart.map((l) => ({
      productId: l.product.id,
      qty: l.qty,
      expectedPriceCents: asCents(l.product.price),
      note: l.note,
      removed: l.removed,
    })),
  };
}

export type PayMethod = 'Nakit' | 'Kart' | 'Karışık';

export interface PaymentInput {
  method: PayMethod;
  amountCents: number;
  receivedCents?: number;
  cashCents?: number;
}

/** Display-only change; Windows validates the payment. */
export function changeCents(p: PaymentInput): number {
  if (p.method !== 'Nakit' || p.receivedCents === undefined) return 0;
  return Math.max(0, p.receivedCents - p.amountCents);
}

export function paymentProblem(p: PaymentInput, dueCents: number): string | null {
  if (!Number.isInteger(p.amountCents) || p.amountCents <= 0) return 'Tutar girin';
  if (p.amountCents > dueCents) return 'Tutar kalan bakiyeden fazla';
  if (p.method === 'Nakit' && p.receivedCents !== undefined && p.receivedCents < p.amountCents)
    return 'Alınan nakit tutardan az';
  if (p.method === 'Karışık') {
    const cash = p.cashCents ?? 0;
    if (cash <= 0 || cash >= p.amountCents) return 'Nakit kısmı 0 ile toplam arasında olmalı';
  }
  return null;
}

export function paymentAction(
  orderId: number,
  p: PaymentInput,
  ctx: { requestId: string; expectedRevision: number; staffId: number | null },
  opts: { printReceipt: boolean; guestId?: number; shares?: Record<string, number> } = { printReceipt: false },
) {
  const base = {
    requestId: ctx.requestId,
    expectedRevision: ctx.expectedRevision,
    staffId: ctx.staffId,
    orderId,
    confirmed: true,
    ...(opts.guestId !== undefined ? { guestId: opts.guestId } : {}),
  };
  const received = p.method === 'Nakit' && p.receivedCents !== undefined ? { receivedCents: p.receivedCents } : {};
  const cash = p.method === 'Karışık' ? { cashCents: p.cashCents } : {};
  if (opts.shares)
    // Item-based split (Windows `payProducts`).
    return { ...base, action: 'payProducts', method: p.method, amountCents: p.amountCents, shares: opts.shares, ...received, ...cash };
  if (p.method === 'Karışık')
    return { ...base, action: 'payMixed', amountCents: p.amountCents, ...cash, printReceipt: opts.printReceipt };
  return { ...base, action: 'pay', method: p.method, amountCents: p.amountCents, ...received, printReceipt: opts.printReceipt };
}

/** Other order actions exactly as Windows `submitStaffAction` accepts them. */
export function orderAction(
  orderId: number,
  action: 'move' | 'close' | 'status' | 'splitEqual',
  ctx: { requestId: string; expectedRevision: number; staffId: number | null },
  extra: { table?: number; count?: number } = {},
) {
  return { requestId: ctx.requestId, expectedRevision: ctx.expectedRevision, staffId: ctx.staffId, orderId, action, ...extra };
}

export type CommandKind = 'order' | 'action' | 'platform' | 'shift' | 'print' | 'menu' | 'finance' | 'staff' | 'admin' | 'review';

export type CommandState = 'confirmed' | 'pending' | 'rejected' | 'unavailable';

export interface CommandResult {
  state: CommandState;
  message: string;
  requestId?: string;
}

export interface CommandChannel {
  send(kind: CommandKind, payload: object): Promise<CommandResult>;
  status?(requestId: string): Promise<CommandResult>;
}

/** Phase 5 replaces this with the authenticated cloud command queue. */
export const offlineChannel: CommandChannel = {
  async send() {
    return {
      state: 'unavailable',
      message: 'Uzaktan işlem kanalı henüz açık değil. İşlem yapılmadı — kasadan yapın.',
    };
  },
};
