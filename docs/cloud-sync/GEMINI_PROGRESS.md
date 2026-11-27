# Nohut POS 2.0 — Independent QA, Security & Business-Logic Audit (`GEMINI_PROGRESS.md`)

**Agent:** Google Antigravity / Gemini (Independent Engineering, Security & QA)  
**Branch:** `gemini/independent-qa` (PR #45)  
**Last Updated:** 2026-11-27 (Pass 9 Complete — PR #44 `6a83ef7` QA-18/19 Verification, Option A & QR Menü Visual/Accessibility Audit)  
**Canonical QA Matrix:** `docs/qa/FUNCTIONAL_QA_MATRIX.md` (on PR #44)  
**Premium UI/UX Inventory:** `docs/design/PREMIUM_UI_INVENTORY.md` (on PR #44 `c29a882`)  
**Shared Coordination Board:** `docs/cloud-sync/PROGRESS.md`

---

## 1. Inspected Repository State & Commit SHAs

| Target | Branch / Ref | Commit SHA | Status |
|---|---|---|---|
| Production base | `main` | `ed7ccce` | Merged (`#42`, `#43`) |
| Claude active PR | `claude/project-thread-51u0i4` (PR #44) | `6a83ef7` (includes `4fde30e`, `382e355`, `ea4b42b`, `e0ac71d`, `c29a882`, `6a83ef7`) | PR Open (Draft) |
| Codex active PR | `chatgpt/pr-05b-cloud-rpcs` (PR #39) | `8d918b2` (Codex temporarily usage-limited) | PR Open (Draft) — 12/12 CI green |
| Gemini QA branch | `gemini/independent-qa` (PR #45) | Active | PR Open (Draft) |

---

## 2. Audit Scope & Cross-Platform Coverage (7 Surfaces)

| # | Application Surface | Functional QA | Visual / Owner Release Gate | Notes |
|---|---|---|---|---|
| 1 | Windows POS (`flutter_desktop`) | **Tested** (391 baseline + **88/88** Pass 9 auth/QR + **12/12** independent) | 🔄 QR Menü (`4fde30e`) & Ayarlar IA (`6cff0e3`); ⬜ Masalar/Order/Payment/Reports/Finance | `QA-18` LAN/Windows parity verified (`ea4b42b`); logged **`QA-20`** (`QrMenuRemoteService._write` revision-race retry). |
| 2 | Native Android Personel APK (`flutter_personel`) | **Tested** (**72/72** on `6a83ef7`) | ✅ **Ana Sayfa Option A** (`6a83ef7`, owner approved; polish `QA-22`); 🔄 `work_page`, `menu_admin_page` (`QA-21`); ⬜ Masalar/Sipariş/Sepet/Login | 36 widget-rendered PNGs visually audited; CI API 34 emulator run `46047769476` verified `success` (`D-33`; physical device unverified). |
| 3 | Native Android Yönetici APK (`flutter_personel` manager) | **Tested** (**72/72** shared suite) | 🔄 Ana Sayfa (`QA-22` orphan tile), Personel/Maaş, QR Menü (`QA-21`), Ayarlar; ⬜ Finans | `ownerPayroll` + `ownerMenu*` parity verified (`ea4b42b`). |
| 4 | Personel Cloud PWA (`pwa/src/personel`) | **Tested** (**35/35** Vitest incl. Login BFF `QA-19` resolved) | ⬜ Legacy UI pending redesign | Live read RPCs (`QA-09`) & cloud QR relay wait for Codex. |
| 5 | Yönetici Cloud PWA (`pwa/src/yonetici`) | **Tested** (**35/35** Vitest incl. Login BFF `QA-19` resolved) | ⬜ Legacy UI pending redesign | Live read RPCs (`QA-09`) & cloud QR relay wait for Codex. |
| 6 | Local Personel Browser App (`assets/staff.html`) | **Tested** (LAN auth + PIN + QR Menü parity) | 🔄 Menü; ⬜ Legacy serif CSS pending token alignment | `QA-17`/`QA-18` verified on LAN API. |
| 7 | Local Yönetici Browser App (`assets/yonetici.html`) | **Tested** (LAN auth + PIN + QR Menü parity + Gün Sonu) | 🔄 Menü; ⬜ Legacy CSS pending token alignment | Gün Sonu Raporu verified free of `staffHours`. |

---

## 3. Premium UI/UX Per-Page Acceptance Checklist (Release Gate)

*Distinguishes **Implemented**, **Functionally Tested**, **Independently Visually Audited (Gemini)**, and **Owner Approved**.*

| Surface / Page | Implemented | Functionally Tested | Visually Audited (Gemini) | Owner Approved | Open Visual / A11y Findings |
|---|---|---|---|---|---|
| Android Personel · **Ana Sayfa (Option A)** (`6a83ef7`) | ✅ | ✅ (10 render + 72 suite) | ✅ Audited (320/360/390/430, light/dark, 1.3× offline, tablet) | ✅ **Approved (Option A)** | **`QA-22`:** 320/360 dp next-shift end-time truncation + 1.3× quick-action unequal row height |
| Android Personel/Yönetici · **QR Menü Yönetimi** (`ea4b42b`) | ✅ | ✅ (8 tests + 4 renders) | ✅ Audited (light/dark/320 compact) | ⬜ Pending owner review | **`QA-21`:** Stale Windows-only footer copy (`menu_admin_page.dart:468`) |
| Android Yönetici · **Ana Sayfa** (`9e4676c`) | ✅ | ✅ | ✅ Audited (light/dark/compact/tablet) | ⬜ Pending owner review | **`QA-22`:** 5-card grid leaves `Aktif masa` as orphan tile |
| Android Yönetici · **Haftalık Maaş Ödemeleri** (`c3d0874`) | ✅ | ✅ | ✅ Audited (light/dark) | ⬜ Pending owner review | None (`QA-16` resolved) |
| Android Yönetici · **Personel & Ayarlar Q2** (`86c2a2a`) | ✅ | ✅ | ✅ Audited (light/dark) | ⬜ Pending owner review | None |
| Android Personel · **Mesai / Vardiya / Maaş** (`d22e706`) | ✅ | ✅ | ✅ Audited (light/dark) | ⬜ Pending owner review | None (`QA-15` resolved) |
| Windows POS · **QR Menü Yönetimi** (`4fde30e`) | ✅ | ✅ (11 tests) | ⬜ Pending Windows render | ⬜ Pending owner review | **`QA-20`** (concurrency retry in `qr_menu_remote.dart`) |
| Windows POS · **Masalar, Sipariş, Ödeme, Raporlar, Finans, Ayarlar** | ⬜ Redesign queued | ✅ Existing tests | ⬜ Pending redesign | ⬜ Pending | Tracked in `docs/design/PREMIUM_UI_INVENTORY.md` |
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
| **QA-05** | ~~Medium~~ | — | PR #44 (`ad35d58`) | — | ~~`buildDailyReport` `staffHours`.~~ **Owner decision:** Gün Sonu Raporu must **NOT** include employee working hours. Verified absent. | Owner [#7223400650](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223400650) | **Superseded (Owner Decision — Verified Absent)** |
| **QA-06** | **Medium** | P0/P1 (Validation & LAN) | PR #44 (`08f5812`) | Claude | Invalid calendar dates, mid-week `Haftalık Sabit` switch, missing `_privateIp` on LAN, `/api/mobile/bootstrap` auth gate. | Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-07** | **Medium** | P0 (Financial / Schema) | PR #39 (`abbcf31`) | Codex | `combined_payment_groups` enforces `cash_kurus + card_kurus = amount_kurus`, method components, `received_kurus >= cash_kurus`. | Verified [#7225414738](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7225414738) | **Verified Resolved (`abbcf31`)** |
| **QA-08** | **Medium** | P0 (Financial / Terminal) | PR #39 (`abbcf31`) | Codex | `apply_typed_projection` marks all definitive terminal outcomes (`approved`, `declined`, `cancelled`) immutable. | Verified [#7225414738](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7225414738) | **Verified Resolved (`abbcf31`)** |
| **QA-09** | **High** | P1 (Cross-Platform Parity) | PR #39 (`8d918b2`) | Codex | All 5 typed write projections + payment collector attribution verified clean. **Still OPEN (`O-03`):** authorized weekly payroll/workforce read RPCs & cloud client wiring (blocked while Codex is usage-limited). | Verified [#7226886518](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7226886518) | **In Progress — Blocked on Codex usage limit** |
| **QA-10** | **Medium** | P0 (Financial / Terminal) | PR #44 (`08f5812`) | Claude | `InposPayments._apply` overwrote definitive `declined`/`cancelled` outcomes back to `unknown`. | Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-11** | **Medium** | P1 (Attribution / Parity) | PR #44 (`08f5812`) | Claude | `submitStaffAction` omitted `staffId` on `pay` and `payMixed` payment rows. | Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-12** | **Medium** | P2 (Performance) | PR #44 (`08f5812`) & PR #39 (`abbcf31`) | Claude / Codex | `command_receipts` indexed (`deleteOrder`: 47 ms → 24 ms), `staff.html` hidden-tab pause, `sync_outbox_pending` partial index (`O-10`). | Verified [#7225414738](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7225414738) | **Verified Resolved (`08f5812` + `abbcf31`)** |
| **QA-13** | **Low/Med** | P1 (Concurrency / Print) | PR #44 (`d22e706`) | Claude | `ReceiptPrinter._commitAfterPrint` retries up to 5 times on `store.replace().ok`. | Verified [#7225442203](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7225442203) | **Verified Resolved (`d22e706`)** |
| **QA-14** | **High (Visual)** | P1 (Spec §24.3 Nav & Design) | PR #44 (`6a83ef7`) | Claude | Personel Ana Sayfa redesigned and **Option A ("Özet kartı") approved by owner** (`6a83ef7`); alternative B removed. Remaining accessibility/polish fixes tracked in `QA-22`. | Verified [#7227955860](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7227955860) | **Owner Approved Option A (Polish in `QA-22`)** |
| **QA-15** | **Low** | P1 (Visual Polish) | PR #44 (`d22e706`) | Claude | Android `work_page.dart` Maaş tab adds 4th card `Çalışma süresi`, balancing 2×2 grid. | Verified [#7225442203](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7225442203) | **Verified Resolved (`d22e706`)** |
| **QA-16** | **Low** | P2 (UI Field Mismatch) | PR #44 (`c3d0874`) | Claude | `owner_payroll.dart:177` checks `p['reverses'] != null \|\| p['kind'] == 'Düzeltme'` for `Icons.undo`. | Verified [#7226896798](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7226896798) | **Verified Resolved (`c3d0874`)** |
| **QA-17** | **Low/Med** | P0 (Security / Auth) | PR #44 (`d5b6225` / `6a83ef7`) | Claude | Windows `LocalAuth.setPin`, Cloud `public.nohut_set_pin`, and Login BFF require password/recent-JWT-`amr` outside 5-min sign-in window. Re-confirmed in Pass 9. | Verified [#7227214677](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7227214677) · Re-confirmed [#7227955860](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7227955860) | **Verified Resolved (`d5b6225`, re-confirmed)** |
| **QA-18** | **High** | P1 (Owner Decision — QR Menu Parity) | PR #44 (`ea4b42b`) | Claude | Full `menu.*` parity (incl. publish, photo upload, POS sync, 3-way draft merge, lost-answer reconcile) verified for Personel & Yönetici on Windows + LAN Android/Browser + Cloud role templates (`20261127221000`). Cloud PWA remote relay waits for Codex. | Verified [#7227955860](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7227955860) | **Verified Resolved (`ea4b42b` — LAN/Windows/Roles; Cloud relay on Codex)** |
| **QA-19** | **Low** | P1 (Auth BFF & SQL Polish) | PR #44 (`ea4b42b`) | Claude | `bff.ts` returns `403` on wrong password during `setPin` & passes `p_label: null`; `20261127222000` marks `recent_password_auth` `stable`. | Verified [#7227955860](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7227955860) | **Verified Resolved (`ea4b42b`)** |
| **QA-20** | **Medium** | P1 (Concurrency / QR Publish) | PR #44 (`ea4b42b` / `6a83ef7`) | Claude | `QrMenuRemoteService._write` (`qr_menu_remote.dart:287-292`) ignores `store.replace().ok`; a revision race with a concurrent POS order/payment write can silently drop `qrPublisherPendingPublish` clear or new revision after GitHub accepts a publish. | [PR #44 #7227955860](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7227955860) | Open (Pending fix) |
| **QA-21** | **Low/Med** | P1 (UI Copy Contradiction) | PR #44 (`ea4b42b` / `6a83ef7`) | Claude | `menu_admin_page.dart:468` still shows stale footer `"Fotoğraf yükleme ve QR menüde yayınlama Windows’taki QR Menü Yönetimi’nden yapılır."` below the live `Yayınla` button. | [PR #44 #7227955860](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7227955860) | Open (Pending fix) |
| **QA-22** | **Low/Med** | P1 (Visual / Accessibility) | PR #44 (`6a83ef7`) | Claude | (1) Option A green card footer truncates next-shift end time at 360 dp & 320 dp @ 1.3× (`10:00-1...` / `Cmt 2...`); (2) 320 dp @ 1.3× `HIZLI İŞLEMLER` paired tiles have unequal heights when one wraps; (3) Yönetici Dashboard 5-card grid leaves `Aktif masa` as an orphan tile. | [PR #44 #7227955860](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7227955860) | Open (Pending fix) |

---

## 5. Tests Executed & Actual Results

| Suite | Target | Command | Result |
|---|---|---|---|
| Desktop baseline | `main` (`ed7ccce`) | `cd flutter_desktop && flutter test --reporter compact` | **391 passed, 3 skipped, 0 failed** |
| Android baseline | `main` (`ed7ccce`) | `cd flutter_personel && flutter test --reporter compact` | **15 passed, 0 failed** |
| PWA + Login BFF 3B-2 (`QA-19`) | PR #44 (`6a83ef7`) | `cd pwa && npm ci && npm test` | **35 passed, 0 failed** (`shared.test.ts` 28 + `bff.test.ts` 7) |
| PR #44 Pass 9 Android full suite & widget renders | PR #44 (`6a83ef7`) | `cd flutter_personel && NOHUT_RENDER_DIR=... flutter test` | **72 passed, 0 failed** + **36 light/dark/compact/tablet widget-rendered PNGs** visually audited |
| PR #44 Pass 9 desktop auth + QR menu suites | PR #44 (`6a83ef7`) | `flutter test test/local_accounts_test.dart test/lan_auth_gate_test.dart test/*qr*_test.dart test/campaign_menu_test.dart` | **88 passed, 0 failed** |
| PR #44 CI Android emulator evidence (`D-33`) | PR #44 (`0e36b63`) | `gh run view 46047769476` (GitHub Actions API 34 emulator) | **`conclusion: success`** (emulator only; physical device unverified) |
| PR #39 Pass 6–7 sync/ledger/workforce suites | PR #39 (`8d918b2`) | 8 Dart sync/ledger/workforce suites | **18 + 5 passed, 0 failed** + **12/12 CI jobs green on `8d918b2`** |
| Synthetic P2 SQLite benchmark (before/after `QA-12`) | `main` (`ed7ccce`) vs PR #44 (`08f5812`) | 500 orders + 500 `command_receipts`, WAL + FULL | `deleteOrder`: **47 ms** (full scan) → **24 ms** (indexed $O(\log N)$) |
| Independent QA regression suite | `gemini/independent-qa` | `flutter test test/independent_qa_audit_test.dart` | **12 passed, 0 failed** |

---

## 6. Remaining Dependencies & Blockers

1. **Blocked on Codex (temporarily usage-limited — PR #39 at `8d918b2`):**
   - `QA-09` / `O-03`: authorized weekly payroll/workforce read RPCs & cloud client wiring.
   - Cloud remote relay for QR Menu Management edits/publish through Windows (for Cloud PWAs).
2. **Active work on Claude (PR #44 — currently at `6a83ef7`):**
   - `QA-20`: `QrMenuRemoteService._write` revision-race retry loop.
   - `QA-21`: Remove/guard stale Windows-only footer in `menu_admin_page.dart:468`.
   - `QA-22`: Option A next-shift 2-line footer + equal-height quick-action rows + Yönetici Dashboard orphan tile.
   - **Premium UI/UX Release Gate** remaining surfaces per `docs/design/PREMIUM_UI_INVENTORY.md` (shared components → Windows Masalar/Order/Payment → Android Masalar/Sipariş/Siparişler → Dashboards/Reports → Ayarlar/Finance/Market → Browser/PWA alignment).
3. **Physical-Device & Production Gates (Owner Gate — Not Performed by Agents):**
   - Physical iPhone Safari test of local `/personel` and `/yonetici` over trusted local HTTPS (`L4`).
   - Physical Android phone installation & testing of signed Personel and Yönetici APKs (biometrics, keyboard, back button, LAN/cloud reconnect, notifications).
   - Physical Windows second-PC encrypted backup restore verification (Phase 1).
   - Physical thermal receipt printer & InPOS card terminal verification.
   - KVKK legal review confirmation prior to enabling real production data sync to Supabase.
