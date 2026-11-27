# Nohut POS — Persisted Data Inventory (Phase 0, PR-01)

Spec: NOHUT POS 2.0 Master Specification V5.1, §4.1, §18.2 and §19.9.
This file was produced by reading the source. It describes what the code stores today. Nothing has been migrated, uploaded or deleted.

| Item | Value |
|---|---|
| Baseline `main` at start of Phase 0 | `cbbb130defdc7df73c9cb61331b4ab42571ba887` (PR #27 merged) |
| Branch | `claude/inspiring-mccarthy-t5ywuv` (after PR #30) |
| Machine-readable contract | `flutter_desktop/lib/sync_registry.dart` |
| CI guard | `flutter_desktop/test/sync_registry_drift_test.dart` |
| Method | `grep`/regex over `flutter_desktop/lib/*.dart` for every receiver that holds the whole state (`s`, `state`, `data`, `next`, `db`, `migrated`, `current`, `updated`, `finished`, `widget.state`, `.data`), plus a line-by-line reading of `pos_store.dart`, `pos_logic.dart`, `operations.dart`, `staff_commands.dart`, `mobile_pairing.dart`, `windows_vault.dart`, `partner_credentials.dart`, `receipt_printer.dart`, `lan_server.dart`, `customer_accounts.dart`, `trendyol_go_readonly.dart`, `finance_logic.dart` and `platform_workflows.dart`. |

Status legend:
- `VERIFIED_EXISTING`: present on `main`.
- `IN_FLIGHT_PR`: only on an open PR.
- `PROPOSED_V5`: does not exist yet.

Classes: `PUBLIC`, `INTERNAL`, `PERSONAL_PII`, `FINANCIAL`, `SECRET`, `DEVICE_LOCAL`, `DERIVED`, `TRANSIENT_API`, `NOT_COLLECTED`.

---

## 1. SQLite database `nohut-pos.sqlite3`

The database lives at `%APPDATA%\NohutFalafel\nohut-pos.sqlite3` and can be overridden with `NOHUT_POS_DATABASE`. Pragmas: `journal_mode=WAL`, `busy_timeout=15000`, `synchronous=FULL`.

| Table | Key | Content | Class | Sync policy (proposed) | Status |
|---|---|---|---|---|---|
| `state_snapshot` | `id=1` (single row) | `revision` INTEGER (fences every write), `payload` TEXT, `updated_at`. **Since Phase 1B the payload holds only the small core** (settings, menu, finance, …); the growing collections live in the `pos_*` tables below. | all classes of §2 | Never uploaded as a blob. It is projected per entity through the registry (spec §2.2). | VERIFIED_EXISTING |
| `command_receipts` | `request_id` | Idempotency receipt: the full request `payload` JSON and the `result` JSON. Written by `PosStore.command` (staff phone orders/actions, finance sync). | INTERNAL, **PERSONAL_PII** (a Gel-Al phone order payload contains `customer.phone`) | Keep request identity, hash and outcome. Cloud copy redacted (spec §19.6.5). | VERIFIED_EXISTING |
| `deleted_requests` | `request_id` | Opaque IDs of commands that belonged to an order removed by `deleteOrder`. | INTERNAL | Anti-replay identity; must survive restore. | VERIFIED_EXISTING |
| `pos_meta` | `key` | `storage_version` (2), `migrated_at`, `present:<stateKey>` markers | INTERNAL | Local | VERIFIED_EXISTING (Phase 1B) |
| `pos_orders` | `row_key` = order id | One row per order: `seq`, `json` (the full order aggregate), `source`, `created_at`, `closed` | FINANCIAL, PERSONAL_PII | `orders` + children | VERIFIED_EXISTING (Phase 1B) |
| `pos_print_jobs` | `orderId:batchId:kind` | One row per print job: `seq`, `json`, `order_id`, `state` | INTERNAL, PERSONAL_PII (name + time only) | `receipt_snapshots`, `print_jobs` | VERIFIED_EXISTING (Phase 1B) |
| `pos_platform_orders` | supplier:store:packageId | One row per Trendyol Go package: `seq`, `json`, `status`, `created_at` | FINANCIAL, TRANSIENT_API | `platform_order_records` | VERIFIED_EXISTING (Phase 1B) |
| `pos_deleted_orders` | order id | One row per soft-deleted order: `seq`, `json`, `deleted_at` | FINANCIAL, PERSONAL_PII | tombstones | VERIFIED_EXISTING (Phase 1B) |
| `backup_history` | `backup_id` | Backup runs: time, revision, sizes, SHA-256, destination, status, verification, reason, error | INTERNAL, DEVICE_LOCAL | Local history; never pruned | VERIFIED_EXISTING (Phase 1) |
| `auth_users`, `auth_devices`, `auth_sessions`, `auth_settings`, `auth_audit`, `auth_notification_reads` | user_id / device_id / sha256(token) / key / id | Local individual accounts (`lib/local_accounts.dart`): username, role, linked employee id, per-user grants, PBKDF2 password/PIN verifiers, owner TOTP secret, trusted devices, session verifiers (token never stored), idle-lock and "Bireysel giriş zorunlu" settings, security audit. **Never in the state JSON, never projected to the cloud**; travels only inside the encrypted backup. | SECRET (verifiers, TOTP secret), DEVICE_LOCAL | Control plane (A2) maps users ↔ `nohut_private.app_users`; local verifiers are never uploaded | PROPOSED_V5 (A3/A4) |
| `sync_outbox`, `sync_state` | — | — | — | Spec §4.4 | PROPOSED_V5 |

**History-loss finding (resolved in Phase 1B):** `PosStore.deleteOrder` physically removes the order, its print jobs, staff notices and terminal attempts. It also deletes the matching `command_receipts`; only the request IDs remain in `deleted_requests`. **Phase 1B change:** deletion is now an audited soft delete.
- The order, its print jobs, staff notices and terminal attempts move unchanged into `deletedOrders`, together with `deletedAt`, `deletedBy`, `deletedByStaffId`, `reason` and `requestId`.
- Command receipts are **kept**. Their IDs are also listed in `deleted_requests`, so a replay is refused.

---

## 2. `state_snapshot.payload` top-level keys (29)

Every key below is registered in `lib/sync_registry.dart`. CI fails if a new key appears in the source without an entry.

| Key | Written by (function / file) | Content and stable ID | Class | Proposed cloud target | Sync / retention policy | Status |
|---|---|---|---|---|---|---|
| `employees` | `emptyPosState`, finance/personnel UI | `{id:int, name, role, active}`. ID is stable and never reused. | PERSONAL_PII, INTERNAL | `employees` | POS→Cloud. Deactivate, never delete. Keep attribution. | VERIFIED_EXISTING |
| `orders` | `newLocalOrder`, `addOrderBatch`, payments, cancellations, platform demo | Local Masa/Gel-Al orders and demo platform orders (detail in §3). ID `int` from `nextId`. | FINANCIAL, PERSONAL_PII, INTERNAL | `orders`, `order_batches`, `order_items`, `payments`, `order_events` | Full history. Phone protected and never printed. | VERIFIED_EXISTING |
| `deletedOrders` | `PosStore.deleteOrder` (Phase 1B) | Soft-deleted orders, each `{orderId, deletedAt, deletedBy, deletedByStaffId, reason, requestId, revision, order, related{printJobs, staffNotices, terminalAttempts}}` | FINANCIAL, PERSONAL_PII, INTERNAL | `orders` (deleted_at tombstone) + `audit_logs` | Never erased. Excluded from reports exactly as before. The archived order follows the `orders[]` field rules. | VERIFIED_EXISTING (Phase 1B) |
| `nextId` | `newLocalOrder` | Monotonic order ID sequence (starts at 1200). | INTERNAL | — | Single-writer authority, not replicated. | VERIFIED_EXISTING |
| `printJobs` | `queueLocalKitchen`, `queuePaymentReceipt` | `{orderId, batchId, kind?, state, createdAt, attempts, error, spooledAt, snapshot{order{id,dailyNumber,numberDay,source,table,createdAt,pickupChannel,customer{name,time}}, batch}, text?}`. Key: (`orderId`, `batchId`). | INTERNAL, PERSONAL_PII (name/time only; phone excluded since this PR) | `receipt_snapshots`, `print_jobs` | Audit only. Never replayed on another machine or after restore. | VERIFIED_EXISTING |
| `settings` | many | Business and device settings (§4). | INTERNAL, DEVICE_LOCAL | `restaurant_settings` (business keys only) | Printer/paper/device keys stay local. | VERIFIED_EXISTING |
| `shifts` | `shifts.dart` (Phase 5C) | `{id, employeeId, employeeName, start, end?, source, corrections[{at, byId, by, before, after, reason}]}` | PERSONAL_PII (employee name, hours), INTERNAL | `shifts` | Mesai Başlat/Bitir. Never deleted; corrections are appended, visible to the employee. | VERIFIED_EXISTING (Phase 5C) |
| `staffNotices` | `recordStaffNotice` | Rolling last 100 `{id, orderId, staff, action, table, at}`. | INTERNAL | `audit_logs` | Operational audit. | VERIFIED_EXISTING |
| `floorPositions` | floor plan editor | Table rectangles by table number. | INTERNAL | `pos_tables` | Owner command. | VERIFIED_EXISTING |
| `combinedPayments` | `group_payments.dart` | `{id(ref), accountKey, orderIds, amount, cash, card, received, method, createdAt}`. | FINANCIAL | `payments` (group link) | Append-only. | VERIFIED_EXISTING |
| `terminalAttempts` | `card_terminal.dart` | `{reference, orderId, amountCents, terminalReference, transactionId, …}`. No PAN. | FINANCIAL | `payments` (terminal attempts) | Append-only. No card data, ever. | VERIFIED_EXISTING |
| `cashBook` | `operations.dart` (`cashBook()`) | Legacy `sessions` / `movements` (Kasa Aç/Kapat UI was removed at the owner's request; data kept). | FINANCIAL | `cash_sessions`, `cash_movements` | Preserve history. | VERIFIED_EXISTING |
| `localMenu` | `assets/menu.json` seed, QR sync | Products `{id, name, category, price, active, …}`. | PUBLIC, INTERNAL | `products`, `product_versions` | Versioned (spec §19.3). Old orders keep their frozen name and price. | VERIFIED_EXISTING |
| `internalMenu` | `pos_logic.dart` (custom items) | Cashier custom products. | INTERNAL | `products` (internal) | Never published to QR. | VERIFIED_EXISTING |
| `qrCategories`, `qrCampaigns` | `qr_menu_sync.dart` | Mirror of the public QR catalog. | PUBLIC | `categories`, `campaigns`, `campaign_versions` | Versioned. | VERIFIED_EXISTING |
| `qrMenuSync` | `qr_menu_sync.dart` | Sync bookkeeping `{version, unlistedLocalProducts, …}`. | DERIVED | — | Local. | VERIFIED_EXISTING |
| `qrPublisherDraft`, `qrPublisherDraftRevision`, `qrPublisherDraftSourceSnapshot` | `qr_menu_management.dart` | Unpublished menu draft, its base revision and the published copy it started from. | PUBLIC, INTERNAL | — | Local until published. | VERIFIED_EXISTING |
| `customers` | `savePickupCustomer` (`customer_accounts.dart`, PR #17 content on main) | Saved Gel-Al customers `{id, name, phone, createdAt, updatedAt}`, used by Açık Hesaplar (open accounts). | PERSONAL_PII | **BLOCKED**: owner and KVKK decision (spec §19.5) | Existing feature: preserve, do not expand. Platform customers are never added. | VERIFIED_EXISTING |
| `finance` | `finance_logic.dart` | `materials`, `weeklyPayroll` (incl. `workedMinutes`, `advanceCents`, `bonusCents`), `monthlyFixed` (`activeRanges`, `amountHistory`), `fixedPayments`, `other`, `manualPlatformSales`. | FINANCIAL, PERSONAL_PII (payroll) | `material_purchases`, `expenses`, `fixed_expenses`, `payroll_*`, `platform_sales` | Full history. Payroll restricted to owner and self through RLS. | VERIFIED_EXISTING |
| `marketPrices` | `market_prices.dart` | `tracked`, `priceAlerts`, `storeMatches`, location and refresh settings and status. | INTERNAL | `market_price_history` | — | VERIFIED_EXISTING |
| `integrations` | `platformHub()` | Platform hub v4: demo stores, `menu` per platform, `settlements`, `sequence`. | INTERNAL, FINANCIAL | `platform_order_records`, `platform_menu` | Settlements are financial facts. | VERIFIED_EXISTING |
| `trendyolGoOrders` | `normalizeTgoPackage` + sync (`trendyol_go_readonly.dart`) | Normalized packages (detail in §3.4). Key: `packageId` (+ `orderNumber`). | FINANCIAL, INTERNAL, **TRANSIENT_API** | `orders` (channel=trendyol), `platform_order_records` | Business facts durable. Customer contact fields are transient (see `platform-data-policy.md`). | VERIFIED_EXISTING |
| `tgoSyncInfo` | Trendyol sync | Polling cursor/status. | INTERNAL | — | Local. | VERIFIED_EXISTING |
| `tgoOperationAudit` | `trendyol_go_readonly.dart` | `{platform, packageId, orderNumber, action, result, at}`. | INTERNAL | `audit_logs` | Operational audit. | VERIFIED_EXISTING |
| `tgoReviewStoreId` | `trendyol_go_ui.dart` | Store ID for reviews (not a secret). | INTERNAL | `restaurant_settings` | — | VERIFIED_EXISTING |
| `tgoReviewCache` | `trendyol_go_ui.dart` | Cached reviews, including reviewer names. | TRANSIENT_API, PERSONAL_PII | — | Refreshable cache. No CRM. | VERIFIED_EXISTING |
| `platformReviews` | `review_sync_service.dart`, `review_repository.dart` (table `pos_platform_reviews`) | Persistent review repository: platform, supplier, store, reviewId, rating, comment, product names, reply + moderation, firstSeen/lastVerified, read, notification state. No reviewer identity, no raw payloads. | INTERNAL | — (reviews read contract pending) | Kept; never deleted by sync. | PROPOSED_V5 |
| `tgoReviewSync` | `review_sync_service.dart` | Review sync status, diagnostics and window checkpoints. | INTERNAL | — | Local cursor. | PROPOSED_V5 |
| `tgoStoreIdentity` | `review_sync_service.dart`, `tgo_store_identity.dart` | Verified Trendyol store {supplierId, storeId, name, source, verifiedAt}; replaces the hard-coded fallback. | INTERNAL | `restaurant_settings` | — | PROPOSED_V5 |
| `notifications` | `notification_center.dart` | Durable Windows notification history (eventId dedup, read state). No payroll or customer contact data. | INTERNAL | — (contract N1 pending) | Capped at 500; unread kept. | PROPOSED_V5 |
| `mobileDevices` | `mobile_pairing.dart` | `{id, name, hash(token), createdAt, revoked}`. | SECRET (token verifier), DEVICE_LOCAL | — (control plane) | Never in the business projection. | VERIFIED_EXISTING |
| `mobileServerId` | `mobile_pairing.dart` | This POS's LAN identity. | DEVICE_LOCAL | — | — | VERIFIED_EXISTING |

---

## 3. Nested entities inside `orders`

### 3.1 Order header
Fields:
- Identity and placement: `id`, `dailyNumber`, `numberDay`, `source` (`Masa`/`Gel-Al`/`Yemeksepeti`/`Trendyol Go`), `table`, `pickupChannel`.
- Times: `created`, `createdAt`.
- Status: `closed`, `closedAt`, `cancelled`, `cancelledAt`, `cancelReason`, `tableReleased`, `serviceStatus`, `serviceStartedAt`, `readyAt`, `deliveredAt`.
- `customer` (§3.5) and `customerLinkHistory`.
- `events` (free-text audit strings).
- Correction records: `lineEdits`, `voids`.
- Platform demo fields: `platformAdjustments`, `platformCollection`, `platformCancelledAmount`, `platformSnapshot`, `platformPackageId`, `platformRevision`, `demoRemoteStatus`.
- `terminalPending`.

**Identity gap:** `id` is stable. `dailyNumber` is a display number that is reused every day, so it must never be used as an ID (spec §19.2).

### 3.2 Batches and lines
- **Batch:** `{id (per order, 1..n), staff (name), staffId, time, createdAt, lines}`.
- **Line:** `{productId, productKey, name, price (TL, decimal), qty, removed[], note, components[] (campaign), campaignId, basePrice, adjustmentCents, customItem, voided, originalQty, correction}`.
- **Line identity:** today a line is addressed as `"<batchId>:<index>"` (`checkLines`). That is an index, not a stable ID. PR-04 must assign stable line IDs once at migration (spec §4.4).
- The price is frozen on the line, so historical totals do not depend on today's menu. This is already correct.
- **Duplication finding:** depending on the entry path, a line can carry a **copy of the whole catalog product**: `category`, `active`, `description{tr,en,ar}`, `startsAt`, `endsAt` and catalog `id`. Campaign components carry multilingual `description` too. The same copy is repeated in every print snapshot. These fields are not needed to reproduce the sale, so they are excluded from the cloud allowlist. Phase 1B stores a product-version reference instead (spec §19.6.1).
- **Full nested field list:** `flutter_desktop/lib/sync_field_paths.g.dart` (628 declared paths). It comes from runtime observation of every write in the test suite plus code reading, and every write in CI is validated against it.

### 3.3 Payments, refunds and guest checks
- **Payment:** `{createdAt, method (Nakit/Kart/Platform), amount (TL decimal), received, change, time, by, guestCheckId?, guestAllocations[], refunds[{amount, reason, createdAt}], reversed, combinedPaymentId?}`. No payment ID exists today; payments are addressed by list index. PR-04 must assign stable IDs.
- **Money storage:** stored as decimal TL `num` and converted with `cents()` everywhere. The cloud should use integer kuruş (spec §11.2).
- **`guestChecks`:** `{id, name, allocations[{key, cents}]}`.

### 3.4 `trendyolGoOrders` row (normalized, no raw payload stored)
- **Identity:** `packageId`, `orderId`, `orderNumber`, `orderCode`, `supplierId`, `storeId`, `packageItemIds[]`.
- **Status and timing:** `status`, `createdAt`, `modifiedAt`, `preparationMinutes`, `pickupEtaState`, `deliveryType`, `deliveryEta`, `pickup`, `testPackage`.
- **Money:** `totalCents`, `paymentType`.
- **Lines:** `lines[{name, qty, unitPriceCents, options[], removed[], extras[]}]`.
- **Other:** `customerNote`, `cancelReason`, `kitchenPrintState`, `kitchenQueuedAt`, `dailyNumber`, `numberDay`.
- **PII stored durably today:** `customerName`, `customerEmail`, `customerPhone`, `deliveryAddress`, `appName`. These are classified `TRANSIENT_API` by V5 §19.4 and are **not** removed in Phase 0. The proposal is in `platform-data-policy.md`.
- **Protection today:** the LAN staff projection (`lan_server.dart` `_staffState`) already strips them.

### 3.5 Gel-Al `customer`
- **Fields:** `{name, phone, time, id? (saved customer)}`.
- **Where they reach:**

  | Destination | Fields | Notes |
  |---|---|---|
  | Print snapshot (`printJobs[].snapshot.order.customer`) | `name`, `time` only | Fixed in this PR. Before, the first ticket froze an empty customer (spec §11.1). |
  | Staff phones (LAN projection) | `name`, `phone`, `time` | Operational. To be reviewed under KVKK. |
  | `command_receipts.payload` | full staff payload, including `phone` | |

---

## 4. `settings` keys

| Group | Keys | Class | Sync |
|---|---|---|---|
| Printer / paper (device) | `printerName`, `printerModel`, `printerMode`, `printerCount`, `receiptTransport`, `paperWidthMm`, `printableWidthMm`, `receiptMarginMm`, `receiptOffsetMm`, `receiptLogoMm`, `receiptSidePaddingMm`, `receiptScale`, `receiptLayoutVersion` | DEVICE_LOCAL | never |
| Printing policy | `autoPrint`, `autoPrintEnabledAt`, `receiptPolicy` (legacy), `receiptPolicyVersion` | INTERNAL | business setting |
| Platform | `platformDeductionRates`, `tgoKitchenTiming` (legacy), `storeId`, `supplierId`, `acceptFlow`, `open`, `connection`, `cursor`, `lastSync` | INTERNAL | business setting (credentials are NOT here; see §5) |
| Alerts / QR | `onlineOrderSound`, `soundAlerts`, `qrAutoSync`, `migrated` | INTERNAL | business setting |

---

## 5. Sidecar files (outside SQLite)

| File | Written by | Content | Class | Policy |
|---|---|---|---|---|
| `<db>.finance-sync.dpapi` | `finance_sync_server.dart` → `WindowsVault` | Android finance AES key | SECRET | DPAPI only. Re-pair on a new PC. Never synced or backed up in plaintext. |
| `<db dir>/google-business.dpapi` | `google_business.dart` | Google OAuth tokens | SECRET | Same as above. |
| `%APPDATA%\NohutFalafel\trendyol-go-credentials.dpapi` | `trendyol_go_readonly.dart` | Trendyol API key/secret | SECRET | Same as above. |
| `%APPDATA%\NohutFalafel\yemeksepeti-credentials.dpapi`, `migros-yemek-credentials.dpapi` | `partner_credentials.dart` | Partner credentials | SECRET | Same as above. |
| `%APPDATA%\NohutFalafel\qr-publisher-credentials.dpapi` (+ `QrPublisher\`) | `qr_publisher_client.dart` / settings | GitHub publisher credentials | SECRET | Same as above. |
| `%APPDATA%\NohutFalafel\alarm-tones\*.wav`, `staff-order.mp3` | `order_alerts.dart` | Generated sounds | DERIVED | Regenerated; not backed up. |
| `nohut-backup-<ms>.sqlite3` / `nohut-<ms>.sqlite3` | `operations_ui.dart`, `simple_settings.dart` (`VACUUM INTO`) | **Unencrypted** full DB copy chosen by the user | all classes | Phase 1 replaces these with encrypted backups (AES-256-GCM). |
| CSV exports (`Documents\…`) | `sales_reports.dart`, `operations_ui.dart` | Report rows | FINANCIAL | User files; not managed. |
| Finance PDFs | `finance_ui.dart` | Reports | FINANCIAL, PERSONAL_PII (payroll) | Generated on demand. |
| `Nohut_Market_Takip.nohut.json` | `market_price_tracking.dart` | Market-watch export/import | INTERNAL | User file. |
| Temp `nohut-receipt-*/receipt.png, receipt.bin, job.json` | `receipt_printer.dart` | Print raster, deleted after spooling | DERIVED | Never kept. |

---

## 6. QR menu repository files (`nohutfalafel/qr-menu`)

The POS reads these files (`qr_menu_reader.dart`):
- `cms/catalog-v1.json`
- `cms/menu-prices.json`
- `cms/campaigns.json`
- `cms/pos-managed-status.json`
- `cms/pos-managed-menu.json`

The publisher writes the POS-managed files through `qr_publisher_client.dart`. All of them are PUBLIC.

**BLOCKED:** adding the `nohutfalafel/qr-menu` repository to this session was refused by the session's permission policy. Its client scripts (`cms-live.js`, `cms-pos-live.js`, `menu.js`, `campaigns-data.js`) were therefore not line-audited (spec §1.3). The owner must allow access to that repository, or another session must audit it.

---

## 7. Mobile apps (inventory relevant to sync)

- **Nohut Personel:** `flutter_personel/lib/main.dart`, built as an APK by `flutter-personel-android.yml`.
- **Nohut Yönetici:** `flutter_personel/lib/manager_main.dart`, a separate APK built with `--target lib/manager_main.dart` by `flutter-yonetim-android.yml`. Both share `packages/nohut_core` (`finance_wire.dart`, `management_sections.dart`, `report_period.dart`).
- **Persisted on Android:** secure storage holds the pairing token and the finance key, plus the quick-expense outbox (`expense_drafts.dart`, restaurant-scoped, persisted before send, reuses the request ID).

The phone channel (`assets/staff.html`, served by `PosLanServer` on :8787) keeps only the staff ID and drafts in browser storage.

---

## 8. Open PR / conflict register (at `cbbb130`)

| PR | Branch | Ahead / behind `main` | Assessment |
|---|---|---|---|
| #30 | `claude/inspiring-mccarthy-t5ywuv` | this work | receipt margins, print policy |
| #19 | `codex/nohut-receipt-realistic-preview-20261122` | 14 / 141 | Touches `receipt_preview.dart`, `receipt_printer.dart`, `print-raster.ps1`, `simple_settings.dart` and `main.dart`. **Conflicts** with the merged receipt redesign (#27/#30); needs a manual re-base or closing (owner decision). |
| #17 | `codex/nohut-pos-customer-ledger-20261120` | 0 / 242 | Fully contained in `main`. Can be closed. |
| #16 | `codex/nohut-pos-premium-ui` | 0 / 350 | Fully contained in `main`. Can be closed. |
| #15 | `codex/nohut-pos-online-reports-google` | 0 / 470 | Fully contained in `main`. Can be closed. |
| #14 | `feature/trendyol-go-readonly-20261118` | 30 / 489 | Its Trendyol code was superseded on `main`. The unique remaining piece is the Windows installer (`windows/installer/*.iss`, `build-setup.ps1`), worth salvaging separately. |
| #2 | `codex/staff-sessions-platform-integrations` | 14 / 704 | 73 files, very old, includes `integration_gateway/` (Python) and `nohut-menu/`. Superseded. Close or archive (owner decision). |

No PR was closed or merged as part of Phase 0.
