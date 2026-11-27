# Nohut POS 2.0 — Independent QA, Security & Business-Logic Audit (`GEMINI_PROGRESS.md`)

**Agent:** Google Antigravity / Gemini (Independent Engineering, Security & QA)  
**Branch:** `gemini/independent-qa` (PR #45)  
**Last Updated:** 2026-11-27 (Pass 2 Complete)  
**Canonical QA Matrix:** `docs/qa/FUNCTIONAL_QA_MATRIX.md` (on PR #44)  
**Shared Coordination Board:** `docs/cloud-sync/PROGRESS.md`

---

## 1. Inspected Repository State & Commit SHAs

| Target | Branch / Ref | Commit SHA | Status |
|---|---|---|---|
| Production base | `main` | `ed7ccce` | Merged (`#42`, `#43`) |
| Claude active PR | `claude/project-thread-51u0i4` (PR #44) | `b20dd44e8d0b322e6a8697e47f8606bf32031665` | PR Open (Draft) |
| Codex active PR | `chatgpt/pr-05b-cloud-rpcs` (PR #39) | `e826e0626cf1eaac91aa09c3ff09c1cf0105446e` | PR Open (Draft) |
| Gemini QA branch | `gemini/independent-qa` (PR #45) | Active | PR Open (Draft) |

---

## 2. Audit Scope & Cross-Platform Coverage (7 Surfaces)

| # | Application Surface | Audit Status | Notes |
|---|---|---|---|
| 1 | Windows POS (`flutter_desktop`) | **Tested** (P0/P1/P2) | 391 baseline tests passed on `main`; 44 P0 tests + 5 repro tests on PR #44; 37 sync/ledger tests on PR #39; 10/10 independent regression tests + synthetic 500-order SQLite benchmark on `gemini/independent-qa`. DPAPI (`windows_vault.dart`) & Argon2id/AES-256-GCM backup (`backup_container.dart`) verified. |
| 2 | Native Android Personel APK (`flutter_personel`) | **Tested** (unit/widget + arch) | Genuine Flutter native app (zero WebView dependency; `flutter_secure_storage`, bundled fonts/logo, `ExpenseDraftStore` offline outbox). 15/15 passed on `main`; 16/16 passed on PR #44. Emulator/physical APK visual verification pending Premium UI/UX pass. |
| 3 | Native Android Yönetici APK (`flutter_personel` manager entry) | **Tested** (unit + arch) | Genuine Flutter native; owner identity no longer hardcoded to `"Ömer Yılmaz"` on PR #44 (`D-14`). `ExpenseDraftStore` encrypted LAN transport (`FinanceWire`) verified. V6.0/V6.1 payroll cloud projection pending (`QA-09` / Matrix `O-03`). |
| 4 | Personel Cloud PWA (`pwa/src/personel`) | **Tested** (unit + code audit) | 28/28 Vitest passed on `main`. Confirmed Bulut/Yedek admin removed (§22). Live auth/commands wait for Phase 3B-2 + PR #39. |
| 5 | Yönetici Cloud PWA (`pwa/src/yonetici`) | **Tested** (unit + code audit) | 28/28 Vitest passed on `main`. Confirmed Bulut/Yedek admin removed (§22). Payroll V6.0/V6.1 projection pending (`QA-09`). |
| 6 | Local Personel Browser App (`assets/staff.html`) | **Reviewed** (code + LAN API) | Employee selector hidden on individual login (`D-02`); unlinked sessions blocked (`D-01`). `setInterval(refresh, 5000)` lacks `document.hidden` guard (`QA-12`). Dark mode (`O-01`) & Premium UI redesign pending. |
| 7 | Local Yönetici Browser App (`assets/yonetici.html`) | **Reviewed** (code + LAN API) | Login always required; finance gated by HTTPS or explicit owner switch; payroll gated by `payroll.view`/`payroll.manage`; polling checks `!document.hidden` with `poll=1`. Premium UI redesign & Ayarlar Q2 pending. |

---

## 3. Verified Functionality (Passes 1 & 2)

- **Windows-only Bulut & Yedek isolation (§22):** Verified across `local_accounts.dart`, `supabase/migrations/20261127005000_nohut_auth_control_plane.sql`, `20261127131000_nohut_app_commands.sql`, `pwa/src/`, and `flutter_personel/lib/`. `sync.*` and `backup.*` are refused (`windows_only`) for all remote clients including the owner.
- **Backup encryption & Windows DPAPI:** `backup_container.dart` uses Argon2id (64 MiB, 3 iter, refuses parameter downgrade) + AES-256-GCM with header bytes as AAD + 260-bit recovery key + staged restore with `PRAGMA integrity_check`. `windows_vault.dart` uses DPAPI (`CRYPTPROTECT_UI_FORBIDDEN`) with explicit buffer zeroing and atomic rename.
- **Restaurant operations, concurrency & duplicate prevention:**
  - `PosStore.command`: SQLite `BEGIN IMMEDIATE` writer lock, persisted `command_receipts`, deduplicated retries, mutated-payload rejection, `deleted_requests` replay fence.
  - `operations.dart`: `splitEqually` exact remainder kuruş distribution (`100.01 TL / 3 = 33.34 + 33.34 + 33.33`), `refundPayment` capped at `paymentNetCents` with guest allocation guard, `cancelLocalOrder` refused while payments held, `recordMixedPayment` & `recordProductPayment` detached-copy atomicity.
  - `group_payments.dart`: `recordCombinedPickupPayment` single-account enforcement, detached-copy atomicity, duplicate `transactionId` refusal.
  - `card_terminal.dart`: `InposPayments` persists `dispatched` before device I/O; retries call `inquire` (never double-charging `pay`); unknown outcomes block `PosStore.deleteOrder`.
  - `mobile_pairing.dart`: SHA-256 hashed bearer tokens, constant-time compare, 5-attempt/5-min rate limit, single-use rotating PIN, device revocation.
- **Payroll owner acceptance scenario (PR #44):** Verified `8 h × 100 TL + 8 h × 120 TL = 1,760 TL` → `800 TL` paid → `Kısmen Ödendi` (`960 TL` remaining) → `960 TL` paid → `Ödendi` (`0 TL` remaining) → later wage change non-retroactive.
- **Dashboards & analytics:** Verified `order_reporting.dart` (Istanbul UTC+3, round-trip calendar validation), `platform_net.dart` (delivered non-demo only, `null` when deduction unconfigured — never fabricated zero), `overview_metrics.dart` (sales vs collections strictly separated).
- **Cloud auth, command queue & sync (PR #39):** Verified `canonical_command_json` exact integer kuruş enforcement, rejection of client-supplied identity fields, rejection of customer PII (only `customer.time`), rejection of unlinked accounts (`actor not linked`), claim-time reauthorization (`command_still_authorized`), `FORCE ROW LEVEL SECURITY` on all `nohut_private` tables, A1 `aal2` Windows agent enrollment, and `sync_worker.dart::groupPending` atomic handling of >500-event commits on PR #39.
- **No hardcoded real employee names or synthetic production statistics:** Verified clean across `flutter_desktop`, `flutter_personel` (PR #44), and `pwa`.

---

## 4. Findings Tracker

| ID | Severity | Priority | Target PR / SHA | Owner | Summary | GitHub Report | Status |
|---|---|---|---|---|---|---|---|
| **QA-01** | **High** | P0 (Financial / Idempotency) | PR #44 (`b20dd44`) | Claude | `recordPayrollPayment` (`payroll.dart:199-239`) has no duplicate `requestId` guard; direct retry double-counts `paidCents` and leaves the second row irreversible via `reversePayrollPayment`. | [PR #44 #7223333964](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223333964) | Pending fix |
| **QA-02** | **High** | P0 (Financial / Payroll) | PR #44 (`b20dd44`) | Claude | Deactivated employee (`active: false`) with unpaid worked hours (`remainingCents > 0`, 0 payments) silently vanishes from `payrollWeek` (`payroll.dart:306-308`) and payday reminders (`payroll_reminders.dart:66`). | [PR #44 #7223333964](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223333964) | Pending fix |
| **QA-03** | **High** | P0 (Security / Spec §24.1) | PR #44 (`b20dd44`) & `main` (`ed7ccce`) | Claude | Trusted-device PIN enforces 6 digits (`^[0-9]{6}$`) in `local_accounts.dart:222` and `20261127005000_nohut_auth_control_plane.sql:338,361`, rejecting valid 5-digit PINs required by Spec §24.1. | [PR #44 #7223333964](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223333964) | Pending fix |
| **QA-04** | **Medium** | P0 (Security / Auth) | PR #44 (`b20dd44`) & `main` (`ed7ccce`) | Claude | `LocalAuth.unlockWithPassword` (`local_accounts.dart:530-539`) bypasses 5-failure 15-minute `locked_until` account lockout and mutates `last_seen_at` before active/device/client validation. | [PR #44 #7223333964](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223333964) | Pending fix |
| **QA-05** | ~~Medium~~ | — | PR #44 (`b20dd44`) | — | ~~`buildDailyReport` returns `'staffHours': null`.~~ **Owner decision (2026-11-27):** Gün Sonu Raporu must **NOT** calculate or display employee working hours; hours belong to weekly Mesai and Haftalık Maaş Ödemeleri only. | [Owner correction #7223400650](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223400650) / [PR #45 #7223423784](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/45#issuecomment-7223423784) | **Superseded (Owner Decision)** |
| **QA-06** | **Medium** | P0/P1 (Validation & LAN Defense-in-Depth) | PR #44 (`b20dd44`) | Claude | Invalid calendar dates (e.g. `2026-02-31`) accepted by regex-only checks in `payroll.dart` & `daily_report.dart`; mid-week `Haftalık Sabit` rate edge case in `weeklyEarnings`; missing `_privateIp` check on `/api/staff/*`, `/api/state`, `/api/bootstrap`, `/api/mobile/bootstrap`; `/api/mobile/bootstrap` does not enforce `_guard` under `Bireysel giriş zorunlu`. | [PR #44 #7223333964](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223333964) | Pending fix |
| **QA-07** | **Medium** | P0 (Financial / Schema) | PR #39 (`e826e06`) | Codex | `combined_payment_groups` (`20261127150000_nohut_payment_ledgers.sql:2-8`) lacks `CHECK` constraints enforcing `cash_kurus + card_kurus = amount_kurus` and method-to-component consistency. | [PR #39 #7223334066](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7223334066) | Pending fix |
| **QA-08** | **Medium** | P0 (Financial / Terminal) | PR #39 (`e826e06`) | Codex | `apply_typed_projection` (`20261127151000_nohut_typed_ledger_apply.sql:138`) only marks `approved` terminal attempts immutable; `declined` and `cancelled` outcomes can be mutated on a higher revision. | [PR #39 #7223334066](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7223334066) | Pending fix |
| **QA-09** | **High** | P1 (Cross-Platform Parity) | PR #39 (`e826e06`) / PR #44 (`b20dd44`) | Codex | V6.0/V6.1 payroll & workforce entities (`payHistory`, `payrollPayments`, `payrollReviews`, `payrollEligible`, `shiftPlans`, `timesheetWeeks`) not yet in PR #39 typed projections (aligned with Matrix `O-03`). | [PR #39 #7223334066](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7223334066) | Planned / Coordinated |
| **QA-10** | **Medium** | P0 (Financial / Terminal) | `main` (`ed7ccce`) / PR #44 (`b20dd44`) | Claude | `InposPayments._apply` (`card_terminal.dart:108-150`) only short-circuits on `'approved'`; offline `reconcile()` on a `'declined'`/`'cancelled'` attempt overwrites it to `'unknown'`, blocking future card payments and `deleteOrder`. | [PR #44 #7223539958](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223539958) | Pending fix |
| **QA-11** | **Medium** | P1 (Attribution / Parity) | `main` (`ed7ccce`) / PR #44 (`b20dd44`) | Claude | `submitStaffAction` (`staff_commands.dart:324-365`) stamps `staffId` on `payProducts` but omits `staffId` on `pay` and `payMixed` payment rows. | [PR #44 #7223539958](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223539958) | Pending fix |
| **QA-12** | **Medium** | P2 (Performance / Scalability) | `main` (`ed7ccce`) / PR #44 (`b20dd44`) | Claude | `PosStore.deleteOrder` (`pos_store.dart:553-561`) performs a full `command_receipts` scan + `jsonDecode` inside `BEGIN IMMEDIATE` (47 ms at 500 receipts; scales $O(N)$); `sync_outbox` lacks partial index `WHERE acked_at IS NULL`; `staff.html:591` polls every 5 s without `document.hidden` check. | [PR #44 #7223539958](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223539958) | Pending fix |

---

## 5. Tests Executed & Actual Results

| Suite | Target | Command | Result |
|---|---|---|---|
| Desktop baseline | `main` (`ed7ccce`) | `cd flutter_desktop && flutter test --reporter compact` | **391 passed, 3 skipped, 0 failed** |
| Android baseline | `main` (`ed7ccce`) | `cd flutter_personel && flutter test --reporter compact` | **15 passed, 0 failed** |
| PWA baseline | `main` (`ed7ccce`) | `cd pwa && npm ci && npm test` | **28 passed, 0 failed** |
| PR #44 P0 desktop suites | PR #44 (`b20dd44`) | `flutter test test/payroll_test.dart test/lan_auth_gate_test.dart test/workforce_test.dart test/yonetici_api_test.dart test/owner_identity_test.dart test/daily_report_test.dart` | **44 passed, 0 failed** |
| PR #44 Android suite | PR #44 (`b20dd44`) | `cd flutter_personel && flutter test --reporter compact` | **16 passed, 0 failed** |
| PR #44 Pass 1 repro suite | PR #44 (`b20dd44`) | Standalone Dart repro (`verify_pr44_findings.dart`) | **5/5 reproduced** (`QA-01`–`QA-04`, superseded `QA-05`) |
| Pass 2 repro suite | `main` (`ed7ccce`) | Standalone Dart repro (`verify_pass2_findings.dart`) | **2/2 reproduced** (`QA-10`, `QA-11`) |
| PR #39 sync/ledger/agent suites | PR #39 (`e826e06`) | `flutter test test/remote_commands_test.dart test/payment_ledger_sync_test.dart test/windows_agent_setup_test.dart test/sync_worker_test.dart` | **37 passed, 1 skipped, 0 failed** |
| Synthetic P2 SQLite benchmark | `main` (`ed7ccce`) | Standalone Dart benchmark (`perf_benchmark_test.dart`, 500 orders + 500 receipts, WAL + FULL) | **Passed** (`open`: 121 ms, 500 orders: 10,041 ms / 20.08 ms/order, cached read: 6 ms, `daySales` + `liveOperations`: 12 ms, `deleteOrder`: 47 ms, DB: 944 KB) |
| Independent QA regression suite | `gemini/independent-qa` | `flutter test test/independent_qa_audit_test.dart` | **10 passed, 0 failed** |

---

## 6. Key Files Reviewed

- **Docs & Specs:** `docs/cloud-sync/PROGRESS.md`, `docs/cloud-sync/NOHUT_POS_2.0_MASTER_SPEC_v5.1.md` (§22–§24), `docs/qa/FUNCTIONAL_QA_MATRIX.md`
- **Windows / LAN / Operations (`main` & PR #44):** `payroll.dart`, `payroll_reminders.dart`, `workforce.dart`, `workforce_api.dart`, `lan_auth_gate.dart`, `lan_server.dart`, `local_accounts.dart`, `yonetici_api.dart`, `finance_sync_server.dart`, `finance_logic.dart`, `daily_report.dart`, `staff_commands.dart`, `operations.dart`, `group_payments.dart`, `card_terminal.dart`, `pos_store.dart`, `entity_storage.dart`, `sync_outbox.dart`, `sync_worker.dart`, `remote_commands.dart`, `order_reporting.dart`, `platform_net.dart`, `overview_metrics.dart`, `mobile_pairing.dart`, `backup_container.dart`, `windows_vault.dart`, `simple_settings.dart`, `assets/staff.html`, `assets/yonetici.html`
- **Native Android (`flutter_personel`):** `pubspec.yaml`, `pos_api.dart`, `owner_api.dart`, `expense_drafts.dart`, `manager_main.dart`, `manager_finance.dart`
- **Cloud / Supabase (PR #39 & `main`):** `20261127005000_nohut_auth_control_plane.sql`, `20261127121000_nohut_command_queue.sql`, `20261127124000_nohut_authorized_enqueue.sql`, `20261127125000_nohut_authorized_claim.sql`, `20261127129000_nohut_agent_transport.sql`, `20261127131000_nohut_app_commands.sql`, `20261127145000_nohut_windows_agent_setup.sql`, `20261127150000_nohut_payment_ledgers.sql`, `20261127151000_nohut_typed_ledger_apply.sql`, `sync_worker.dart`

---

## 7. Remaining Blockers & Queued Independent Audit Passes

1. **Awaiting agent fixes (Blocked on PR updates):**
   - Claude (PR #44): `QA-01`, `QA-02`, `QA-03`, `QA-04`, `QA-06`, `QA-10`, `QA-11`, `QA-12`.
   - Codex (PR #39): `QA-07`, `QA-08`, `QA-09`.
   - Every fix will be independently re-tested against the exact new commit SHA before marking resolved.
2. **Awaiting unimplemented features (Blocked on development):**
   - **Premium UI/UX redesign** across native Android Personel/Yönetici, PWAs, and local browser apps (owned by Claude; not yet implemented).
   - **Ayarlar Q2** information architecture & full settings audit/redesign (claimed by Claude; not yet implemented).
   - **Phase 3B-2** Login BFF + cloud auth on PWAs/Android (owned by Claude; not yet implemented).
   - **Phase 6** cloud sales/heatmap/top-products projections (open/pending).

## 8. Physical-Device Tests Required (Owner Gate — Not Performed by Agents)

- Physical iPhone Safari test of local `/personel` and `/yonetici` over trusted local HTTPS (`L4`).
- Physical Android phone installation & testing of signed Personel and Yönetici APKs (biometrics, keyboard, back button, LAN/cloud reconnect, notifications).
- Physical Windows second-PC encrypted backup restore verification (Phase 1).
- Physical thermal receipt printer & InPOS card terminal verification.
- KVKK legal review confirmation prior to enabling real production data sync to Supabase.
