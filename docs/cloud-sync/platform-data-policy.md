# Platform & Customer Data Policy (Phase 0, PR-01)

Spec: V5.1 §4.3(6), §19.4, §19.5. This document describes the current behaviour (verified from source) and the proposed V5 treatment.

Nothing in Phase 0 deletes, uploads or rewrites any stored field. Every change listed under "proposed" needs owner approval, and KVKK review where personal data is involved.

## 1. Principles (binding, from the owner)

- **No CRM:** no customer database, profile, directory or cross-platform identity matching for Trendyol Go or any delivery-platform customer.
- **Platform contact details are API-first and transient:** customer details come from the authorized platform API, are used only for the active order, and are not replicated to clients that do not need them.
- **Business facts are durable:** order and package IDs, items, options, quantities, prices, totals, status transitions, action outcomes and cancellation reasons are kept for the full history.
- **No raw API responses or debug payloads are stored permanently.** Ingestion parses into allowlisted typed fields.
- **The local Gel-Al pickup name and time** are kept per order. The phone is kept only when it is needed for contact, and it **never** appears on a print snapshot or a receipt.
- **The existing saved Gel-Al customers and Açık Hesaplar (open accounts)** are preserved as they are. They are not expanded and are not deleted automatically.

## 2. Trendyol Go: what ingestion stores today

PR #39 implementation update (not production activated): the additive `lineFacts` commercial collection retains fully cancelled lines, source item IDs and original quantities where provided; `lines` keeps its existing active-only behavior. `totalKnown`, `quantityKnown` and `unitPriceKnown` distinguish source knowledge from legacy normalized values. Cloud commercial versions retain all available source facts and corrections, redact known contact values from preparation notes and exclude structured customer contact/raw payloads. No bank settlement is inferred from an order total or configured fee estimate. Review implementation and its privacy contract remain Claude-owned.

Ingestion is `normalizeTgoPackage` in `flutter_desktop/lib/trendyol_go_readonly.dart`. It does not store raw payloads; it parses into typed fields.

| Field (stored key) | API source | Class | Today | Proposed V5 treatment |
|---|---|---|---|---|
| `packageId`, `orderId`, `orderNumber`, `orderCode`, `supplierId`, `storeId`, `packageItemIds` | package identity | INTERNAL (linkable) | durable | **Durable.** Scope by platform/restaurant. |
| `status`, `createdAt`, `modifiedAt`, `preparationMinutes`, `pickupEtaState`, `deliveryType`, `deliveryEta`, `pickup`, `testPackage`, `cancelReason` | operational | INTERNAL | durable | **Durable.** Status transitions become events. |
| `lines[{name, qty, unitPriceCents, options, removed, extras}]`, `totalCents`, `paymentType` | items / money | FINANCIAL | durable | **Durable**, as typed records. Distinguish a missing value from 0. |
| `customerNote` | customer note | INTERNAL (may contain PII) | durable | **Durable**, because it describes preparation. Not truncated. Contact details typed into the note are not parsed out automatically. |
| `customerName` | `customer.firstName/lastName` | PERSONAL_PII | **durable in `trendyolGoOrders`** | `TRANSIENT_API`: used for the active order screen and the Sipariş Fişi (the owner asked for the name on the ticket). Clear it after an owner-approved TTL once the order is final. Never sent to the cloud projection. |
| `customerPhone` | `address.phone` | PERSONAL_PII | **durable** | `TRANSIENT_API`: not needed for pickup-by-courier fulfillment. Proposal: stop storing it, or clear it at order final state. Never printed (already true). |
| `customerEmail` | `customer.email` | PERSONAL_PII | **No longer collected** (owner decision, PR-01). Older stored values remain until the approved clean-up. | `NOT_COLLECTED`. |
| `deliveryAddress` | `address.*` | PERSONAL_PII | **durable** | `TRANSIENT_API`: courier deliveries mask it anyway. Proposal: clear it at final state. |
| `appName` | `userInformation.appName` | INTERNAL | durable | Durable (channel analytics). |
| `kitchenPrintState`, `kitchenQueuedAt`, `dailyNumber`, `numberDay` | local | INTERNAL | durable | Durable. |

Where these fields reach today:

| Destination | Platform customer fields | Notes |
|---|---|---|
| LAN staff projection (`lan_server.dart _staffState`) | stripped | Already allowlisted. |
| Sipariş Fişi (`tgoKitchenTicket`) | name only | No phone, email or address. |
| `tgoOperationAudit` | none | Stores only package ID, order number, action, result and time. |
| Windows UI order card (`trendyol_go_ui.dart`) | name, phone, email, address | Operator view for the active order. |

