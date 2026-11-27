// Typed projection consumed by both PWAs. The shapes are the SAME ones the
// Windows POS already produces for the native Android apps, so no business
// rule is re-implemented here:
//   StaffState    ← lan_server.dart `_staffState` (+ staffNotices)
//   OwnerOverview ← finance_sync_server.dart `ownerOverview(day)`
//   MonthView     ← finance_sync_server.dart `monthView(month)`
// Totals, paid and due amounts are computed by the Windows POS (orderTotalCents,
// orderPaidCents, orderDueCents); the apps only display them.

export type Json = Record<string, unknown>;

export interface Product {
  id: number;
  name: string;
  category: string;
  /** TL, as stored by the Windows POS (`asCents` converts). */
  price: number;
  active?: boolean;
  campaignId?: string;
  description?: { tr?: string };
  /** Removable ingredients, when the product defines them. */
  ingredients?: string[];
  soldOut?: boolean;
}

export interface OrderLine {
  /** Stable line key used by item-based payment (`payProducts`). */
  key?: string;
  productId?: number;
  name: string;
  qty: number;
  /** TL per unit (Windows stores `price`). */
  price: number;
  note?: string;
  removed?: string[];
  voided?: boolean;
  correction?: boolean;
  customItem?: boolean;
}

export interface Batch {
  id?: number | string;
  at?: string;
  staff?: string;
  lines: OrderLine[];
}

export interface GuestCheck {
  id: number;
  name?: string;
  balanceCents: number;
}

export interface Customer {
  name?: string;
  /** Only present when the user holds `pickup.contact.view` (server-filtered). */
  phone?: string;
  /** Promised pickup time, HH:MM. */
  time?: string;
  channel?: 'Tezgahtan' | 'Telefon';
}

export interface Order {
  id: number;
  dailyNumber?: number;
  numberDay?: string;
  source: 'Masa' | 'Gel-Al';
  table?: number;
  createdAt: string;
  serviceStatus?: string;
  customer?: Customer;
  batches: Batch[];
  totalCents: number;
  paidCents: number;
  dueCents: number;
  guestChecks: GuestCheck[];
  serviceStartedAt?: string;
  readyAt?: string;
  deliveredAt?: string;
}

export type Platform = 'Trendyol Go' | 'Yemeksepeti' | 'Migros Yemek';

export interface OnlineLine {
  name: string;
  qty: number;
  unitPriceCents?: number;
  options?: string[];
  removed?: string[];
  extras?: string[];
}

export interface OnlineOrder {
  platform: Platform;
  orderNumber: string;
  dailyNumber?: number;
  status: string;
  createdAt: string;
  totalCents: number;
  paymentType?: string;
  customerNote?: string;
  preparationMinutes?: number;
  kitchenPrintState?: string;
  lines: OnlineLine[];
}

export interface StaffNotice {
  id: number | string;
  staff?: string;
  action: string;
  table?: number;
  orderId?: number;
  at: string;
}

export interface FloorCell {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface StaffState {
  floorPlan: Record<string, FloorCell>;
  employees: { id: number; name: string; active?: boolean }[];
  localMenu: Product[];
  orders: Order[];
  onlineOrders: OnlineOrder[];
  staffNotices: StaffNotice[];
  /** Which platform operations the Windows POS can actually perform now. */
  platformWritable: Partial<Record<Platform, boolean>>;
}

export interface OverviewOrder {
  id?: number;
  dailyNumber?: number;
  orderNumber?: string;
  source: string;
  table?: number;
  createdAt: string;
  closed?: boolean;
  cancelled?: boolean;
  status?: string;
  totalCents: number;
  paidCents?: number;
  dueCents?: number;
  owner?: string;
}

export interface OwnerOverview {
  day: string;
  cashCents: number;
  cardCents: number;
  orderCount: number;
  orders: OverviewOrder[];
  openAccounts: OverviewOrder[];
  online: OverviewOrder[];
  staff: {
    name: string;
    tableOrders: number;
    pickupOrders: number;
    ownedCents: number;
    items: number;
    distinctTables: number;
  }[];
  /** 24 entries, order count per hour (Europe/Istanbul). */
  hourly: number[];
  reviews: { reviewId: string; rating?: number; createdAt: string; comment?: string }[];
  employees: { id: number; name: string; role?: string; active?: boolean }[];
}

export interface MonthView {
  month: string;
  summary: {
    localReceiptsCents: number;
    onlineKnownNetCents: number;
    onlineUnpricedGrossCents: number;
    materialsCents: number;
    payrollCents: number;
    fixedCents: number;
    otherCents: number;
    totalExpensesCents: number;
    estimateCents: number;
  };
  platforms: {
    source: string;
    grossCents: number;
    deductionCents: number;
    netCents: number;
    automaticOrders: number;
  }[];
  materials: {
    id: number;
    date: string;
    title: string;
    market?: string;
    totalCents: number;
    paymentMethod?: string;
    voided?: boolean;
  }[];
  weeklyPayroll: {
    id: number;
    employeeId: number;
    employeeName: string;
    weekStart: string;
    weekEnd: string;
    payType: string;
    rateCents: number;
    workedMinutes: number;
    bonusCents: number;
    advanceCents: number;
    grossCents: number;
    payableCents: number;
    paid: boolean;
  }[];
  monthlyFixed: { id: number; category: string; name: string; dueDay?: number; amountCents: number }[];
  fixedPayments: { templateId: number; month: string; paidAt: string; amountCents: number }[];
  other: { id: number; date: string; category: string; name: string; amountCents: number; voided?: boolean }[];
}

export interface Session {
  name: string;
  employeeId: number | null;
  isOwner: boolean;
  grants: string[];
}

/** One synchronized view, always with the time it describes. */
export interface Snapshot {
  asOf: string;
  revision: number;
  /** Is the Windows POS (the authority) online right now? */
  posOnline: boolean;
  pendingCommands: number;
  session: Session;
  staff: StaffState;
  overview?: OwnerOverview;
  month?: MonthView;
  /** Windows-computed sales history (Phase 6 projection `sales_daily`). */
  sales?: SalesView;
  /** Read-only menu publication status (Windows QR publisher). */
  menuStatus?: { qrVersion?: string; qrPublishedAt?: string; qrState: 'published' | 'pending' | 'failed' | 'unknown' };
  /** Integration status as reported by the Windows POS. */
  integrations?: { name: string; state: 'Aktif' | 'Salt Okunur' | 'Onay Bekliyor' | 'Yapılandırılmadı'; detail?: string }[];
  /** Own shift records (Personel) or everyone's (Yönetici, staff.view). */
  shifts?: { employeeId: number; employeeName: string; start: string; end?: string; corrected?: boolean }[];
  /** Audit trail (Yönetici, audit.view). */
  audit?: { at: string; actor: string; action: string; detail?: string }[];
  /** Users & grants (Yönetici, users.manage). */
  users?: { id: number; name: string; role: string; active: boolean; grants: string[]; devices: number }[];
}

export interface DailySales {
  day: string;
  grossCents: number;
  cashCents: number;
  cardCents: number;
  platformCents: number;
  refundCents: number;
  orderCount: number;
  masaCount: number;
  gelalCount: number;
  onlineCount: number;
}

export interface SalesView {
  daily: DailySales[];
  topProducts: { name: string; category: string; qty: number; grossCents: number }[];
  /** [weekday 0=Pzt..6=Paz][hour 0..23] order counts over the period. */
  heatmap: number[][];
  platforms: { source: string; orders: number; grossCents: number }[];
}
