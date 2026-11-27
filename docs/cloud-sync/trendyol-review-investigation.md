# Trendyol Go reviews — Milestone 1: read-only root-cause investigation

**Owner:** Claude · **Date:** 2026-11-27 · **Spec:** §23.6 · **Status:** code + official documentation reviewed; **no live API call made** (none authorized yet).

Owner symptom: the newest review shown is ~200 days old, recent reviews are missing, no automatic notification, the screen must be opened manually.

This document separates **verified facts** (from the repository at `main` `dd64f88` and the official documentation read on 2026-11-27) from **hypotheses** that need one authorized, read-only live check. No credentials, supplier IDs or customer data are recorded here.

## 1. Official documentation (read 2026-11-27, developers.tgoapps.com)

| Topic | What the documentation says |
|---|---|
| Host / auth | `https://api.tgoapis.com` (prod), `https://stageapi.tgoapis.com` (stage). Same Basic auth (supplierId + API key/secret) as orders; 401 = wrong supplierId/key/secret. |
| **Store discovery** | `GET /integrator/store/meal/suppliers/{supplierId}/stores?page&size` (size max 50) → `restaurants[] {id, name, supplierId, workingStatus, address, deliveryType, …}`, `totalPages`, `totalElements`. **This is the officially supported way to list a supplier's restaurants. The POS does not call it today.** |
| Review list | `GET /integrator/review/meal/suppliers/{supplierId}/stores/{storeId}/reviews/filter` with `page` (default 0), `size`, `deliveryType`, **`startDate` / `endDate` (epoch ms, filter on `createdDate`)**, `orderParentId`, `hasComment`, `hasRestaurantAnswer`, `restaurantAnswerStatus` (`WAITING_FOR_APPROVE`, `APPROVED`, `REJECTED`). |
| Review shape | `reviewId` (UUID string), `restaurantId`, `orderCreatedDate`, `createdDate` (epoch ms), `orderParentId`, `rating {flavorScore, serviceScore, deliveryScore, average}`, `deliveryType`, `products[] {productId, name, modifierProducts[]}`, `comment {text, restaurantAnswer {text, status, rejectedReason {reason, reasonId}}}`. |
| Review rules | Customers can review only **within 7 days** of the order; reviews cannot be edited afterwards. Rejected answers carry `rejectedReason` (ids 1–15 listed). |
| Sorting | **Not documented.** No sort parameter exists. |
| Rate limits | **Not documented** on the review/store pages. |
| Reply | `POST …/stores/{storeId}/reviews/{reviewId}/answer` body `{"text": …}`. Moderation outcome is only visible later via the list endpoint (`restaurantAnswer.status`). |
| Uber Eats migration | Review **stats, filter and answer** endpoints return **403 `endpoint.not-available.error`** for restaurants migrated to Uber Eats, and after removal **404 with plain-text body `404 page not found`** (must not be parsed as JSON). The migration is staged per store; the first phase affects **only stores in Bilecik**, other cities keep the current integration "until the end of the year". Uber orders carry `uberPackageId`, `userInformation.appName = "UberEats"`, a different `customer.id`, and a 5-character `orderCode`. |

## 2. Existing implementation — verified facts

