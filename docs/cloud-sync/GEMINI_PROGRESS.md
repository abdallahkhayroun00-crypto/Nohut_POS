# Nohut POS 2.0 — Independent QA, Security & Business-Logic Audit (`GEMINI_PROGRESS.md`)

**Agent:** Google Antigravity / Gemini (Independent Engineering, Security & QA)  
**Branch:** `gemini/independent-qa` (PR #45)  
**Last Updated:** 2026-11-27 (Pass 5 Complete — PR #44 `7455259` Android Native UI & Visual Audit)  
**Canonical QA Matrix:** `docs/qa/FUNCTIONAL_QA_MATRIX.md` (on PR #44)  
**Shared Coordination Board:** `docs/cloud-sync/PROGRESS.md`

---

## 1. Inspected Repository State & Commit SHAs

| Target | Branch / Ref | Commit SHA | Status |
|---|---|---|---|
| Production base | `main` | `ed7ccce` | Merged (`#42`, `#43`) |
| Claude active PR | `claude/project-thread-51u0i4` (PR #44) | `7455259a505689341c56ce399c69dbb0e6eee377` (includes `a9b6351`, `8bf92c0`, `7fe404a`, `7455259`) | PR Open (Draft) |
| Codex active PR | `chatgpt/pr-05b-cloud-rpcs` (PR #39) | `e826e0626cf1eaac91aa09c3ff09c1cf0105446e` (no new commits yet; resumed by ChatGPT at 17:05Z) | PR Open (Draft) |
| Gemini QA branch | `gemini/independent-qa` (PR #45) | Active | PR Open (Draft) |

---

## 2. Audit Scope & Cross-Platform Coverage (7 Surfaces)

| # | Application Surface | Audit Status | Notes |
|---|---|---|---|
| 1 | Windows POS (`flutter_desktop`) | **Tested** (P0/P1/P2) | 391 baseline tests on `main`; 59/59 core tests + 8/8 independent verification tests passed on PR #44 (`08f5812`); 37 sync/ledger tests on PR #39 (`e826e06`); 10/10 independent regression tests on `gemini/independent-qa`. `deleteOrder` with 500 receipts improved from 47 ms → 24 ms ($O(\log N)$ indexed). DPAPI & Argon2id/AES-256-GCM backup verified. |
| 2 | Native Android Personel APK (`flutter_personel`) | **Tested & Visually Audited** | Genuine Flutter native app (zero WebView; `flutter_secure_storage`, bundled logo/fonts, `WorkRequestIds` idempotent retry). **34/34 tests passed** on `7455259`. Rendered light/dark PNGs (`staff-home`, `work-0..2`) visually verified: forest green/cream/gold identity, zero clipping, exact kuruş formatting. Notes `QA-14` (§24.3 nav), `QA-15` (Maaş 2×2 grid). |
| 3 | Native Android Yönetici APK (`flutter_personel` manager entry) | **Tested & Visually Audited** | Genuine Flutter native; owner identity not hardcoded (`D-14`); `ExpenseDraftStore` encrypted LAN transport verified. Rendered light/dark `owner-dashboard` PNGs visually verified: crisp hourly chart, readable dark/light contrast, zero emoji icons. V6.0/V6.1 payroll cloud projection pending (`QA-09`). |
| 4 | Personel Cloud PWA (`pwa/src/personel`) | **Tested** (unit + code audit) | 28/28 Vitest passed on `main`. Confirmed Bulut/Yedek admin removed (§22). Live auth/commands wait for Phase 3B-2 + PR #39. |
| 5 | Yönetici Cloud PWA (`pwa/src/yonetici`) | **Tested** (unit + code audit) | 28/28 Vitest passed on `main`. Confirmed Bulut/Yedek admin removed (§22). Payroll V6.0/V6.1 projection pending (`QA-09`). |
| 6 | Local Personel Browser App (`assets/staff.html`) | **Tested** (code + LAN API) | Employee selector hidden on individual login (`D-02`); unlinked sessions blocked (`D-01`); hidden-tab polling pause (`08f5812`); dark mode verified (`7455259`, `O-01`). |
| 7 | Local Yönetici Browser App (`assets/yonetici.html`) | **Tested** (code + LAN API) | Login always required; finance gated by HTTPS or explicit owner switch; payroll gated by `payroll.view`/`payroll.manage`; Gün Sonu Raporu verified free of employee working hours (`ad35d58`); dark mode verified (`7455259`). Ayarlar Q2 pending. |

---

## 3. Verified Functionality (Passes 1–3)

- **Windows-only Bulut & Yedek isolation (§22):** Verified across `local_accounts.dart`, `supabase/migrations/20261127005000_nohut_auth_control_plane.sql`, `20261127131000_nohut_app_commands.sql`, `pwa/src/`, and `flutter_personel/lib/`. `sync.*` and `backup.*` are refused (`windows_only`) for all remote clients including the owner.
- **Backup encryption & Windows DPAPI:** `backup_container.dart` uses Argon2id (64 MiB, 3 iter, refuses parameter downgrade) + AES-256-GCM with header bytes as AAD + 260-bit recovery key + staged restore with `PRAGMA integrity_check`. `windows_vault.dart` uses DPAPI (`CRYPTPROTECT_UI_FORBIDDEN`) with explicit buffer zeroing and atomic rename.
- **Restaurant operations, concurrency & duplicate prevention:** `PosStore.command` (`BEGIN IMMEDIATE` + `command_receipts` + `deleted_requests` + indexed `order_id`/`result_order_id`), `splitEqually` exact kuruş remainder, `refundPayment` cap & guest allocation guard, `cancelLocalOrder` payment guard, `recordCombinedPickupPayment` detached-copy atomicity, `InposPayments` no-double-charge & final `approved`/`declined`/`cancelled` state machine (`08f5812`), `MobilePairing` SHA-256/throttling/revocation.
- **Payroll & Gün Sonu Raporu (PR #44 `08f5812`):** Owner acceptance scenario (`8 h × 100 TL + 8 h × 120 TL = 1,760 TL` → `800 TL` → `Kısmen Ödendi` → `960 TL` → `Ödendi` → non-retroactive raise), idempotent `recordPayrollPayment`, departed employee unpaid dues retention, calendar date validation, Monday-only pay-type switching, and Gün Sonu Raporu strictly omitting employee working hours (`ad35d58`).
- **Dashboards & analytics:** Verified `order_reporting.dart` (Istanbul UTC+3), `platform_net.dart` (delivered non-demo only, `null` when deduction unconfigured), `overview_metrics.dart` (sales vs collections strictly separated).
- **Cloud auth, command queue & sync (PR #39 `e826e06`):** Verified `canonical_command_json`, identity binding, PII restriction, unlinked-account rejection (`actor not linked`), claim-time reauthorization, `FORCE ROW LEVEL SECURITY`, A1 `aal2` Windows agent enrollment, and atomic >500-event commit batching in `sync_worker.dart::groupPending`.

---

## 4. Findings Tracker

| ID | Severity | Priority | Target PR / SHA | Owner | Summary | GitHub Report / Verification | Status |
|---|---|---|---|---|---|---|---|
| **QA-01** | **High** | P0 (Financial / Idempotency) | PR #44 (`ab4b3ff` / `08f5812`) | Claude | `recordPayrollPayment` duplicate `requestId` double-counting & irreversible second row. | Reported [#7223333964](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223333964) · Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-02** | **High** | P0 (Financial / Payroll) | PR #44 (`ab4b3ff` / `08f5812`) | Claude | Deactivated employee with unpaid worked hours vanished from `payrollWeek` and payday reminders. | Reported [#7223333964](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223333964) · Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-03** | **High** | P0 (Security / Spec §24.1) | PR #44 (`ab4b3ff` / `4249b9e`) | Claude | Trusted-device 5-digit PIN across Windows/LAN (`local_accounts.dart`) and Supabase Cloud (`20261127210000_nohut_pin_five_digits.sql`); legacy 6-digit verifiers keep unlocking; all CI green (`synthetic-postgres` ×2). | Reported [#7223333964](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223333964) · Verified on `4249b9e` | **Verified Resolved (`4249b9e`)** |
| **QA-04** | **Medium** | P0 (Security / Auth) | PR #44 (`ab4b3ff` / `08f5812`) | Claude | `LocalAuth.unlockWithPassword` bypassed 5-failure 15-min lockout and pre-checks. | Reported [#7223333964](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223333964) · Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-05** | ~~Medium~~ | — | PR #44 (`ad35d58` / `08f5812`) | — | ~~`buildDailyReport` `staffHours`.~~ **Owner decision:** Gün Sonu Raporu must **NOT** include employee working hours. Verified absent from `daily_report.dart`, `daily_report_ui.dart`, `yonetici.html`. | Owner [#7223400650](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223400650) / [#7223423784](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/45#issuecomment-7223423784) · Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Superseded (Owner Decision — Verified Absent)** |
| **QA-06** | **Medium** | P0/P1 (Validation & LAN) | PR #44 (`ab4b3ff` / `08f5812`) | Claude | Invalid calendar dates (`2026-02-31`), mid-week `Haftalık Sabit` switch, missing `_privateIp` on LAN reads/writes, `/api/mobile/bootstrap` auth gate. | Reported [#7223333964](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223333964) · Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-07** | **Medium** | P0 (Financial / Schema) | PR #39 (`e826e06`) | Codex | `combined_payment_groups` (`20261127150000_nohut_payment_ledgers.sql:2-8`) lacks `CHECK` constraints enforcing `cash_kurus + card_kurus = amount_kurus` and method-to-component consistency. | [PR #39 #7223334066](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7223334066) | Pending fix (no new PR #39 commits) |
| **QA-08** | **Medium** | P0 (Financial / Terminal) | PR #39 (`e826e06`) | Codex | `apply_typed_projection` (`20261127151000_nohut_typed_ledger_apply.sql:138`) only marks `approved` terminal attempts immutable; `declined`/`cancelled` can still be mutated. | [PR #39 #7223334066](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7223334066) | Pending fix (no new PR #39 commits) |
| **QA-09** | **High** | P1 (Cross-Platform Parity) | PR #39 (`e826e06`) / PR #44 (`4249b9e`) | Codex | V6.0/V6.1 payroll & workforce entities (`payHistory`, `payrollPayments`, `payrollReviews`, `payrollEligible`, `shiftPlans`, `timesheetWeeks`) not yet in PR #39 typed projections (Matrix `O-03`). | [PR #39 #7223334066](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7223334066) | Planned / Coordinated |
| **QA-10** | **Medium** | P0 (Financial / Terminal) | PR #44 (`08f5812`) | Claude | `InposPayments._apply` overwrote definitive `declined`/`cancelled` outcomes back to `unknown` on offline `reconcile()`. | Reported [#7223539958](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223539958) · Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-11** | **Medium** | P1 (Attribution / Parity) | PR #44 (`08f5812`) | Claude | `submitStaffAction` omitted `staffId` on `pay` and `payMixed` payment rows. | Reported [#7223539958](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223539958) · Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-12** | **Medium** | P2 (Performance / Scalability) | PR #44 (`08f5812`) / PR #39 | Claude / Codex | **Windows/LAN verified resolved (`08f5812`):** `command_receipts` indexed on `order_id`/`result_order_id` (`deleteOrder` on 500 receipts dropped **47 ms → 24 ms**); `staff.html` pauses polling on hidden tab. **Still open (Codex):** `sync_outbox` partial index `WHERE acked_at IS NULL` (Matrix `O-10`). | Reported [#7223539958](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223539958) · Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Partially Resolved (Codex index open)** |
| **QA-13** | **Low/Med** | P1 (Concurrency / Print Queue) | `main` (`ed7ccce`) / PR #44 (`0b342b7`) | Claude | `ReceiptPrinter.pump` (`receipt_printer.dart:98,147`) ignores `store.replace().ok` after print I/O; on a revision race with a concurrent LAN/POS write, the job stays stuck in `'Gönderiliyor'` until restart (blocking `deleteOrder`). | [PR #44 #7224086253](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7224086253) | Pending fix |
| **QA-14** | **Low/Med** | P1 (Spec §24.3 Nav Parity) | PR #44 (`7455259`) | Claude | Android Personel still opens on `Masalar` (5 tabs: `Masalar · Ürünler · Sepet · Siparişler · Bağlantı`) instead of **Ana Sayfa** (`Ana Sayfa · Masalar · Siparişler · Online · Daha Fazla` per Spec §24.1/§24.3). | [PR #44 #7224563633](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7224563633) | Tracked (UI pass) |
| **QA-15** | **Low** | P1 (Visual Polish) | PR #44 (`7455259`) | Claude | Android `work_page.dart` Maaş tab `NohutMetricGrid` has 3 cards leaving an orphan half-row next to `Saatlik ücret`; adding `Çalışma süresi` (4th card) balances the 2×2 grid and clarifies mid-week rate totals (`O-02`). | [PR #44 #7224563633](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7224563633) | Tracked (UI polish) |

---

## 5. Tests Executed & Actual Results

| Suite | Target | Command | Result |
|---|---|---|---|
| Desktop baseline | `main` (`ed7ccce`) | `cd flutter_desktop && flutter test --reporter compact` | **391 passed, 3 skipped, 0 failed** |
| Android baseline | `main` (`ed7ccce`) | `cd flutter_personel && flutter test --reporter compact` | **15 passed, 0 failed** |
| PWA baseline | `main` (`ed7ccce`) | `cd pwa && npm ci && npm test` | **28 passed, 0 failed** |
| PR #44 Pass 3 core suites | PR #44 (`08f5812`) | `flutter test test/payroll_test.dart test/local_accounts_test.dart test/lan_auth_gate_test.dart test/daily_report_test.dart test/terminal_delete_guard_test.dart test/workforce_test.dart` | **59 passed, 0 failed** |
| PR #44 Pass 3 independent verification | PR #44 (`08f5812`) | Standalone Dart verification (`verify_pass3_pr44.dart`) | **8 passed, 0 failed** (`QA-01`, `QA-02`, `QA-03` local, `QA-04`, `QA-05` absent, `QA-06`, `QA-10`, `QA-11`, `QA-12` indexed `deleteOrder`: **24 ms**) |
| PR #44 Pass 3B–4 CI & module audit | PR #44 (`4249b9e` / `0b342b7`) | `gh pr checks 44` + direct audit of `20261127210000_nohut_pin_five_digits.sql`, `campaign_menu.dart`, `customer_accounts.dart`, `product_customization.dart`, `receipt_printer.dart`, `online_order_alarm.dart`, `trendyol_go_readonly.dart`, `0b342b7` (`O-11`) | **All 6 CI jobs green on `4249b9e`** |
| PR #44 Pass 5 Android full suite & visual audit | PR #44 (`7455259`) | `cd flutter_personel && flutter test` + `NOHUT_RENDER_DIR=... flutter test test/visual/screens_render_test.dart` | **34 passed, 0 failed** + **10 light/dark PNGs rendered & visually inspected** (no clipping/overflow, brand colors & typography verified) |
| PR #39 sync/ledger/agent suites | PR #39 (`e826e06`) | `flutter test test/remote_commands_test.dart test/payment_ledger_sync_test.dart test/windows_agent_setup_test.dart test/sync_worker_test.dart` | **37 passed, 1 skipped, 0 failed** |
| Synthetic P2 SQLite benchmark (before/after `QA-12`) | `main` (`ed7ccce`) vs PR #44 (`08f5812`) | 500 orders + 500 `command_receipts`, WAL + FULL | `deleteOrder`: **47 ms** (full scan) → **24 ms** (indexed $O(\log N)$) |
| Independent QA regression suite | `gemini/independent-qa` | `flutter test test/independent_qa_audit_test.dart` | **10 passed, 0 failed** |

---

## 6. Remaining Dependencies & Blockers

1. **Pending fixes from Codex (PR #39 — currently at `e826e06`; resumed by ChatGPT at 17:05Z):**
   - `QA-07`: `combined_payment_groups` component-sum & method `CHECK` constraints.
   - `QA-08`: `terminal_attempts` immutability for `declined`/`cancelled` outcomes.
   - `QA-09`: V6.0/V6.1 payroll & workforce typed projections (Matrix `O-03`) + `orders[].payments[].staffId` mapping.
   - `QA-12` (remaining half): `CREATE INDEX IF NOT EXISTS sync_outbox_pending ON sync_outbox(seq) WHERE acked_at IS NULL` (Matrix `O-10`).
2. **Pending items from Claude:**
   - `QA-13`: `ReceiptPrinter.pump` retry loop on `store.replace().ok` after print I/O.
   - **Premium UI/UX redesign** across native Android Personel/Yönetici, PWAs, and local browser apps (not yet implemented).
   - **Ayarlar Q2** information architecture & full settings audit/redesign (not yet implemented).
   - **Phase 3B-2** Login BFF + cloud auth on PWAs/Android (not yet implemented).
3. **Physical-Device Tests Required (Owner Gate — Not Performed by Agents):**
   - Physical iPhone Safari test of local `/personel` and `/yonetici` over trusted local HTTPS (`L4`).
   - Physical Android phone installation & testing of signed Personel and Yönetici APKs (biometrics, keyboard, back button, LAN/cloud reconnect, notifications).
   - Physical Windows second-PC encrypted backup restore verification (Phase 1).
   - Physical thermal receipt printer & InPOS card terminal verification.
   - KVKK legal review confirmation prior to enabling real production data sync to Supabase.