### 2.1 Trendyol reviews cache (`tgoReviewCache`)
- Holds review rows as returned by the reviews call, including reviewer display names, plus `pendingReplies`.
- **Class:** `TRANSIENT_API`.
- **Proposed treatment:** keep it as a bounded, refreshable local cache. It is never projected to the cloud and never linked to orders as a customer profile.
- **To verify in PR-04:** whether the stored review rows are the full API objects. If they are, reduce them to allowlisted fields.

### 2.2 Credentials
Trendyol, Yemeksepeti, Migros, Google and QR publisher credentials are kept only in Windows DPAPI sidecar files. They never enter `state_snapshot`, logs, command receipts or backups in plaintext (verified in `data-inventory.md` §5).

## 3. Yemeksepeti / Migros Yemek

The only Yemeksepeti and Migros Yemek data on `main` is DEMO: `platform_workflows.dart` creates `customerName: 'DEMO MÜŞTERİ'`. The same policy applies before any real integration is enabled.

## 4. Local Gel-Al

| Data | Where | Proposed |
|---|---|---|
| `orders[].customer.{name, time}` | order | Durable, order-specific. Printed on the Sipariş Fişi and the Hesap Özeti. |
| `orders[].customer.phone` | order | Keep only when entered for contact. Separately protected in the cloud projection (RLS owner/manager), never printed. |
| `printJobs[].snapshot.order.customer` | print snapshot | `{name, time}` only. **Phone excluded; enforced by the code and tests in this PR.** |
| `command_receipts.payload` (phone orders) | SQLite | Contains the staff payload including the phone. Proposed: redact the phone in the cloud copy, keep the local receipt for idempotency. |
| `customers[]` (saved directory, PR #17 content) | state | **Existing feature, preserved.** Used by Açık Hesaplar balances. Cloud projection **BLOCKED** until the owner and KVKK decide. No auto-matching of platform customers into it (verified: only the cashier path `linkedPickupCustomer` writes it). |
| `orders[].customerLinkHistory` | order | Audit of manual links. Durable with the order. |

## 5. Regression gate implemented in this PR (spec §11.1)

`newLocalOrder` now receives the pickup customer and `staffId` **before** it freezes the first print snapshot. Both entry paths pass them:
- the Windows composer (`main.dart`);
- the LAN/phone path (`staff_commands.dart submitStaffOrder`), which is also used by the Android Personel app.

Tests in `flutter_desktop/test/receipt_text_test.dart`:
- **First ticket, cashier path:** name and time are present; no phone in the text or the snapshot.
- **First ticket, LAN path:** same checks.
- **Added order:** the ticket is marked `EK SİPARİŞ`, with name and time and no phone.

The iPhone PWA does not exist yet. When it is built in Phase 4–5, it must use the same command, so the same test applies.

## 6. Open decisions for the owner

1. TTL for `customerName`, `customerPhone` and `deliveryAddress` on Trendyol orders after the final state (proposal: clear once the order is Delivered or Cancelled + N days). Requires legal review.
2. ~~Stop collecting `customerEmail`~~ **Decided and implemented in PR-01.**
3. Cloud projection of `customers[]` and Gel-Al phone (proposal: owner/manager-only RLS, or keep local-only).
4. What to do with the existing stored platform PII in current databases (proposal: a one-time local clean-up after the decision, never a silent deletion).

## 7. Proposed minimal retention policy (for owner approval and KVKK review; NOT implemented)

| Data | Kept while | Then | Never |
|---|---|---|---|
| Trendyol `customerName` | The order is active (`Created` / `Picking` / `Invoiced` / `Shipped`), and for **7 days** after the final state, to handle claims, missing items and courier issues. | Cleared locally (field removed, `contactClearedAt` recorded). The order, its items, money, status history and receipt remain. | Projected to the cloud, copied to another record, or linked across orders. |
| Trendyol `customerPhone`, `deliveryAddress` | The order is active only (needed only if the restaurant must contact the customer or courier). | Cleared at the final state + **24 h**. | Printed, projected, or logged. |
| Trendyol `customerEmail` | — | Not collected. | — |
| Trendyol review reviewer names (`tgoReviewCache`) | Cache lifetime (refreshed from the API). | Replaced on refresh. Bounded to the last N pages. | Projected or linked to orders. |
| Gel-Al `customer.phone` on an order | Until the order is closed and fully paid. If it is linked to a saved customer, the saved customer keeps it under the existing feature. | Proposal: clear on the order N days after close. Owner decides N. | Printed or projected. |
| Saved Gel-Al customers (`customers`) | Unchanged existing feature. | Only on an owner-approved data-subject request, or an owner decision. | Expanded or auto-deleted. |
| Command receipts with a Gel-Al phone | Needed for idempotency (request identity + outcome). | Proposal: redact the phone inside the stored payload after the order closes; keep the request ID, hash and outcome. | Projected. |

The day counts are proposals only. Legal review must confirm them against accounting, consumer-dispute and platform-contract obligations. The clean-up job will be idempotent, audited, covered by the backup, and will never touch financial facts.

