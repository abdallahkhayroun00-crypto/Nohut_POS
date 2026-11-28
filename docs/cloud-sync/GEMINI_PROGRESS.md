# Nohut POS 2.0 — Independent QA, Security & Business-Logic Audit (`GEMINI_PROGRESS.md`)

**Agent:** Google Antigravity / Gemini (Independent Engineering, Security & QA)  
**Branch:** `gemini/independent-qa` (PR #45)  
**Last Updated:** 2026-11-28 (Pass 13 Complete — Owner Ownership Update `#7231137435` Acknowledged; PR #44 `865fdd3` QR Publisher & Trendyol Proxy 48/48 Passed; PR #46 Increment D Initial Sync & Required `draftSha256` Implemented/Tested)  
**Canonical QA Matrix:** `docs/qa/FUNCTIONAL_QA_MATRIX.md` (on PR #44)  
**Premium UI/UX Inventory:** `docs/design/PREMIUM_UI_INVENTORY.md` (on PR #44 `865fdd3`)  
**Shared Coordination Board:** `docs/cloud-sync/PROGRESS.md`

---

## 1. Inspected Repository State & Commit SHAs

| Target | Branch / Ref | Commit SHA | Status |
|---|---|---|---|
| Production base | `main` | `ed7ccce` | Merged (`#42`, `#43`) |
| Claude active PR | `claude/project-thread-51u0i4` (PR #44) | `865fdd3` (includes `61cc9c6`, `2b5e6d9`, `865fdd3`) | PR Open (Draft) |
| Codex historical PR | `chatgpt/pr-05b-cloud-rpcs` (PR #39) | `8d918b2` (removed from active assignments per `#7231137435` — preserved untouched) | PR Open (Draft) — 12/12 CI green |
| Gemini Backend PR | `gemini/backend-continuation` (PR #46 → `chatgpt/pr-05b-cloud-rpcs`) | Increment D (`20261127172000`) | PR #46 Open (Draft — `Implemented / Tested`, independent ChatGPT review requested) |
| Gemini QA branch | `gemini/independent-qa` (PR #45) | Active | PR Open (Draft — QA only) |

---

## 2. Audit Scope & Cross-Platform Coverage (7 Surfaces)

| # | Application Surface | Functional QA | Visual / Owner Release Gate | Notes |
|---|---|---|---|---|
| 1 | Windows POS (`flutter_desktop`) | **Tested** (391 baseline + **88/88** Pass 9 + **14/14** Pass 10 + **12/12** independent) | 🔄 QR Menü (`4fde30e`) & Ayarlar IA (`6cff0e3`); ⬜ Masalar/Order/Payment/Reports/Finance | `QA-18` & **`QA-20`** (`QrMenuRemoteService._write` retry) verified resolved on `da7faf5`. |
| 2 | Native Android Personel APK (`flutter_personel`) | **Tested** (**72/72** + **40/40** Pass 10 renders on `da7faf5`) | ✅ **Ana Sayfa Option A** (`da7faf5`, owner approved + **`QA-22` verified resolved**); 🔄 `work_page`, `menu_admin_page` (**`QA-21` verified resolved**); ⬜ Masalar/Sipariş/Sepet/Login | 36 widget-rendered PNGs visually audited; CI API 34 emulator run `46047769476` verified `success` (`D-33`; physical device unverified). |
| 3 | Native Android Yönetici APK (`flutter_personel` manager) | **Tested** (**72/72** + **40/40** Pass 10) | 🔄 Ana Sayfa (**`QA-22` 4-tile grid verified**), Personel/Maaş, QR Menü (**`QA-21` resolved**), Ayarlar; ⬜ Finans | `ownerPayroll` + `ownerMenu*` parity verified (`da7faf5`). |
| 4 | Personel Cloud PWA (`pwa/src/personel`) | **Tested** (**35/35** Vitest incl. Login BFF `QA-19` resolved) | ⬜ Legacy UI pending redesign | Live read RPCs (`QA-09`) & cloud QR relay in progress on `gemini/backend-continuation`. |
| 5 | Yönetici Cloud PWA (`pwa/src/yonetici`) | **Tested** (**35/35** Vitest incl. Login BFF `QA-19` resolved) | ⬜ Legacy UI pending redesign | Live read RPCs (`QA-09`) & cloud QR relay in progress on `gemini/backend-continuation`. |
| 6 | Local Personel Browser App (`assets/staff.html`) | **Tested** (LAN auth + PIN + QR Menü parity) | 🔄 Menü; ⬜ Legacy serif CSS pending token alignment | `QA-17`/`QA-18` verified on LAN API. |
| 7 | Local Yönetici Browser App (`assets/yonetici.html`) | **Tested** (LAN auth + PIN + QR Menü parity + Gün Sonu) | 🔄 Menü; ⬜ Legacy CSS pending token alignment | Gün Sonu Raporu verified free of `staffHours`. |

---

## 3. Premium UI/UX Per-Page Acceptance Checklist (Release Gate)

*Distinguishes **Implemented**, **Functionally Tested**, **Independently Visually Audited (Gemini)**, and **Owner Approved**.*

| Surface / Page | Implemented | Functionally Tested | Visually Audited (Gemini) | Owner Approved | Open Visual / A11y Findings |
|---|---|---|---|---|---|
| Android Personel · **Ana Sayfa (Option A)** (`da7faf5`) | ✅ | ✅ (10 render + 72 suite) | ✅ Audited (320/360/390/430, light/dark, 1.3× offline, tablet) | ✅ **Approved (Option A)** | None (**`QA-22` resolved**) |
| Android Personel/Yönetici · **QR Menü Yönetimi** (`da7faf5`) | ✅ | ✅ (8 tests + 4 renders) | ✅ Audited (light/dark/320 compact) | ⬜ Pending owner review | None (**`QA-21` resolved**) |
| Android Yönetici · **Ana Sayfa** (`da7faf5`) | ✅ | ✅ | ✅ Audited (light/dark/compact/tablet) | ⬜ Pending owner review | None (**`QA-22` 4-tile grid resolved**) |
| Android Yönetici · **Haftalık Maaş Ödemeleri** (`c3d0874`) | ✅ | ✅ | ✅ Audited (light/dark) | ⬜ Pending owner review | None (`QA-16` resolved) |
| Android Yönetici · **Personel & Ayarlar Q2** (`86c2a2a`) | ✅ | ✅ | ✅ Audited (light/dark) | ⬜ Pending owner review | None |
| Android Personel · **Mesai / Vardiya / Maaş** (`d22e706`) | ✅ | ✅ | ✅ Audited (light/dark) | ⬜ Pending owner review | None (`QA-15` resolved) |
| Windows POS · **QR Menü Yönetimi** (`da7faf5`) | ✅ | ✅ (14 remote + 11 UI tests) | ⚠️ Owner physical screenshot `#7228172987` (publisher lifecycle + UI polish queued on Claude) | ⬜ Pending owner retest | Publisher service lifecycle + duplicate heading / collage thumbnails (`#7228172987`) |
| Windows POS · **Masalar Board** (`aea2861`) | ✅ | ✅ (`masalar_render_test` 7 + `pos_flow_render_test` 2) | ✅ Audited (16 PNGs Pass 12: `Icons.open_with`, `Yerleşim Kuralları` stable edit rail, level `<740 px` tiles) | ⬜ Pending owner review | None (**`QA-23` verified resolved**) |
| Windows POS · **Hesap, Sipariş, Ödeme, Raporlar, Finans, Ayarlar** | 🔄 Hesap/Sipariş quick polish (`9dae32e`) | ✅ Existing tests | ✅ Verified `9dae32e` (wrapped categories, single destructive rail) | ⬜ Pending full redesign & owner review | Full redesign queued in `docs/design/PREMIUM_UI_INVENTORY.md` |
| Android Personel · **Masalar, Sipariş, Sepet, Siparişler, Pairing/Login** | ⬜ Redesign queued | ✅ Existing tests | ⬜ Pending redesign | ⬜ Pending | Tracked in `docs/design/PREMIUM_UI_INVENTORY.md` |
| LAN Browser (`staff.html`, `yonetici.html`) & Cloud PWAs | ⬜ Alignment queued | ✅ Existing tests | ⬜ Pending redesign | ⬜ Pending | Tracked in `docs/design/PREMIUM_UI_INVENTORY.md` |

---

## 4. Findings Tracker

| ID | Severity | Priority | Target PR / SHA | Owner | Summary | GitHub Report / Verification | Status |
|---|---|---|---|---|---|---|---|
| **QA-01** | **High** | P0 (Financial / Idempotency) | PR #44 (`08f5812`) | Claude | `recordPayrollPayment` duplicate `requestId` double-counting & irreversible second row. | Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-02** | **High** | P0 (Financial / Payroll) | PR #44 (`08f5812`) | Claude | Deactivated employee with unpaid worked hours vanished from `payrollWeek` and payday reminders. | Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-03** | **High** | P0 (Security / Spec §24.1) | PR #44 (`4249b9e`) | Claude | Trusted-device 5-digit PIN across Windows/LAN and Supabase Cloud; legacy 6-digit verifiers keep unlocking. | Verified on `4249b9e` | **Verified Resolved (`4249b9e`)** |
| **QA-04** | **Medium** | P0 (Security / Auth) | PR #44 (`08f5812`) | Claude | `LocalAuth.unlockWithPassword` bypassed 5-failure 15-min lockout and pre-checks. | Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-05** | ~~Medium~~ | — | PR #44 (`ad35d58`) & PR #46 (`7460879`) | — | ~~`buildDailyReport` `staffHours`.~~ **Owner decision:** Gün Sonu Raporu must **NOT** include employee working hours. Verified absent on LAN/Windows and recursively forbidden at any nesting depth on Cloud (`20261127171000`). | Owner [#7223400650](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223400650) | **Superseded (Owner Decision — Verified Absent)** |
| **QA-06** | **Medium** | P0/P1 (Validation & LAN) | PR #44 (`08f5812`) | Claude | Invalid calendar dates, mid-week `Haftalık Sabit` switch, missing `_privateIp` on LAN, `/api/mobile/bootstrap` auth gate. | Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-07** | **Medium** | P0 (Financial / Schema) | PR #39 (`abbcf31`) | Codex | `combined_payment_groups` enforces `cash_kurus + card_kurus = amount_kurus`, method components, `received_kurus >= cash_kurus`. | Verified [#7225414738](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7225414738) | **Verified Resolved (`abbcf31`)** |
| **QA-08** | **Medium** | P0 (Financial / Terminal) | PR #39 (`abbcf31`) | Codex | `apply_typed_projection` marks all definitive terminal outcomes (`approved`, `declined`, `cancelled`) immutable. | Verified [#7225414738](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7225414738) | **Verified Resolved (`abbcf31`)** |
| **QA-09** | **High** | P1 (Cross-Platform Parity) | PR #39 (`8d918b2`) → PR #46 (`7460879`) | Gemini (temp) / Codex | All 5 typed write projections verified on PR #39. Workforce/payroll reads, QR Menu cloud projection/commands, Notifications/Gün Sonu allowlist + provenance freshness + v2 `qr_menu_reconcile` implemented & tested on **PR #46** (`7460879`). | PR #46 (`cc93cff`, `467f235`, `3fb60e9`, `7460879`) | **Implemented / Tested on PR #46 (Pending Independent Re-Review)** |
| **QA-10** | **Medium** | P0 (Financial / Terminal) | PR #44 (`08f5812`) | Claude | `InposPayments._apply` overwrote definitive `declined`/`cancelled` outcomes back to `unknown`. | Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-11** | **Medium** | P1 (Attribution / Parity) | PR #44 (`08f5812`) | Claude | `submitStaffAction` omitted `staffId` on `pay` and `payMixed` payment rows. | Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-12** | **Medium** | P2 (Performance) | PR #44 (`08f5812`) & PR #39 (`abbcf31`) | Claude / Codex | `command_receipts` indexed (`deleteOrder`: 47 ms → 24 ms), `staff.html` hidden-tab pause, `sync_outbox_pending` partial index (`O-10`). | Verified [#7225414738](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7225414738) | **Verified Resolved (`08f5812` + `abbcf31`)** |
| **QA-13** | **Low/Med** | P1 (Concurrency / Print) | PR #44 (`d22e706`) | Claude | `ReceiptPrinter._commitAfterPrint` retries up to 5 times on `store.replace().ok`. | Verified [#7225442203](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7225442203) | **Verified Resolved (`d22e706`)** |
| **QA-14** | **High (Visual)** | P1 (Spec §24.3 Nav & Design) | PR #44 (`6a83ef7` / `da7faf5`) | Claude | Personel Ana Sayfa redesigned and **Option A ("Özet kartı") approved by owner**; alternative B removed; `QA-22` polish resolved. | Verified [#7228169257](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7228169257) | **Owner Approved Option A (`da7faf5`)** |
| **QA-15** | **Low** | P1 (Visual Polish) | PR #44 (`d22e706`) | Claude | Android `work_page.dart` Maaş tab adds 4th card `Çalışma süresi`, balancing 2×2 grid. | Verified [#7225442203](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7225442203) | **Verified Resolved (`d22e706`)** |
| **QA-16** | **Low** | P2 (UI Field Mismatch) | PR #44 (`c3d0874`) | Claude | `owner_payroll.dart:177` checks `p['reverses'] != null \|\| p['kind'] == 'Düzeltme'` for `Icons.undo`. | Verified [#7226896798](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7226896798) | **Verified Resolved (`c3d0874`)** |
| **QA-17** | **Low/Med** | P0 (Security / Auth) | PR #44 (`d5b6225`) | Claude | Windows `LocalAuth.setPin`, Cloud `public.nohut_set_pin`, and Login BFF require password/recent-JWT-`amr` outside 5-min sign-in window. | Verified [#7227214677](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7227214677) | **Verified Resolved (`d5b6225`)** |
| **QA-18** | **High** | P1 (Owner Decision — QR Menu Parity) | PR #44 (`ea4b42b`) & PR #46 (`7460879`) | Claude / Gemini (temp) | Full `menu.*` parity verified on Windows + LAN Android/Browser + Cloud roles (`ea4b42b`). Cloud projection (`nohut_qr_menu_view`) & remote commands (`qr_menu_*`, incl. v2 `qr_menu_reconcile`) implemented/tested on PR #46 (`7460879`). | Verified [#7227955860](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7227955860) + PR #46 | **Verified Resolved (LAN/Windows/Roles); Cloud Implemented/Tested on PR #46** |
| **QA-19** | **Low** | P1 (Auth BFF & SQL Polish) | PR #44 (`ea4b42b`) | Claude | `bff.ts` returns `403` on wrong password during `setPin` & passes `p_label: null`; `20261127222000` marks `recent_password_auth` `stable`. | Verified [#7227955860](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7227955860) | **Verified Resolved (`ea4b42b`)** |
| **QA-20** | **Medium** | P1 (Concurrency / QR Publish) | PR #44 (`a54387a` / `da7faf5`) | Claude | `QrMenuRemoteService._write` retries up to 5 times on `!store.replace().ok` and throws `QrMenuConflict` if exhausted; covered by `RacyStore` concurrent POS write test. | Verified [#7228169257](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7228169257) | **Verified Resolved (`da7faf5`)** |
| **QA-21** | **Low/Med** | P1 (UI Copy Contradiction) | PR #44 (`a54387a` / `da7faf5`) | Claude | `menu_admin_page.dart:467` guards Windows-only footer behind `if (v['publish'] != 'here')`; visually confirmed absent on `menu-admin-light.png`. | Verified [#7228169257](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7228169257) | **Verified Resolved (`da7faf5`)** |
| **QA-22** | **Low/Med** | P1 (Visual / Accessibility) | PR #44 (`a54387a` / `da7faf5`) | Claude | Option A two-line next-shift footer shows full `Cmt 28 Kas · 10:00–18:00` at 320 dp @ 1.3×; equal-height quick-action & metric rows; Yönetici Dashboard balanced to 4 tiles. Visually verified on `da7faf5` renders. | Verified [#7228169257](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7228169257) | **Verified Resolved (`da7faf5`)** |
| **QA-23** | **Low/Med** | P1 (Visual Polish — Windows Masalar) | PR #44 (`8e52fb4` / `9dae32e` / `aea2861`) | Claude | All 3 visual polish items verified resolved on updated renders: `Icons.open_with` replaces missing glyph; `Yerleşim Kuralları` right rail keeps floor plan stable so `Masa 4` is 100% visible; `<740 px` status tiles align to exact equal row heights at 1.3×; Hesap duplicate destructive button removed; Sipariş category pills wrap cleanly. | Verified Pass 12 (PR #44) | **Verified Resolved (`aea2861`)** |
| **QA-24** | **Low/Med** | P1 (Security — Activation Timing & State Enumeration) | PR #44 (`88b1a3c`) | Claude | Verified resolved on `88b1a3c`: single PBKDF2 `_verify` runs on every path (unknown, expired, voided, inactive, wrong) with one generic `invalid_activation` refusal. | Verified Pass 15 (PR #44) | **Verified Resolved (`88b1a3c`)** |
| **QA-25** | **Low/Med** | P1 (Reliability — Activation Atomicity) | PR #44 (`88b1a3c`) | Claude | Verified resolved on `88b1a3c`: `client`, `deviceId` regex, `device_mismatch`, and `device_revoked` checked before consuming code; `BEGIN IMMEDIATE` wraps password update + conditional `DELETE` (`updatedRows == 1`), blocking concurrent double-use. | Verified Pass 15 (PR #44) | **Verified Resolved (`88b1a3c`)** |
| **QA-26** | **Medium** | P1 (Initial Sync — Stale-Epoch Guard & Active-on-Abort Reconciliation) | PR #51 (`d93b1a9`) | Claude | Verified resolved on `d93b1a9`: `_run()` compares normalized local and server `authority_epoch` before any RPC and marks stale plans `aborted` (`epoch_rotated`); `abort()` checks server status first and reconciles to `_finish()` if already `active`. | Verified Pass 17 (PR #51) | **Verified Resolved (`d93b1a9`)** |
| **QA-27** | **Low/Med** | P1 (Initial Sync — Local SQLite & Backup Bloat) | PR #51 (`d93b1a9`) | Claude | Verified resolved on `d93b1a9`: `_setPlan()` deletes `initial_sync_batches` rows whenever `finished == true` (`active`, `aborted`, `epoch_rotated`), keeping only the lightweight `initial_sync_plan` audit row. | Verified Pass 17 (PR #51) | **Verified Resolved (`d93b1a9`)** |
| **Pass 18** | **PASS** | P1 (Platform Yönetimi LAN API + TGO Receipt + Windows Flow UI) | PR #51 (`a21b02d`) | Claude | Independently audited `yonetici_api.dart`, `platform_api.dart`, `platform_lan_api_test.dart`, `tgo_receipt_render_test.dart`, and `pos_flow_render_test.dart` (1536 & 1280): `platform.view` / `platform.store.toggle` + `confirmed:true` enforced server-side, 3-provider order preserved, no retry on refusal. **4/4 tests PASS**. | Verified Pass 18 (PR #51) | **Independently Verified (`a21b02d`)** |
| **QA-28** | **Medium** | P1 (Visual — Missing Glyphs & Sidebar Clipping on Windows 1280) | PR #51 (`8eeb3ba`) | Claude | Verified resolved on `8eeb3ba` renders (`finans-1280-maas.png`, `section-1280-platform.png`): `Ayarlar › Personel` and `2026-11-23 – 2026-11-29` render crisply with zero tofu boxes; all 11 sidebar items (`Genel Bakış` through `Ayarlar` + footer) fit cleanly at 1280×720 with zero clipping. | Verified Pass 20 (PR #51) | **Verified Resolved (`8eeb3ba`)** |
| **QA-29** | **Low/Med** | P1 (Visual — Duplicate Headings) | PR #51 (`8eeb3ba`) | Claude | Verified resolved on `8eeb3ba` renders (`section-1280-platform.png`, `ayarlar-1536-bulut.png`): single `"Platform Yönetimi"` heading in top bar; `Ayarlar › Bulut & Senkronizasyon` inner card cleanly titled `"Durum ve ilk senkronizasyon"`. | Verified Pass 20 (PR #51) | **Verified Resolved (`8eeb3ba`)** |
| **QA-30** | **Low** | P2 (Visual Polish — Composer Card Spacing at 1280) | PR #51 (`8eeb3ba` / `665cc84`) | Claude | Verified resolved on `8eeb3ba` / `665cc84` renders (`cart-1280-1-items.png`): clean horizontal spacing between `"Falafel Dürüm"` and `"160,00 ₺"` on 1280 composer cards; `composer_units_test.dart` **3/3 PASS**. | Verified Pass 20 (PR #51) | **Verified Resolved (`8eeb3ba` / `665cc84`)** |
| **Pass 20** | **PASS** | P1 (Visual QA + Per-Unit Cart Editing & Ek Sipariş) | PR #51 (`8eeb3ba` / `665cc84` / `343d70f`) | Claude | Re-rendered `composer_cart_render_test.dart` & `sections_render_test.dart` (**7/7 PASS**), visually verified all 4 updated PNGs (`QA-28`, `QA-29`, `QA-30` all resolved), and verified `flutter_desktop/test/composer_units_test.dart` (**3/3 PASS**) + `flutter_personel/test/cart_units_test.dart` (**2/2 PASS**). | Verified Pass 20 (PR #51) | **Independently Verified (`8eeb3ba` / `665cc84` / `343d70f`)** |
| **Pass 21** | **PASS** | P1 (Windows `cloud_capabilities.dart` v1 Client) | PR #51 (`7bedb7c`) | Claude | Independently audited `flutter_desktop/lib/cloud_capabilities.dart` against `docs/contracts/v1/cloud-capabilities.md` (#46 `61b6743`) and ran `cloud_capabilities_test.dart` (**3/3 PASS**): strict v1 parser, HTTPS-only, `followRedirects=false`, 4096 B cap, fail-closed to `CloudCapabilities.none`, zero secret material, local DPAPI paths untouched until cutover. | Verified Pass 21 (PR #51) | **Independently Verified (`7bedb7c`)** |

---

## 5. Tests Executed & Actual Results

| Suite | Target | Command | Result |
|---|---|---|---|
| Desktop baseline | `main` (`ed7ccce`) | `cd flutter_desktop && flutter test --reporter compact` | **391 passed, 3 skipped, 0 failed** |
| Android baseline | `main` (`ed7ccce`) | `cd flutter_personel && flutter test --reporter compact` | **15 passed, 0 failed** |
| PWA + Login BFF 3B-2 (`QA-19`) | PR #44 (`6a83ef7`) | `cd pwa && npm ci && npm test` | **35 passed, 0 failed** (`shared.test.ts` 28 + `bff.test.ts` 7) |
| PR #44 Pass 10 QR concurrency + visual renders | PR #44 (`da7faf5`) | `qr_menu_remote_test` (14) + `menu_admin_test` + `home_render_test` + `screens_render_test` (40) | **14 + 40 passed, 0 failed** + **36 updated PNGs visually verified** |
| PR #44 Pass 12 Windows Masalar/Hesap/Sipariş (`QA-23`) | PR #44 (`aea2861`) | `NOHUT_RENDER_DIR=... flutter test test/visual/masalar_render_test.dart test/visual/pos_flow_render_test.dart` | **9 passed, 0 failed** + updated PNGs visually verified (**`QA-23` resolved**) |
| PR #44 CI Android emulator evidence (`D-33`) | PR #44 (`0e36b63`) | `gh run view 46047769476` (GitHub Actions API 34 emulator) | **`conclusion: success`** (emulator only; physical device unverified) |
| PR #39 Pass 6–7 sync/ledger/workforce suites | PR #39 (`8d918b2`) | 8 Dart sync/ledger/workforce suites | **18 + 5 passed, 0 failed** + **12/12 CI jobs green on `8d918b2`** |
| PR #46 Backend Continuation (A/B/C/D/E/F + Cloud Capabilities + Edge Deploy/Verify) | PR #46 | Local Docker Postgres 16 (superuser + `cloud_migrator` `NOSUPERUSER NOBYPASSRLS`) + Node synthetic tests + GitHub Actions CI | **68/68 migrations & 34/34 SQL tests passed**; `cloud-capabilities` **7/7 PASS**; **8/8 CI jobs GREEN** (`Implemented / Tested`, pending Claude independent review) |
| Synthetic P2 SQLite benchmark (before/after `QA-12`) | `main` (`ed7ccce`) vs PR #44 (`08f5812`) | 500 orders + 500 `command_receipts`, WAL + FULL | `deleteOrder`: **47 ms** (full scan) → **24 ms** (indexed $O(\log N)$) |
| Independent QA regression suite | `gemini/independent-qa` | `flutter test test/independent_qa_audit_test.dart` | **12 passed, 0 failed** |

---

## 6. Remaining Dependencies & Blockers

1. **Backend & Cloud Services (`Implemented / Tested`, all CI GREEN — awaiting Claude's independent cross-review before merge/cutover):**
   - **PR #46 (`gemini/backend-continuation` → `main`):** Increments A–F (Workforce/Payroll, QR Menu Cloud, Notifications & Daily Report, Clean Resync, Platform Yönetimi, Phase 6 Cloud Sales Analytics `SalesView`, expired-lock reap + atomic `nohut_agent_validate_and_read_claim`, HTTP-to-Postgres 16 integration test) + **Cloud Capabilities v1 Edge Function** (`61b6743`, 7/7 PASS) + **Manual Edge Deploy & Safe Read-Only Verify Workflow** (`nohut-supabase-edge-deploy-verify.yml`). 68/68 migrations & 34/34 SQL tests PASS under both `postgres` and `cloud_migrator`.
   - **PR #52 (`gemini/trendyol-cloud-proxy-v1` → `gemini/backend-continuation`, head `f35f796`, 5/5 CI GREEN):** Trendyol Cloud Proxy Edge Function (continuation of PR #50) supporting `verify`, `poll`, `execute` (`Kabul Et`/`Hazır`), `reconcile`, `store_status_read`, `store_status_set` (`Aç/Kapat`); all Claude cross-review findings (`B1`–`B4`, `N1`–`N4`) resolved; disabled by default (`NOHUT_TRENDYOL_PROXY_ENABLED=true` required).
   - **PR #53 (`gemini/cloud-qr-publisher-v2` → `gemini/backend-continuation`, head `eeda48f`, 4/4 CI GREEN):** Cloud QR Publisher Edge Function (continuation of PR #49) using Supabase Secrets GitHub App credentials, 64-hex `draftSha256` binding, aligned SQL review fixtures; disabled by default (`NOHUT_QR_PUBLISHER_ENABLED=true` required).
2. **Active Client Work (Claude — PR #51, `claude/project-thread-51u0i4` → `main`):**
   - Visual QA Pass 20 verified `QA-28`, `QA-29`, and `QA-30` resolved on `8eeb3ba` / `665cc84`.
   - Remaining client cutover wiring to PR #52 (Trendyol Cloud Proxy) and PR #53 (Cloud QR Publisher) once independent cross-reviews complete; local fallbacks stay operational until verified cutover.
3. **Staging Verification & Physical-Device / Production Gates (Owner Gate):**
   - Safe read-only staging secret verification (`qr-publisher-check` & `trendyol-proxy verify`) after PR #46/#52/#53 review & owner approval (never mutating live restaurant data or public QR menu).
   - Physical Windows installer/upgrade retest, physical iPhone Safari `/personel` & `/yonetici` test over trusted local HTTPS (`L4`), physical Android APK tests, second-PC encrypted backup restore, physical thermal printer & InPOS terminal verification, and KVKK legal confirmation prior to production sync cutover.

