# Nohut POS 2.0 — Independent QA, Security & Business-Logic Audit (`GEMINI_PROGRESS.md`)

**Agent:** Google Antigravity / Gemini (Independent Engineering, Security & QA)  
**Branch:** `gemini/independent-qa` (PR #45)  
**Last Updated:** 2026-11-27 (Pass 6 Complete — PR #39 `20c1fa7` & PR #44 `0e36b63` Independent Re-Verification)  
**Canonical QA Matrix:** `docs/qa/FUNCTIONAL_QA_MATRIX.md` (on PR #44)  
**Shared Coordination Board:** `docs/cloud-sync/PROGRESS.md`

---

## 1. Inspected Repository State & Commit SHAs

| Target | Branch / Ref | Commit SHA | Status |
|---|---|---|---|
| Production base | `main` | `ed7ccce` | Merged (`#42`, `#43`) |
| Claude active PR | `claude/project-thread-51u0i4` (PR #44) | `0e36b63` (includes `735d8e9`, `6cff0e3`, `a808dda`, `d22e706`, `0f16a19`, `97bf0c2`, `0e36b63`) | PR Open (Draft) |
| Codex active PR | `chatgpt/pr-05b-cloud-rpcs` (PR #39) | `20c1fa7` (includes `abbcf31`, `b2dcd16`, `8b78745`, `20c1fa7`) | PR Open (Draft) |
| Gemini QA branch | `gemini/independent-qa` (PR #45) | Active | PR Open (Draft) |

---

## 2. Audit Scope & Cross-Platform Coverage (7 Surfaces)

| # | Application Surface | Audit Status | Notes |
|---|---|---|---|
| 1 | Windows POS (`flutter_desktop`) | **Tested** (P0/P1/P2) | 391 baseline tests on `main`; 59/59 core + 8/8 independent verification tests on `08f5812`; 34/34 Pass 6 tests on PR #44 `0e36b63` (`QA-13` print retry, `payroll`, `shifts` break audit, `Ayarlar Q2` step 1); 18/18 Pass 6 sync/ledger tests on PR #39 `20c1fa7` (`QA-07`, `QA-08`, `QA-12`/`O-10`, `QA-09` slices); 10/10 independent regression tests on `gemini/independent-qa`. `deleteOrder` improved **47 ms → 24 ms**. DPAPI & Argon2id/AES-256-GCM backup verified. |
| 2 | Native Android Personel APK (`flutter_personel`) | **Tested & Visually Audited** | Genuine Flutter native app (zero WebView; `flutter_secure_storage`, bundled logo/fonts, `WorkRequestIds` idempotent retry). **42/42 tests passed** on `0e36b63`. Re-rendered `work-2-light.png` visually confirms `QA-15` resolved (balanced 2×2 Maaş grid with `Çalışma süresi`). `QA-14` (`O-12` §24.3 `Ana Sayfa` nav) tracked. |
| 3 | Native Android Yönetici APK (`flutter_personel` manager entry) | **Tested & Visually Audited** | Genuine Flutter native; owner identity not hardcoded (`D-14`); `ExpenseDraftStore` encrypted LAN transport verified; **native Haftalık Maaş Ödemeleri (`735d8e9`)** audited & visually verified (`owner-payroll-light.png`, `owner-payroll-dark.png`) with 1 low finding `QA-16` (`reversalOf` vs `reverses` icon check). |
| 4 | Personel Cloud PWA (`pwa/src/personel`) | **Tested** (unit + code audit) | 28/28 Vitest passed on `main`. Confirmed Bulut/Yedek admin removed (§22). Live auth/commands wait for Phase 3B-2 + PR #39 read RPCs. |
| 5 | Yönetici Cloud PWA (`pwa/src/yonetici`) | **Tested** (unit + code audit) | 28/28 Vitest passed on `main`. Confirmed Bulut/Yedek admin removed (§22). Cloud payroll read RPCs pending (`QA-09`/`O-03`). |
| 6 | Local Personel Browser App (`assets/staff.html`) | **Tested** (code + LAN API) | Employee selector hidden on individual login (`D-02`); unlinked sessions blocked (`D-01`); hidden-tab polling pause (`08f5812`); dark mode verified (`7455259`, `O-01`). |
| 7 | Local Yönetici Browser App (`assets/yonetici.html`) | **Tested** (code + LAN API) | Login always required; finance gated by HTTPS or explicit owner switch; payroll gated by `payroll.view`/`payroll.manage`; Gün Sonu Raporu verified free of employee working hours (`ad35d58`); dark mode verified (`7455259`). Ayarlar Q2 inventory documented (`a808dda`). |

---

## 3. Verified Functionality (Passes 1–6)

- **Windows-only Bulut & Yedek isolation (§22):** Verified across `local_accounts.dart`, `supabase/migrations/20261127005000_nohut_auth_control_plane.sql`, `20261127131000_nohut_app_commands.sql`, `pwa/src/`, `flutter_personel/lib/`, and `docs/qa/SETTINGS_INVENTORY.md`. `sync.*` and `backup.*` are refused (`windows_only`) for all remote clients including the owner.
- **Backup encryption & Windows DPAPI:** `backup_container.dart` uses Argon2id (64 MiB, 3 iter, refuses parameter downgrade) + AES-256-GCM with header bytes as AAD + 260-bit recovery key + staged restore with `PRAGMA integrity_check`. `windows_vault.dart` uses DPAPI (`CRYPTPROTECT_UI_FORBIDDEN`) with explicit buffer zeroing and atomic rename.
- **Restaurant operations, concurrency & duplicate prevention:** `PosStore.command` (`BEGIN IMMEDIATE` + `command_receipts` + `deleted_requests` + indexed `order_id`/`result_order_id`), `splitEqually` exact kuruş remainder, `refundPayment` cap & guest allocation guard, `cancelLocalOrder` payment guard, `recordCombinedPickupPayment` detached-copy atomicity, `InposPayments` no-double-charge & final `approved`/`declined`/`cancelled` state machine (`08f5812`), `ReceiptPrinter._commitAfterPrint` revision-race retry (`d22e706`), `MobilePairing` SHA-256/throttling/revocation.
- **Payroll & Gün Sonu Raporu (PR #44 `0e36b63`):** Owner acceptance scenario (`8 h × 100 TL + 8 h × 120 TL = 1,760 TL` → `800 TL` → `Kısmen Ödendi` → `960 TL` → `Ödendi` → non-retroactive raise), idempotent `recordPayrollPayment`, departed employee unpaid dues retention, calendar date validation, Monday-only pay-type switching, native Android Yönetici `OwnerPayrollPage` (`735d8e9`), and Gün Sonu Raporu strictly omitting employee working hours (`ad35d58`).
- **Dashboards & analytics:** Verified `order_reporting.dart` (Istanbul UTC+3), `platform_net.dart` (delivered non-demo only, `null` when deduction unconfigured), `overview_metrics.dart` (sales vs collections strictly separated).
- **Cloud auth, command queue & typed projections (PR #39 `20c1fa7`):** Verified `canonical_command_json`, identity binding, PII restriction, unlinked-account rejection (`actor not linked`), claim-time reauthorization, `FORCE ROW LEVEL SECURITY`, A1 `aal2` Windows agent enrollment, atomic >500-event commit batching, `sync_outbox_pending` partial index (`abbcf31`), `combined_payment_groups` component constraints (`abbcf31`), definitive terminal outcome immutability (`abbcf31`), `employee_wage_history` + `payroll_eligible` (`b2dcd16`), immutable `payroll_payments`/`payroll_reviews` with exact reversal checks (`8b78745`), and `shifts` `source='manual'` break/void/correction chains (`20c1fa7`).

---

## 4. Findings Tracker

| ID | Severity | Priority | Target PR / SHA | Owner | Summary | GitHub Report / Verification | Status |
|---|---|---|---|---|---|---|---|
| **QA-01** | **High** | P0 (Financial / Idempotency) | PR #44 (`ab4b3ff` / `08f5812`) | Claude | `recordPayrollPayment` duplicate `requestId` double-counting & irreversible second row. | Reported [#7223333964](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223333964) · Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-02** | **High** | P0 (Financial / Payroll) | PR #44 (`ab4b3ff` / `08f5812`) | Claude | Deactivated employee with unpaid worked hours vanished from `payrollWeek` and payday reminders. | Reported [#7223333964](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223333964) · Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-03** | **High** | P0 (Security / Spec §24.1) | PR #44 (`ab4b3ff` / `4249b9e`) | Claude | Trusted-device 5-digit PIN across Windows/LAN (`local_accounts.dart`) and Supabase Cloud (`20261127210000_nohut_pin_five_digits.sql`); legacy 6-digit verifiers keep unlocking. | Reported [#7223333964](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223333964) · Verified on `4249b9e` | **Verified Resolved (`4249b9e`)** |
| **QA-04** | **Medium** | P0 (Security / Auth) | PR #44 (`ab4b3ff` / `08f5812`) | Claude | `LocalAuth.unlockWithPassword` bypassed 5-failure 15-min lockout and pre-checks. | Reported [#7223333964](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223333964) · Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-05** | ~~Medium~~ | — | PR #44 (`ad35d58` / `08f5812`) | — | ~~`buildDailyReport` `staffHours`.~~ **Owner decision:** Gün Sonu Raporu must **NOT** include employee working hours. Verified absent from `daily_report.dart`, `daily_report_ui.dart`, `yonetici.html`. | Owner [#7223400650](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223400650) / [#7223423784](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/45#issuecomment-7223423784) · Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Superseded (Owner Decision — Verified Absent)** |
| **QA-06** | **Medium** | P0/P1 (Validation & LAN) | PR #44 (`ab4b3ff` / `08f5812`) | Claude | Invalid calendar dates (`2026-02-31`), mid-week `Haftalık Sabit` switch, missing `_privateIp` on LAN reads/writes, `/api/mobile/bootstrap` auth gate. | Reported [#7223333964](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223333964) · Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-07** | **Medium** | P0 (Financial / Schema) | PR #39 (`abbcf31`) | Codex | `combined_payment_groups` (`20261127154000_nohut_ledger_integrity.sql`) enforces `cash_kurus + card_kurus = amount_kurus`, method-component consistency, and `received_kurus >= cash_kurus`. | Reported [#7223334066](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7223334066) · Verified [#7225414738](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7225414738) | **Verified Resolved (`abbcf31`)** |
| **QA-08** | **Medium** | P0 (Financial / Terminal) | PR #39 (`abbcf31`) | Codex | `apply_typed_projection` (`20261127154000_nohut_ledger_integrity.sql`) marks all definitive terminal outcomes (`approved`, `declined`, `cancelled`) immutable. | Reported [#7223334066](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7223334066) · Verified [#7225414738](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7225414738) | **Verified Resolved (`abbcf31`)** |
| **QA-09** | **High** | P1 (Cross-Platform Parity) | PR #39 (`20c1fa7`) | Codex | **3 slices verified clean (`b2dcd16`, `8b78745`, `20c1fa7`):** `payrollEligible` + `payHistory`, `payrollPayments`/reversals/`payrollReviews`, and `source='manual'` Mesai breaks/voids/correction chains. **Remaining (`O-03`):** `shiftPlans`, `timesheetWeeks`, authorized payroll/workforce read RPCs, and `orders[].payments[].staffId`. | Reported [#7223334066](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7223334066) · Partial Verified [#7225414738](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7225414738) | **In Progress (3 slices verified)** |
| **QA-10** | **Medium** | P0 (Financial / Terminal) | PR #44 (`08f5812`) | Claude | `InposPayments._apply` overwrote definitive `declined`/`cancelled` outcomes back to `unknown` on offline `reconcile()`. | Reported [#7223539958](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223539958) · Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-11** | **Medium** | P1 (Attribution / Parity) | PR #44 (`08f5812`) | Claude | `submitStaffAction` omitted `staffId` on `pay` and `payMixed` payment rows. | Reported [#7223539958](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223539958) · Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-12** | **Medium** | P2 (Performance / Scalability) | PR #44 (`08f5812`) & PR #39 (`abbcf31`) | Claude / Codex | **Fully resolved across both PRs:** `command_receipts` indexed on `order_id`/`result_order_id` (`deleteOrder`: **47 ms → 24 ms**), `staff.html` hidden-tab polling pause (`08f5812`), and `sync_outbox_pending ON sync_outbox(seq) WHERE acked_at IS NULL` (`abbcf31`, Matrix `O-10`). | Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) & [#7225414738](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7225414738) | **Verified Resolved (`08f5812` + `abbcf31`)** |
| **QA-13** | **Low/Med** | P1 (Concurrency / Print Queue) | PR #44 (`d22e706`) | Claude | `ReceiptPrinter._commitAfterPrint` retries up to 5 times on `store.replace().ok` for both Trendyol kitchen tickets and local print jobs, preventing stuck `'Gönderiliyor'` jobs. | Reported [#7224086253](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7224086253) · Verified [#7225442203](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7225442203) | **Verified Resolved (`d22e706`)** |
| **QA-14** | **Low/Med** | P1 (Spec §24.3 Nav Parity) | PR #44 (`0e36b63`) | Claude | Android Personel still opens on `Masalar` (5 tabs) instead of **Ana Sayfa** (`Ana Sayfa · Masalar · Siparişler · Online · Daha Fazla` per Spec §24.1/§24.3). Recorded as `O-12`. | [PR #44 #7224563633](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7224563633) | Tracked (`O-12`) |
| **QA-15** | **Low** | P1 (Visual Polish) | PR #44 (`d22e706`) | Claude | Android `work_page.dart` Maaş tab adds 4th card `Çalışma süresi`, balancing the 2×2 `NohutMetricGrid` (visually verified on `work-2-light.png`). | Reported [#7224563633](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7224563633) · Verified [#7225442203](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7225442203) | **Verified Resolved (`d22e706`)** |
| **QA-16** | **Low** | P2 (UI Field Mismatch) | PR #44 (`735d8e9` / `0e36b63`) | Claude | `flutter_personel/lib/owner_payroll.dart:177` checks `p['reversalOf'] != null` for `Icons.undo`, whereas `flutter_desktop/lib/payroll.dart:271` emits `'reverses': original['id']` (and `'kind': 'Düzeltme'`). | [PR #44 #7225442203](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7225442203) | Open (Pending fix) |

---

## 5. Tests Executed & Actual Results

| Suite | Target | Command | Result |
|---|---|---|---|
| Desktop baseline | `main` (`ed7ccce`) | `cd flutter_desktop && flutter test --reporter compact` | **391 passed, 3 skipped, 0 failed** |
| Android baseline | `main` (`ed7ccce`) | `cd flutter_personel && flutter test --reporter compact` | **15 passed, 0 failed** |
| PWA baseline | `main` (`ed7ccce`) | `cd pwa && npm ci && npm test` | **28 passed, 0 failed** |
| PR #44 Pass 3 core + independent suites | PR #44 (`08f5812`) | 6 desktop suites + standalone `verify_pass3_pr44.dart` | **59 + 8 passed, 0 failed** |
| PR #44 Pass 6 Android full suite & visual audit | PR #44 (`0e36b63`) | `cd flutter_personel && flutter test` + `NOHUT_RENDER_DIR=... flutter test test/visual/screens_render_test.dart` | **42 passed, 0 failed** + **12 light/dark PNGs rendered** (`work-2-light`, `owner-payroll-light/dark` visually verified) |
| PR #44 Pass 6 desktop targeted suites | PR #44 (`0e36b63`) | `flutter test test/tgo_kitchen_print_test.dart test/payroll_test.dart test/shifts_test.dart test/updates16_ui_test.dart test/brand_navigation_test.dart` | **34 passed, 0 failed** |
| PR #39 Pass 6 sync/ledger/payroll/attendance suites | PR #39 (`20c1fa7`) | `flutter test test/sync_outbox_hardening_test.dart test/employee_wage_sync_test.dart test/payroll_ledger_sync_test.dart test/manual_attendance_sync_test.dart test/payment_ledger_sync_test.dart test/cloud_finance_serializer_test.dart` | **18 passed, 0 failed** + CI `synthetic-postgres` (×3) & `synthetic-http-postgres` green |
| Synthetic P2 SQLite benchmark (before/after `QA-12`) | `main` (`ed7ccce`) vs PR #44 (`08f5812`) | 500 orders + 500 `command_receipts`, WAL + FULL | `deleteOrder`: **47 ms** (full scan) → **24 ms** (indexed $O(\log N)$) |
| Independent QA regression suite | `gemini/independent-qa` | `flutter test test/independent_qa_audit_test.dart` | **10 passed, 0 failed** |

---

## 6. Remaining Dependencies & Blockers

1. **Remaining work on Codex (PR #39 — currently at `20c1fa7`):**
   - `QA-09` / `O-03` remaining slices: planned schedules (`shiftPlans`), weekly submission snapshots (`timesheetWeeks`), authorized payroll/workforce read RPCs (enforcing owner exclusion & employee privacy), and `orders[].payments[].staffId` attribution mapping.
2. **Remaining work on Claude (PR #44 — currently at `0e36b63`):**
   - `QA-16`: Fix `owner_payroll.dart:177` reversal icon key (`p['reverses']` instead of `p['reversalOf']`).
   - `QA-14` (`O-12`): Android Personel `Ana Sayfa` navigation (§24.1/§24.3).
   - **Ayarlar Q2** remaining audit & redesign steps (steps 1–2 complete).
   - **Phase 3B-2** Login BFF + cloud auth on PWAs/Android.
3. **Physical-Device Tests Required (Owner Gate — Not Performed by Agents):**
   - Physical iPhone Safari test of local `/personel` and `/yonetici` over trusted local HTTPS (`L4`).
   - Physical Android phone installation & testing of signed Personel and Yönetici APKs (biometrics, keyboard, back button, LAN/cloud reconnect, notifications).
   - Physical Windows second-PC encrypted backup restore verification (Phase 1).
   - Physical thermal receipt printer & InPOS card terminal verification.
   - KVKK legal review confirmation prior to enabling real production data sync to Supabase.
