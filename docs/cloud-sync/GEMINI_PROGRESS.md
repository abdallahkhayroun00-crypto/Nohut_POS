# Nohut POS 2.0 — Independent QA, Security & Business-Logic Audit (`GEMINI_PROGRESS.md`)

**Agent:** Google Antigravity / Gemini (Independent Engineering, Security & QA)  
**Branch:** `gemini/independent-qa` (PR #45)  
**Last Updated:** 2026-11-27 (Pass 7 Complete — PR #39 `8d918b2` & PR #44 `a0fbfc9` Independent Verification; Codex usage-limited)  
**Canonical QA Matrix:** `docs/qa/FUNCTIONAL_QA_MATRIX.md` (on PR #44)  
**Shared Coordination Board:** `docs/cloud-sync/PROGRESS.md`

---

## 1. Inspected Repository State & Commit SHAs

| Target | Branch / Ref | Commit SHA | Status |
|---|---|---|---|
| Production base | `main` | `ed7ccce` | Merged (`#42`, `#43`) |
| Claude active PR | `claude/project-thread-51u0i4` (PR #44) | `a0fbfc9` (includes `c3d0874`, `3323bb8`, `f14ac9a`, `7f1e485`, `9e4676c`, `9f8159b`, `86c2a2a`, `7e27ddd`, `a0fbfc9`) | PR Open (Draft) |
| Codex active PR | `chatgpt/pr-05b-cloud-rpcs` (PR #39) | `8d918b2` (includes `da3592a`, `7f2dea6`, `bacae0a`, `8d918b2`; Codex temporarily usage-limited) | PR Open (Draft) — 12/12 CI green |
| Gemini QA branch | `gemini/independent-qa` (PR #45) | Active | PR Open (Draft) |

---

## 2. Audit Scope & Cross-Platform Coverage (7 Surfaces)

| # | Application Surface | Audit Status | Notes |
|---|---|---|---|
| 1 | Windows POS (`flutter_desktop`) | **Tested** (P0/P1/P2) | 391 baseline tests on `main`; 59/59 core + 8/8 independent verification tests on `08f5812`; 57/57 Pass 7 tests on PR #44 `a0fbfc9` (`local_accounts`, `lan_auth_gate`, `workforce`, `payroll`, `shifts`); 18+5 Pass 6–7 sync/ledger/workforce tests on PR #39 `8d918b2`; 10/10 independent regression tests on `gemini/independent-qa`. `deleteOrder` improved **47 ms → 24 ms**. DPAPI & Argon2id/AES-256-GCM backup verified. |
| 2 | Native Android Personel APK (`flutter_personel`) | **Tested & Visually Audited** | Genuine Flutter native app (zero WebView; `flutter_secure_storage`, bundled logo/fonts, `WorkRequestIds` idempotent retry). **49/49 tests passed** on `a0fbfc9`. Widget-rendered `staff-home-signed-in-light.png` visually confirms **`QA-14` resolved** (`Ana Sayfa` landing + 5-tab bottom bar). CI API 34 emulator run `46047769476` on `0e36b63` verified `success` (`D-33`, emulator only — physical device unverified). |
| 3 | Native Android Yönetici APK (`flutter_personel` manager entry) | **Tested & Visually Audited** | Genuine Flutter native; owner identity not hardcoded (`D-14`); `ExpenseDraftStore` encrypted LAN transport verified; **native Haftalık Maaş Ödemeleri** (`QA-16` verified resolved in `c3d0874`); **Ana Sayfa**, **Personel**, and **Ayarlar Q2** (`9e4676c`, `9f8159b`, `86c2a2a`) visually verified via widget renders (`owner-dashboard-light`, `owner-staff-light`, `owner-settings-dark`). |
| 4 | Personel Cloud PWA (`pwa/src/personel`) | **Tested** (unit + code audit) | 28/28 Vitest passed on `main`. Confirmed Bulut/Yedek admin removed (§22). Live auth/commands wait for Phase 3B-2 + PR #39 authorized read RPCs. |
| 5 | Yönetici Cloud PWA (`pwa/src/yonetici`) | **Tested** (unit + code audit) | 28/28 Vitest passed on `main`. Confirmed Bulut/Yedek admin removed (§22). Authorized cloud payroll read RPCs pending (`QA-09`/`O-03`, blocked while Codex is usage-limited). |
| 6 | Local Personel Browser App (`assets/staff.html`) | **Tested** (code + LAN API) | Employee selector hidden on individual login (`D-02`); unlinked sessions blocked (`D-01`); hidden-tab polling pause (`08f5812`); dark mode verified (`7455259`, `O-01`); browser PIN Değiştir audited (`a0fbfc9`, notes `QA-17`). |
| 7 | Local Yönetici Browser App (`assets/yonetici.html`) | **Tested** (code + LAN API) | Login always required; finance gated by HTTPS or explicit owner switch; payroll gated by `payroll.view`/`payroll.manage`; Gün Sonu Raporu verified free of employee working hours (`ad35d58`); dark mode verified (`7455259`); browser PIN Değiştir audited (`a0fbfc9`, notes `QA-17`). |

---

## 3. Verified Functionality (Passes 1–7)

- **Windows-only Bulut & Yedek isolation (§22):** Verified across `local_accounts.dart`, `supabase/migrations/20261127005000_nohut_auth_control_plane.sql`, `20261127131000_nohut_app_commands.sql`, `pwa/src/`, `flutter_personel/lib/manager_main.dart` (`86c2a2a`), and `docs/qa/SETTINGS_INVENTORY.md`. `sync.*` and `backup.*` are refused (`windows_only`) for all remote clients including the owner.
- **Backup encryption & Windows DPAPI:** `backup_container.dart` uses Argon2id (64 MiB, 3 iter, refuses parameter downgrade) + AES-256-GCM with header bytes as AAD + 260-bit recovery key + staged restore with `PRAGMA integrity_check`. `windows_vault.dart` uses DPAPI (`CRYPTPROTECT_UI_FORBIDDEN`) with explicit buffer zeroing and atomic rename.
- **Restaurant operations, concurrency & duplicate prevention:** `PosStore.command` (`BEGIN IMMEDIATE` + `command_receipts` + `deleted_requests` + indexed `order_id`/`result_order_id`), `splitEqually` exact kuruş remainder, `refundPayment` cap & guest allocation guard, `cancelLocalOrder` payment guard, `recordCombinedPickupPayment` detached-copy atomicity, `InposPayments` no-double-charge & final `approved`/`declined`/`cancelled` state machine (`08f5812`), `ReceiptPrinter._commitAfterPrint` revision-race retry (`d22e706`), `MobilePairing` SHA-256/throttling/revocation.
- **Payroll, Workforce & Gün Sonu Raporu (PR #44 `a0fbfc9`):** Owner acceptance scenario (`8 h × 100 TL + 8 h × 120 TL = 1,760 TL` → `800 TL` → `Kısmen Ödendi` → `960 TL` → `Ödendi` → non-retroactive raise), idempotent `recordPayrollPayment`, departed employee unpaid dues retention, calendar date validation, Monday-only pay-type switching, `correctShift` `breakMinutes` + `updatedAt` version bump (`97bf0c2`, `3323bb8`), configured `paydayOffset` (`3323bb8`), native Android Yönetici `OwnerPayrollPage` (`735d8e9`, `c3d0874`), and Gün Sonu Raporu strictly omitting employee working hours (`ad35d58`).
- **Dashboards & analytics:** Verified `order_reporting.dart` (Istanbul UTC+3), `platform_net.dart` (delivered non-demo only, `null` when deduction unconfigured), `overview_metrics.dart` (sales vs collections strictly separated), and `ownerOverview.team` filtering voided/open shifts via `wf.workMinutes` (`9e4676c`).
- **Cloud auth, command queue & typed projections (PR #39 `8d918b2`):** Verified `canonical_command_json`, identity binding, PII restriction, unlinked-account rejection (`actor not linked`), claim-time reauthorization, `FORCE ROW LEVEL SECURITY`, A1 `aal2` Windows agent enrollment, atomic >500-event commit batching, `sync_outbox_pending` partial index (`abbcf31`), `combined_payment_groups` component constraints (`abbcf31`), definitive terminal outcome immutability (`abbcf31`), all **5 typed workforce/payroll write projections** (`employee_wage_history` `b2dcd16`, `payroll_payments`/`payroll_reviews` `8b78745`, manual Mesai `20c1fa7`, immutable `timesheet_weeks`/`submissions`/`entries` `da3592a`, `shift_plans`/`history` `7f2dea6`), and E2E session-bound payment collector attribution (`8d918b2`).

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
| **QA-09** | **High** | P1 (Cross-Platform Parity) | PR #39 (`8d918b2`) | Codex | **All 5 typed write projections + payment collector attribution verified clean (`b2dcd16`, `8b78745`, `20c1fa7`, `da3592a`, `7f2dea6`, `8d918b2`).** **Still OPEN (`O-03`):** authorized weekly payroll/workforce read RPCs & cloud client wiring (blocked while Codex is usage-limited). | Verified [#7225414738](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7225414738) & [#7226886518](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7226886518) | **In Progress — Blocked on Codex usage limit (reads pending)** |
| **QA-10** | **Medium** | P0 (Financial / Terminal) | PR #44 (`08f5812`) | Claude | `InposPayments._apply` overwrote definitive `declined`/`cancelled` outcomes back to `unknown` on offline `reconcile()`. | Reported [#7223539958](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223539958) · Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-11** | **Medium** | P1 (Attribution / Parity) | PR #44 (`08f5812`) | Claude | `submitStaffAction` omitted `staffId` on `pay` and `payMixed` payment rows. | Reported [#7223539958](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223539958) · Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) | **Verified Resolved (`08f5812`)** |
| **QA-12** | **Medium** | P2 (Performance / Scalability) | PR #44 (`08f5812`) & PR #39 (`abbcf31`) | Claude / Codex | **Fully resolved across both PRs:** `command_receipts` indexed on `order_id`/`result_order_id` (`deleteOrder`: **47 ms → 24 ms**), `staff.html` hidden-tab polling pause (`08f5812`), and `sync_outbox_pending ON sync_outbox(seq) WHERE acked_at IS NULL` (`abbcf31`, Matrix `O-10`). | Verified [#7223725943](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7223725943) & [#7225414738](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/39#issuecomment-7225414738) | **Verified Resolved (`08f5812` + `abbcf31`)** |
| **QA-13** | **Low/Med** | P1 (Concurrency / Print Queue) | PR #44 (`d22e706`) | Claude | `ReceiptPrinter._commitAfterPrint` retries up to 5 times on `store.replace().ok` for both Trendyol kitchen tickets and local print jobs, preventing stuck `'Gönderiliyor'` jobs. | Reported [#7224086253](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7224086253) · Verified [#7225442203](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7225442203) | **Verified Resolved (`d22e706`)** |
| **QA-14** | **Low/Med** | P1 (Spec §24.3 Nav Parity) | PR #44 (`7f1e485`) | Claude | Android Personel now opens on **Ana Sayfa** (`PersonelDashboard`) with 5-tab bottom bar (`Ana Sayfa · Masalar · Sipariş · Siparişler · Daha Fazla`). Visually verified on widget render `staff-home-signed-in-light.png`. | Reported [#7224563633](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7224563633) · Verified [#7226896798](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7226896798) | **Verified Resolved (`7f1e485`)** |
| **QA-15** | **Low** | P1 (Visual Polish) | PR #44 (`d22e706`) | Claude | Android `work_page.dart` Maaş tab adds 4th card `Çalışma süresi`, balancing the 2×2 `NohutMetricGrid` (visually verified on `work-2-light.png`). | Reported [#7224563633](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7224563633) · Verified [#7225442203](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7225442203) | **Verified Resolved (`d22e706`)** |
| **QA-16** | **Low** | P2 (UI Field Mismatch) | PR #44 (`c3d0874`) | Claude | `flutter_personel/lib/owner_payroll.dart:177` updated to check `p['reverses'] != null \|\| p['kind'] == 'Düzeltme'` for `Icons.undo`, covered by `owner_payroll_test.dart`. | Reported [#7225442203](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7225442203) · Verified [#7226896798](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7226896798) | **Verified Resolved (`c3d0874`)** |
| **QA-17** | **Low/Med** | P0 (Security / Auth Defense-in-Depth) | PR #44 (`a0fbfc9`) | Claude | `LocalAuth.setPin` (`local_accounts.dart`) only requires password on `!fresh` sessions if `pin_hash != null`; a >5-min-old unattended session that skipped PIN at login can have a PIN installed without password. Should require password whenever `!fresh`. | [PR #44 #7226896798](https://github.com/abdallahkhayroun00-crypto/Nohut_POS/pull/44#issuecomment-7226896798) | Open (Pending fix) |

---

## 5. Tests Executed & Actual Results

| Suite | Target | Command | Result |
|---|---|---|---|
| Desktop baseline | `main` (`ed7ccce`) | `cd flutter_desktop && flutter test --reporter compact` | **391 passed, 3 skipped, 0 failed** |
| Android baseline | `main` (`ed7ccce`) | `cd flutter_personel && flutter test --reporter compact` | **15 passed, 0 failed** |
| PWA baseline | `main` (`ed7ccce`) | `cd pwa && npm ci && npm test` | **28 passed, 0 failed** |
| PR #44 Pass 3–6 suites | PR #44 (`08f5812` / `0e36b63`) | Core + independent + desktop targeted suites | **59 + 8 + 34 passed, 0 failed** |
| PR #44 Pass 7 Android full suite & widget renders | PR #44 (`a0fbfc9`) | `cd flutter_personel && NOHUT_RENDER_DIR=... flutter test` | **49 passed, 0 failed** + **18 light/dark widget-rendered PNGs** (`staff-home-signed-in-light`, `owner-dashboard-light`, `owner-staff-light`, `owner-settings-dark` visually verified; distinct from emulator) |
| PR #44 Pass 7 desktop targeted suites | PR #44 (`a0fbfc9`) | `flutter test test/local_accounts_test.dart test/lan_auth_gate_test.dart test/workforce_test.dart test/payroll_test.dart test/shifts_test.dart` | **57 passed, 0 failed** |
| PR #44 CI Android emulator evidence (`D-33`) | PR #44 (`0e36b63`) | `gh run view 46047769476` (GitHub Actions API 34 emulator) | **`conclusion: success`** (emulator only; physical device unverified) |
| PR #39 Pass 6–7 sync/ledger/workforce suites | PR #39 (`20c1fa7` / `8d918b2`) | `sync_outbox_hardening`, `employee_wage_sync`, `payroll_ledger_sync`, `manual_attendance_sync`, `timesheet_sync`, `planned_shift_sync`, `payment_ledger_sync`, `cloud_finance_serializer` | **18 + 5 passed, 0 failed** + **12/12 CI jobs green on `8d918b2`** |
| Synthetic P2 SQLite benchmark (before/after `QA-12`) | `main` (`ed7ccce`) vs PR #44 (`08f5812`) | 500 orders + 500 `command_receipts`, WAL + FULL | `deleteOrder`: **47 ms** (full scan) → **24 ms** (indexed $O(\log N)$) |
| Independent QA regression suite | `gemini/independent-qa` | `flutter test test/independent_qa_audit_test.dart` | **10 passed, 0 failed** |

---

## 6. Remaining Dependencies & Blockers

1. **Blocked on Codex (temporarily usage-limited — PR #39 at `8d918b2`):**
   - `QA-09` / `O-03` remaining slices: authorized weekly payroll/workforce read RPCs (Windows-generated per-employee/week summary with stale labeling, owner exclusion & employee privacy) and cloud client wiring.
2. **Remaining work on Claude (PR #44 — currently at `a0fbfc9`):**
   - `QA-17`: Require password in `LocalAuth.setPin` whenever `!fresh` (even if `pin_hash` was `null`).
   - **Ayarlar Q2** remaining audit & redesign steps (Windows Q2 step 1–2, Android Yönetici Q2, and browser PIN Değiştir done).
   - **Phase 3B-2** Login BFF + cloud auth on PWAs/Android.
3. **Physical-Device & Production Gates (Owner Gate — Not Performed by Agents):**
   - Physical iPhone Safari test of local `/personel` and `/yonetici` over trusted local HTTPS (`L4`).
   - Physical Android phone installation & testing of signed Personel and Yönetici APKs (biometrics, keyboard, back button, LAN/cloud reconnect, notifications).
   - Physical Windows second-PC encrypted backup restore verification (Phase 1).
   - Physical thermal receipt printer & InPOS card terminal verification.
   - KVKK legal review confirmation prior to enabling real production data sync to Supabase.