| # | File / line (main `dd64f88`) | Fact | Effect |
|---|---|---|---|
| F1 | `lib/trendyol_go_ui.dart:951-954` (`_TgoReviewsPanelState.initState`) | Store ID = saved `tgoReviewStoreId` if numeric; else the single `storeId` found in **currently loaded orders** for the supplier; else the hard-coded **`316490`**. | With 0 loaded orders (e.g. at start-up, quiet day, history cleaned) or ≥2 store IDs, the panel silently uses `316490`. |
| F2 | same file | `316490` is the public **tgoyemek.com consumer page ID** (`nohut-menu/index.html`, `nohut-menu/assets/*.json`). Nothing in the code or the documentation says the consumer page ID equals the integrator `storeId`. | Unverified identity. It may be right, an older record, or a different identifier space. |
| F3 | `trendyol_go_ui.dart:1123-1129` | `onChanged` calls `_saveStoreId` on **every keystroke** (3–12 digits pass). | A half-typed value is persisted and wins over order-derived IDs on every later start. |
| F4 | `trendyol_go_ui.dart:929-937`, `sync_registry.dart:200` | `tgoReviewStoreId` is stored **without `supplierId`** and without a verification time. Only `tgoReviewCache` checks `supplierId`. | After a credential change the old store ID is reused; there is no "verified" state at all. |
| F5 | `trendyol_go_readonly.dart:631-690` (`readReviews`) | Request = `page` + `size=20` only; **no `startDate`/`endDate`**. | With no documented sort order, page 0 can be the oldest (or arbitrary) 20 reviews. **This alone can explain "newest review ≈ 200 days old" even with the correct store.** |
| F6 | `trendyol_go_ui.dart` (`newestFirst`, rating filter) | Sorting/filtering is applied **only to the loaded page**. | Newer reviews on later pages are never shown first. |
| F7 | `trendyol_go_ui.dart:955-961` | The 5-minute timer lives in the review **widget** and only reloads the **current** page. | No sync when the screen is closed; refresh never looks for new reviews elsewhere. No new-review detection, no notification. |
| F8 | `trendyol_go_ui.dart:910-926` | Cache = last page 0 only (`tgoReviewCache`, transient, never projected). | Reviews "disappear" with paging; no history, no read state, no checkpoint. |
| F9 | `readReviews` / `answerReview` | 404 and 403-`not-available` are both shown as "service unavailable". The 404 body is not JSON-parsed (good), but a **wrong store ID that returns 404 is indistinguishable from migration**. | Wrong-ID and migration failures are conflated. |
| F10 | `answerReview` | Reply success = any 2xx; UI keeps a local `pendingReplies` until a later GET shows `restaurantAnswer`. No duplicate guard across restarts beyond the cache. | Partly correct; needs a persisted reply state machine (§23.6.9). |
| F11 | `finance_sync_server.dart:373-375` | Manager LAN API forwards up to 100 rows of `tgoReviewCache` to the Android manager app. | The same stale page propagates to Yönetici. |
| F12 | `test/online_order_alarm_test.dart:18` | Test fixture uses the real `316490`. | Should become a synthetic ID when the review rework lands (no real restaurant data in tests). |

## 3. Ranked hypotheses (need one authorized read-only check)

1. **H1 — Missing date window + undocumented order (F5, F6).** Most likely and independent of the store. Fix regardless: query `startDate`/`endDate` windows (newest first, overlapping) and sort the whole local repository.
2. **H2 — Wrong or stale store ID (F1–F4).** The hard-coded/saved ID may not be the integrator `storeId` of the operating restaurant, or may be an older record. Check: `GET …/stores` list vs `storeId` in recent packages vs saved `tgoReviewStoreId` vs `restaurantId` in review rows.
3. **H3 — Uber Eats migration.** Per the documentation only Bilecik stores are affected so far, so this is unlikely for an Istanbul restaurant, but a 403 `endpoint.not-available.error` or plain-text 404 would prove it. If migrated, the review API is officially unavailable and the POS must say so with a Partner Panel link; there is no documented replacement.
4. **H4 — Outdated credentials.** Orders still arrive, so the credentials are valid for orders; a 401 on `/stores` or reviews would show otherwise.

## 4. Proposed authorized read-only check (not executed)

Run on the Windows POS (credentials stay in the DPAPI vault; nothing printed except the redacted summary below). **Needs the owner's explicit "yes".** GET requests only, no reply submission:

1. `GET /integrator/store/meal/suppliers/{supplierId}/stores?page=0&size=50` → count, `id`, `name`, `workingStatus` per store.
2. Distinct `storeId` values in packages from the last 7 days (already fetched by the order poller).
3. Saved `tgoReviewStoreId` (if any) and whether it equals `316490`.
4. For each candidate store: `GET …/reviews/filter?page=0&size=1&startDate=<now-30d>&endDate=<now>` → HTTP status, `totalElements`/`totalPages` if present, newest `createdDate`, `restaurantId`.
5. The same without dates, `page=0&size=20` → min/max `createdDate` (confirms H1).

Redacted output kept locally: store count, whether IDs match (yes/no), HTTP status per call, newest/oldest review dates. **Never** API keys, supplier ID, customer names, or review text in GitHub.

## 5. Implementation order after the check (spec §23.6)

1. `TgoStoreIdentityService` (pure Dart, injected transport): `/stores` discovery + order `storeId`s + review `restaurantId`; states `verified | needsSelection | mismatch | unavailable | migrated`; persisted as `{supplierId, storeId, name, verifiedAt, source}`; revalidated on credential change; **no hard-coded fallback**.
2. `ReviewSyncService` started from `main.dart` with the Trendyol integration, independent of the UI: date windows with overlap, all pages, bounded backfill, single-flight, backoff, checkpoints, honest status.
3. Persistent review repository (SQLite entity table keyed `platform + supplierId + storeId + reviewId`).
4. Notification events (§23.5) with first-import suppression; then Yorum Merkezi UI.

Each step lands with synthetic tests listed in §23.6.12.
