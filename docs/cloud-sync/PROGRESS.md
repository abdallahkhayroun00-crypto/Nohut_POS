# Nohut POS 2.0 — Shared Progress & Coordination

The **single shared status board** for every agent (Claude Code, ChatGPT automation) and the owner. Update it in the same PR as the work it describes.

Repository: `abdallahkhayroun00-crypto/Nohut_POS` (renamed from `brand-management-proposal`; same repository ID).

## Rules (all agents)

1. **Fetch first.** Before each iteration, read `main`, the open PRs and their latest CI, and this file.
2. **One branch per agent; never push to another agent's branch.**
   - Claude Code: `claude/inspiring-mccarthy-t5ywuv`, `claude/project-thread-51u0i4` (spec §23 consolidation + review work).
   - ChatGPT: `chatgpt/<topic>`.
3. **Claim before you start.** Add your name and the date to an item in "Claims". Do not start an item that another agent has claimed and is still working on. If a claim is older than 24 h with no PR, note that in the PR and take it over.
4. **Reuse; don't duplicate.** If an open PR already implements something, review it and build on it. Do not open a competing implementation.
5. **Merge gate (owner authorization 2026-11-26):**
   - all required CI green;
   - existing functionality and history preserved;
   - backup, restore and migration safety verified;
   - no production data uploaded or deleted;
   - no paid service activated.
6. **Never print secrets.** No real restaurant data in tests. No Nohut AI.

## Cumulative owner requirements (2026-11-27) — spec §23, binding for every agent

All owner messages are **cumulative requirements**, not competing tasks. Requirement text: Master Spec **§23**. Do not drop any of them after a usage-limit reset.

**Priority:** 1 unified auth + Windows account management → 2 local Personel + `/yonetici` browser apps → 3 unified notifications → 4 Trendyol review sync + dynamic store identity → 5 remaining Phase 6/7.

**Connectivity decision (owner, verified on a physical iPhone):** Windows POS authoritative · Android native = cloud + LAN · iPhone in the restaurant = local browser apps served by Windows, no VPN · iPhone outside = existing Cloudflare PWAs (via VPN; `pages.dev` blocked in Türkiye). Keep Cloudflare + Supabase. No hosting change, no domain purchase.

**Ownership:** PR #39 / `chatgpt/pr-05b-cloud-rpcs` belongs to **ChatGPT Codex** — nobody else pushes there. Claude owns auth, local browser UI, notifications, reviews and Windows analytics; Codex consumes those contracts and does not duplicate them.

### Agent-to-agent protocol (GitHub, mandatory)

Before every iteration: read this file, open PR comments and issues, pending requests, recent commits, CI and shared contracts. Use PR comments for technical talk, this file as the durable board. Answer pending requests in your next run; report completed dependencies with commit SHA, PR link, API contract, test evidence and limitations. Never post credentials, tokens, passwords or private restaurant data.

```
FROM: Claude | ChatGPT Codex
TO: Claude | ChatGPT Codex
STATUS: REQUEST | RESPONSE | BLOCKER | COMPLETED
TASK:
DEPENDENCY:
EXPECTED INTERFACE:
ACCEPTANCE CRITERIA:
RELATED PR:
EVIDENCE:
```

### Task board (§23)

| # | Task | Owner | Status | Depends on | PR / evidence |
|---|---|---|---|---|---|
| A1 | Windows owner session + MFA contract for Windows agent enrollment (`client=windows`, `sync.*` allowed only there) — open request from Codex on #39 | Claude | ✅ SQL contract (#42): migration `20261127200000_nohut_windows_owner_session.sql`, `public.nohut_windows_owner_session(device)`, tests `windows_owner_session_test.sql` (superuser + plain owner; also green on top of #39 locally). **Installation approval** (`20261127201000`): Windows binding only via a single-use ticket — bootstrap from the service role while no Windows installation exists, then approvals from an existing approved Windows aal2 session; `nohut_register_device('windows')` now refuses (`windows_enrollment_requires_approval`); use `nohut_register_windows_device(device, label, ticket)`. Test `windows_installation_approval_test.sql`. Windows login UI = A2/A3 | #40/#41 | #39 comment 2026-11-27 12:18Z |
| A2 | Login BFF (3B-2), PWA + Android login, trusted devices, 5-digit PIN (cloud rule: migration 20261127210000), 30-min configurable lock, biometrics where secure, owner TOTP | Claude | ⏳ | A1 | — |
| A3 | Windows Kullanıcılar & Yetkiler, Bağlı Cihazlar, password/PIN reset, deactivation, session revocation (3C) | Claude | ✅ local (Ayarlar › Güvenlik; `lib/local_accounts.dart`, `lib/accounts_ui.dart`). Cloud sync of accounts waits for A2 | — | branch `claude/project-thread-51u0i4`, tests `local_accounts_test`, `accounts_ui_test` |
| A4 | Bounded offline local sessions for LAN apps (no plaintext passwords, no cloud refresh tokens over HTTP) | Claude | ✅ PBKDF2 passwords/PINs, 30-day hashed tokens in HttpOnly SameSite=Strict cookie, idle lock (owner-set, default 30 min), PIN unlock, owner TOTP | — | `local_accounts_test`, `lan_auth_gate_test` |
| L1 | Authenticate + authorize every legacy LAN endpoint (`/api/state`, `/api/bootstrap`, `/api/staff/*`, finance routes) | Claude | 🔄 `/api/state`, `/api/bootstrap`, `/api/staff/*` gated per operation and acting employee stamped from the session (`lib/lan_auth_gate.dart`); enforced once the owner turns on **Bireysel giriş zorunlu** (off by default so current phones keep working). Finance routes already need pairing | A4 | `lan_auth_gate_test`; owner action: create staff accounts, then turn the switch on |
| L2 | Upgrade local Personel (`assets/staff.html`): keep floor plan + functions, add §22.2 features, reuse PWA components | Claude | ⏳ | L1 | — |
| L3 | Local Yönetici at `/yonetici` reusing `finance_sync_server.dart` | Claude | 🔄 first version: Özet, Siparişler, Personel, Finans (month view, other expenses, PDF report), Menü; always requires login; per-operation checks; payroll hidden without `payroll.view`. Money/finance refused unless HTTPS or owner turns on **Yönetici uygulamasında finans verileri** (default off, §23.4.7). Also: mark weekly payroll paid (`payroll.manage`), fixed monthly costs list + paid/unpaid (`finance.edit`) with version checks. Remaining: payroll hours/bonus editing, material purchases, Google/review panels | L1 | `lib/yonetici_api.dart`, `assets/yonetici.html`, `yonetici_api_test`; owner action: physical iPhone check (L4) |
| L4 | Bundle assets in the installer; trusted local HTTPS; Safari check on a physical iPhone (owner device test) | Claude | ⏳ | L2, L3 | — |
| N1 | Notification event contract `docs/contracts/v1/notifications.json` | Claude | ✅ 15 categories (severity, recipient permission, clients, Windows-only), lock-screen = title only; Dart mirror `lib/notification_events.dart` | — | `notification_events_test` (mirror check) |
| N2 | Windows notification center (reuse sound, `online_order_alarm.dart`, `staffNotices`) | Claude | ✅ history derived from committed state (phone orders, Trendyol packages, print failures, unknown terminal outcomes, reviews) with stable ids; stale events stored as read; Ayarlar › Bildirimler › Bildirim geçmişi. Existing sounds/popups unchanged | N1 | `notification_events_test` |
| N3 | Bildirimler in Android + local + cloud apps; LAN events + Supabase Realtime | Claude (cloud read RPCs: Codex) | 🔄 LAN done: `/api/notifications` (+`/read`), permission-filtered, per-user read state, bell in Personel and Yönetici pages. Android native + cloud Realtime pending | N1, #39 | `notification_events_test`; owner device test: bell on a real phone |
| N4 | FCM + `flutter_local_notifications` **evaluation only** (free; owner approval before any new project/credential) | Claude | ✅ evaluated: `notifications-push-evaluation.md`. **Owner decision needed** before creating a Firebase project | N1 | — |
| R1 | Trendyol review root-cause investigation | Claude | ✅ verified live (read-only, 2026-11-27): no date filter + page 0 only; store `316490` is correct; no Uber Eats impact | — | `trendyol-review-investigation.md` §6 |
| R2 | Store identity (official `/stores` discovery, `316490` fallback removed, diagnostics) | Claude | ✅ #42 | R1 | `tgo_store_identity.dart`, `test/review_sync_test.dart` |
| R3 | `ReviewSyncService` (date windows, all pages, backoff, single flight) + `pos_platform_reviews` repository + Windows popup + rewritten review screen | Claude | ✅ #42 (Windows); owner-device check pending | R2 | `review_sync_service.dart`, `review_repository.dart` |
| R4 | Yorum Merkezi in Yönetici, Google/other platforms, Android review notifications | Claude | ⏸ paused by owner 2026-11-27 (reviews deprioritized; Windows notifications + reply states already done in R3) | R3, N1 | — |
| S1 | PR-05B typed sync, snapshot/first sync, reconciliation, read projections (incl. reviews/notifications projections when contracts exist) | ChatGPT Codex | 🔄 #39 | A1 | #39 |
| S2 | Phase 5B command queue RPCs | ChatGPT Codex | 🔄 #39 | — | #39 |
| G1 | §24.8 Simplified Giderler: only **Hızlı Gider Ekle** on Windows, Yönetici, Personel (history kept) | Claude | 🔄 Windows Finans › Günlük Malzeme: itemized *Malzeme Ekle* removed, one **Hızlı Gider Ekle**; old itemized rows still listed/editable. Manager actions `quick_save` / `quick_void` (versioned, idempotent request id) serve LAN `/yonetici` (new Giderler card: date, market, Tutar 1 + Tutar Ekle, method, note, live Toplam) and Android Yönetici (shared `QuickExpenseDialog`; *Detaylı Malzeme Ekle* removed, quick rows now editable/voidable). Remaining: Personel own-submission view with explicit create grant (W5 dashboards) | — | `finance_sync_test` (create/retry/stale/edit/void/legacy untouched), `finance_store_picker_test`; LAN smoke on iPhone 13 viewport |
| D1 | §24.7 Gün Sonu Raporu: 21:30 notification (configurable, deduped) + green/cream Yönetici report | Claude (cloud projection: Codex) | 🔄 LAN/Windows done: `lib/daily_report.dart` (exact-kuruş projection: Net = Brüt − İadeler, sales vs collections separate, open accounts, platform breakdown without invented settlement, estimate only when all deductions known, ön rapor while trading/open accounts, previous-day comparison only when final); event `daily:<day>` category `report.daily` (contract + mirror), generic text; Windows Ayarlar › Bildirimler › Gün Sonu Raporu (default 21:30, weekday + special-date/closed); `/api/yonetici/daily` (dashboard.view; amounts need sales.view + finance gate; expenses need finance.view); Yönetici report screen + Özet card + notification deep link, PDF/share. Remaining: cloud projection/push (Codex #39, N3). No staff hours in this report (owner decision 2026-11-27; hours live in weekly Mesai/payroll) | N1 | `daily_report_test` (7), `yonetici_api_test`; Playwright phone/dark/desktop render |
| W1 | §24.4 Vardiya (own planned shifts, shared schedule, no approvals) | Claude UI / Codex sync | 🔄 LAN done: `lib/workforce.dart` `shiftPlans` (own future plans, overnight, break, day off, bounded repeat ≤8 weeks, copy last week, confirmable own-overlap warning, manager edits audited), `/api/work/*`; Personel › Mesai › Vardiyalarım + Ekip programı (names/times only); Yönetici › Personel › Vardiya Planlama (view). Remaining: manager editing another person's plan in the UI, optional manual notification, Android/cloud (Codex) | — | `workforce_test` |
| W2 | §24.4 Mesai (own actual hours, manual only) + weekly Taslak/Gönderildi submission | Claude UI / Codex sync | 🔄 LAN done: manual records in `shifts` (source `manual`; past days, break, no future/overlap, edits keep previous values, void with reason), `timesheetWeeks` (Taslak / Gönderildi / Değişti / Çalışma yok, every snapshot kept); Personel › Mesai (week view, Mesai Ekle/Düzenle/İptal, Haftalık Mesailerimi Gönder, estimated earnings when hourly rate exists); Yönetici › Personel › Mesai Takibi. Existing Mesai Başlat/Bitir kept (explicit, user-operated). Remaining: Windows screen, Android/cloud (Codex) | W1 | `workforce_test` (8); Playwright phone smoke |
| W3 | §24.5 Hourly rates with effective dates + payroll payment ledger (Nakit/Havale/Karma, derived status) | Codex ledger / Claude UI | 🔄 Windows/LAN done: `lib/payroll.dart` (`employees[].payHistory` effective-dated rates, kuruş earnings rounded once per week, missing rate = incomplete not 0, `finance.payrollPayments` append-only ledger with Avans and audited reversal `pr_<id>`, `finance.payrollReviews` explicit Ödenmedi; legacy `weeklyPayroll` weeks refuse ledger rows so nothing is double counted); finance summary + PDF include ledger payroll; Personel › Mesai shows own Kazanılan/Ödenen/Kalan. Remaining: Android/cloud projection of the ledger (Codex), Windows payroll screen | W2 | `payroll_test` (8) |
| W4 | §24.6 Haftalık Maaş Ödemeleri panel + Sunday/Monday reminders | Claude | 🔄 LAN done: Yönetici › Personel › Haftalık Maaş Ödemeleri (Ödeme Kaydet Nakit/Havale/Karma/Avans, Düzelt with reason, Ödenmedi, Ücret), persistent Özet warning until every status is resolved; `lib/payroll_reminders.dart` Sunday 18:00/21:30 own-week reminders, payday 09/14/20 then daily 09:00, stable ids, generic lock-screen text, `personal` category scoped by `recipientEmployeeId`. Remaining: Windows reminder-time settings, FCM push (not approved) | W2, W3, N1 | `payroll_test`; Playwright phone smoke (partial → reverse → full) |
| Q1 | Cross-platform logic audit + QA matrix (owner mandates 2026-11-27 18:50/18:53) | Claude (Codex for sync/ledger rows) | 🔄 `docs/qa/FUNCTIONAL_QA_MATRIX.md`: 12 defects fixed in #44 (identity bound to session, owner excluded from payroll via `employees[].payrollEligible`, honest statuses Çalışma kaydı yok / Ücret belirlenmedi, reminders only for real outstanding pay, effective-dated Windows rate edits, no seeded names on fresh installs). Orders/payments/analytics/Android re-audit still open | — | `payroll_test` (13), `lan_auth_gate_test`, `workforce_test`, `control_workflows_test`; Playwright synthetic scenarios |
| Q2 | Ayarlar information architecture + premium redesign + settings audit on all platforms (relayed by ChatGPT on #44 comment 7222677347; owner confirmed all relayed instructions 2026-11-27 20:07) | Claude (Codex for shared config/sync contracts) | 🔄 Windows step 1 done: grouped navigation (Genel Bakış; İşletme: Personel, Kullanıcılar & Güvenlik, Telefon Bağlantısı; Operasyon: Yazıcı & Fiş, Bildirimler & Sesler, Entegrasyonlar, Menü & QR; Sistem: Yedekleme & Geri Yükleme) with settings search; only existing, working settings are listed (no Bulut & Senkronizasyon page until Codex's sync UI exists). Next: settings inventory (platform, role, scope, default, storage, sync eligibility, audit, failure behavior), mobile/web settings pages | Q1, #39 | branch `claude/project-thread-51u0i4` |
| W5 | §24.3 Ana Sayfa dashboards (Personel, Yönetici) + personal performance | Claude | ⏳ | W1–W3 | — |
| W6 | §24.2 Activation invites, pending approval, 5-digit trusted-device PIN | Claude (cloud: A2) | ⏳ | A2 | — |
| P6 | Windows sales/top products/heatmap projections (Phase 6) | open | ⏳ | — | — |
| P7 | Phase 7 acceptance incl. spec §23.7 | all | ⏳ | all | — |

**Blockers / owner actions:** live Trendyol read-only check needs explicit owner authorization (R1); physical iPhone HTTPS/Safari test (L4); any FCM project needs owner approval (N4); KVKK gate unchanged.

## Antigravity (Gemini) temporary backend continuation — Increment C: Cloud Notifications & Gün Sonu Raporu Projections (2026-11-27)

- **Branch / PR:** `gemini/backend-continuation` (**PR #46** draft targeting `chatgpt/pr-05b-cloud-rpcs`).
- **Status:** `Implemented / Tested` (NOT self-verified; independent review requested from ChatGPT / Codex).
- **Implemented:**
  - `supabase/migrations/20261127170000_nohut_notifications_and_daily_reports.sql`:
    - Private `nohut_private.cloud_notifications` + `nohut_private.notification_reads` (FORCE RLS + owner-only policy, zero direct client grants) + `public.nohut_notifications_list` (client-, permission-, and personal `recipientEmployeeId`-filtered) + `public.nohut_notification_mark_read` (per-user read state).
    - Private `nohut_private.daily_report_summaries` (FORCE RLS + owner-only policy) enforcing owner decision (`QA-05` permanently superseded): **`staffHours` / `workingHours` are strictly rejected at schema and projection level**.
    - `public.nohut_daily_report_view` requiring `dashboard.view` and gating sales/collections/platforms on `sales.view` and expenses/profit on `finance.view`, with explicit `syncMeta`.
    - Extended `ingest_sync_transaction` for `entity_type in ('notifications', 'dailyReports')`.
  - Aligned `docs/contracts/v1/permissions.json` and `flutter_desktop/lib/permission_roles.g.dart` with `menu.*` parity (`20261127168000` / Claude `20261127221000`).
  - `supabase/tests/notifications_and_daily_reports_test.sql` + `docs/contracts/v1/notifications-and-daily-reports.md`.
- **Validation (synthetic data only):**
  - Local Docker Postgres 16: **57/57 migrations & 31/31 SQL tests passed** under both `postgres` superuser and `cloud_migrator` (`NOSUPERUSER NOBYPASSRLS`).

## Antigravity (Gemini) temporary backend continuation — Increment B: QR Menu Management Cloud Integration (2026-11-27)

- **Branch / PR:** `gemini/backend-continuation` (**PR #46** draft targeting `chatgpt/pr-05b-cloud-rpcs`).
- **Status:** `Implemented / Tested` (NOT self-verified; independent review requested from ChatGPT / Codex).
- **Implemented:**
  - `supabase/migrations/20261127168000_nohut_qr_menu_cloud.sql`:
    - Idempotent `menu.*` role parity alignment for `Personel`, `Müdür`, and `Yönetici` (matching Claude's `20261127221000_nohut_menu_parity.sql`, zero broadening outside `menu.*`).
    - Private `nohut_private.qr_menu_state` (FORCE RLS + owner-only policy, zero direct client grants), recursive `contains_forbidden_secret_key` guard blocking any token/key from entering cloud state or commands, `apply_qr_menu_projection`, and atomic `ingest_sync_transaction` support for `entity_type = 'qrMenuState'`, `entity_id = 'core'`.
    - JWT-authenticated `public.nohut_qr_menu_view(p_device_id, p_client, p_permission_version)` returning Claude's `#7228113217` contract shape + dynamic `can` map + `syncMeta`.
  - `supabase/migrations/20261127169000_nohut_qr_menu_commands.sql`:
    - Extends `validate_command_payload` and `enqueue_command` for `qr_menu_write` (per-action `menu.*` grant), `qr_menu_publish` (`menu.qr.publish`, `confirmed: true`, 5m TTL), `qr_menu_reconcile` (`menu.qr.publish`, 5m TTL), `qr_menu_image` (`menu.product.edit`, MIME/path/6 MB cap, 10m TTL), and `qr_menu_sync` (`menu.product.edit`, 5m TTL), preserving `expectedStamp`, `requestId` idempotency, actor binding, and zero credentials in cloud.
  - `flutter_desktop/lib/cloud_qr_menu_bridge.dart` + `flutter_desktop/test/cloud_qr_menu_test.dart` + `docs/contracts/v1/qr-menu-cloud.md`.
  - CI fixes: eliminated `sync_registry_drift_test` false positive (`s['start']` → `shiftRow['start']` in `cloud_workforce_summary.dart`) and aligned `finance_store_picker_test.dart` to Istanbul business day (mirroring Claude `da7faf5`).

## Antigravity (Gemini) temporary backend continuation — Increment A: QA-09 / O-03 Workforce & Payroll Read APIs (2026-11-27)

- **Branch / PR:** `gemini/backend-continuation` (branched from verified PR #39 head `8d918b2`, draft PR targeting `chatgpt/pr-05b-cloud-rpcs`; PR #39 untouched).
- **Status:** `Implemented / Tested` (NOT self-verified; independent review requested from ChatGPT / Codex when available).
- **Implemented:**
  - `supabase/migrations/20261127166000_nohut_workforce_summaries.sql`: private `nohut_private.weekly_workforce_summaries` (FORCE RLS, zero direct client grants), `apply_workforce_summary_projection`, and atomic `ingest_sync_transaction` support for `entity_type = 'workforceSummaries'`, `entity_id = 'core'`.
  - `supabase/migrations/20261127167000_nohut_workforce_read_rpcs.sql`: `sync_freshness` helper + 3 JWT-scoped `SECURITY DEFINER` read RPCs:
    - `public.nohut_workforce_own_week(p_device_id, p_client, p_permission_version, p_week_start)` — matches Claude's `/api/work/week` shape, strictly bound to `auth.uid() -> pos_employee_id` (impossible to query another employee).
    - `public.nohut_team_schedule(p_device_id, p_client, p_permission_version, p_from, p_to)` — shared schedule with employee names and shift times ONLY (zero wages, zero manager notes, zero payroll).
    - `public.nohut_payroll_week(p_device_id, p_client, p_permission_version, p_week_start)` — matches Claude's `ownerPayroll` shape, enforces `payroll.view` (or owner), excludes non-eligible owners (`payrollEligible=false`), preserves `null` for missing wages (`Ücret belirlenmedi`), retains departed employees with unpaid hours, and returns explicit `syncMeta` (`sourceRevision`, `calculatedAt`, `syncedAt`, `stale`, `staleReason`).
  - `flutter_desktop/lib/cloud_workforce_summary.dart`: Windows-authoritative serializer reusing `payrollStatus`, `ownWeek`, `payRateOn`, `weekStartOf` (no parallel cloud wage engine).
  - `docs/contracts/v1/workforce-reads.md`: full contract documentation.
- **Validation (synthetic data only):**
  - `flutter test test/employee_wage_sync_test.dart test/payroll_ledger_sync_test.dart test/workforce_summary_sync_test.dart`: **3/3 passed** (verifies owner acceptance 1760/800/960/0, `Kısmen Ödendi` → `Ödendi`, missing rate `null`, owner exclusion, departed employee unpaid dues).
  - Local Docker Postgres 16: **54/54 migrations & 29/29 SQL test files passed** under both `postgres` superuser and `cloud_migrator` (`NOSUPERUSER NOBYPASSRLS`), including `supabase/tests/workforce_read_rpcs_test.sql` (privacy, permissions, stale-data detection, cross-tenant isolation, direct-table RLS block).

## Codex verified payment attribution and source-contract checkpoint (2026-11-27)

- Integrated Claude 97bf0c2 / PR #44 0e36b63 into #39 only (bacae0a). Exceptional manual corrections now retain nonzero breaks in both audit snapshots; 8 targeted shifts/manual/submission tests pass. Equivalent render-helper fixes resolved using the already tested try/finally behavior; no agent branch changed.
- Extended actual HTTP flow: JWT enqueue → scoped lease/Windows execution → durable confirmation → typed ingestion for pay, payMixed and payProducts. All four resulting payment rows carry session-derived staffId=1 and resolve to that tenant's payments.employee_id. Re-enqueue/worker replay creates no extra payment. Full HTTP integration passed; this covers the attribution gap without changing the existing serializer/business handler.
- Gemini Pass 6 independently verified QA-07, QA-08 and QA-12/O-10 resolved, and wage/ledger/manual attendance slices clean (20c1fa7). O-10 matrix updated with independent evidence. New schedule/submission re-review requested; authorized reads/runtime keep O-03 open.
- New source-contract requests on #44: correctShift must bump an existing manual updatedAt to reject stale employee forms; historical payday source contract needed because payrollStatus default/reminder configured offsets currently differ and historical due-date retention is not explicit. Do not invent a parallel cloud wage/payday engine. Continue independent read integration; no production actions.

## Codex planned Vardiya checkpoint (2026-11-27)

- QA-09 fifth slice: shiftPlans now ingests into private typed shift_plans and immutable shift_plan_history, separate from actual hours/payroll. Existing source IDs, tenant employee/nullable actor mapping, historical labels, overnight flags, breaks/notes/day off, creation/update and cancelled rows are preserved. Edits retain typed before-values; cancellation keeps the actual source audit without inventing a before snapshot. Missing/rewritten history, invalid intervals, stale revisions and resurrected cancellations fail before ACK. Confirmed overlap remains the existing Windows decision.
- Validation: **52 migrations / 28 SQL suites** pass as superuser and non-BYPASSRLS owner; targeted plan/submission/workforce **11 passed**. Real HTTP/PostgreSQL passes repeats, overnight edits, lost ACK, cancellation/day off, and proves plans create no actual work. Full Windows **494 passed, 2 skips**; analysis no errors/warnings (596 style/deprecation infos).
- Shared inventory marks the five typed workforce slices implemented/tested only in PR #39, not merged/deployed. O-10 index is documented tested with independent re-review pending. O-03 remains open for authorized Windows-calculated summaries/read APIs and cloud client runtime wiring. Contract: docs/contracts/v1/planned-shifts.md. Other remaining first-sync/domain/runtime/Phase 7 requirements are unchanged.
- Independently verified all seven CI workflows green at 20c1fa7: Windows 46047503911; Android Personel 46047503912 / Yönetim 46047504023; PWA 46047504002; PostgreSQL 46047504010; auth 46047503959; HTTP 46047503955. New-head CI follows push; green CI does not satisfy remaining PR completion gates. No production or real data actions.

## Codex weekly submission checkpoint (2026-11-27)

- QA-09 fourth slice: existing timesheetWeeks event now ingests private typed weeks, immutable submission ordinals and nested historical entry snapshots. Stable source week/shift identities, tenant employee mapping, Istanbul Monday weeks, exact integer-minute totals and current-or-audited historical interval matching are enforced. Changed/omitted snapshots, entry-set changes, invented intervals and inconsistent current headers abort the complete transaction. Shift ingestion precedes submissions; no approvals or planned-hour pay introduced.
- Validation: **49 migrations / 27 SQL suites** pass under both superuser and non-BYPASSRLS owner. Targeted real Windows weekly/manual/workforce suite **11 passed**; actual HTTP/PostgreSQL passes submit → lost ACK/retry (one snapshot) → corrected/resubmitted → explicit no-work, retaining [480, 510, 0] minutes and all historical entries. Analysis has no errors/warnings (596 style/deprecation infos). Latest full Windows baseline remains the prior **492 passed, 2 skips**; do not count this as a new full-suite run.
- Registry/data inventory now distinguish the tested PR-only wage/ledger/submission slices from unimplemented planned shifts; nothing merged/deployed. Contract: docs/contracts/v1/timesheet-submissions.md. Planned Vardiya, authorized weekly summaries/read APIs, initial snapshot/reconciliation, remaining eligible domains and runtime command/auth integration remain open. QA-09/O-03 is not closed; PR stays draft.

## Codex manual Mesai checkpoint (2026-11-27)

- Integrated Claude d22e706 print completion revision-race fix and Q2 settings inventory/navigation into #39 only (merge 44157be). Preserved existing operations, frozen receipt audit and test-only renderer fix. No other agent branch modified.
- QA-09 third slice: existing atomic shifts event now supports source=manual, exact break minutes, notes, created/update timestamps, retained void facts and before/after break history. Stable shift IDs/correction ordinals, tenant employee/actor mapping, immutable historical labels/creation, complete append-only correction chains and audited voids are validated before ACK. Legacy explicit clock records retain compatibility. No planned hours become actual attendance or wages; no approvals added. Contract: docs/contracts/v1/manual-attendance.md.
- Validation: **46 migrations / 26 SQL suites** pass as superuser and non-BYPASSRLS owner, including break rewrites, broken chains, omitted history, historical attribution changes and void undo rejection. Targeted manual/workforce/receipt/print suite **20 passed**. Actual HTTP/PostgreSQL manual create → edit → void retains 480 → 510 → 0 active minutes and two immutable corrections. Full Windows **492 passed, 2 skips**; analysis has no errors/warnings (594 style/deprecation infos).
- Dependency request #44 comment 7225045679: correctShift must include unchanged nonzero breakMinutes in exceptional manual correction snapshots; Codex does not guess missing historical breaks or duplicate Claude's handler. Continue independent schedules/submission/read work. QA-09/O-03 remains open.
- CI at a6f35c8: dynamic-port HTTP 46046252798, PostgreSQL 46046252927, auth 46046252795, PWA 46046252641 and both Android builds 46046252833/46046252759 pass. Windows still running at that check; latest-head CI pending. PR remains draft, production/legal/physical-device gates unchanged.

## Codex integration-test reliability checkpoint (2026-11-27)

- Full native suite initially exposed 12 render-helper invariant failures on local Flutter 3.47.4: debugDisableShadows was restored in tearDown after binding invariant checks. Test-only try/finally now restores the prior flag before returning, keeping actual shadow rendering and all assertions. **45 native tests pass**, including all 12 rendering smoke tests. A separate actual capture run passes all 12 and writes bundled-font light/dark PNGs locally; owner payroll light and staff payroll dark inspected. This is widget-render evidence, not physical Android testing. Claude notified on #44.
- PWA typecheck and **36 tests pass**. New HTTP CI at 8b78745 failed before tests: EADDRINUSE on hardcoded 55440. Bridge/CI now use an OS-assigned loopback port and readiness URL written only after migrations/listen succeed. Actual full synthetic HTTP/PostgreSQL test passes on the dynamic port while 55440 remains occupied; no data/security tests weakened. Replacement CI pending.
- Claude d22e706 QA-13 print-race fix and settings inventory acknowledged, fetched for the next integration; not yet included in this checkpoint. No production actions. Remaining S1/S2 and QA-09/O-03 work unchanged.

## Codex payroll ledger checkpoint (2026-11-27)

- QA-09 second slice: typed payrollPayments (partial/mixed payments, advances, audited exact reversals) and payrollReviews (Ödenmedi acknowledgement, no movement) reuse Claude's handlers and the existing atomic finance transaction. Stable source UUID mapping, tenant employee attribution, exact components, immutable financial facts, complete retained history and legacy-week exclusion are enforced before ACK. Private tables have FORCE RLS and no direct client grants. Contract: docs/contracts/v1/payroll-ledger.md.
- Validation: **44 migrations / 25 SQL suites** passed as superuser and plain non-BYPASSRLS owner, including invalid new amounts/methods/dates, changed/omitted history, exact reversal and duplicate-reversal cases. Targeted payroll/finance Flutter **25 passed**; full Windows **490 passed, 2 skips**. Actual HTTP/PostgreSQL passes lost ACK with one partial mixed payment, retained original + exact reversal + final payment (net 176000 kuruş), and one nonfinancial unpaid review. Analysis no errors/warnings (593 style/deprecation infos).
- Native Android/PWA checks and new CI running; no production calls. Manual-attendance extensions, planned shifts, weekly submissions and authorized Windows-calculated summary reads remain pending; QA-09/O-03 stays open. PR #39 remains draft.

## Codex workforce integration and wage checkpoint (2026-11-27)

- Integrated Claude #44 actual head 735d8e9 into #39 only (f5614fe), preserving native applications, ownerPayroll, PIN compatibility, manual workforce/payroll handlers, notifications, quick expenses and no daily staffHours. Merge keeps both durable remote receipts and indexed local receipts. Removed duplicate constant field entries from the automatic registry merge; retained every field. No other agent branch changed.
- Combined full Windows regression: **488 passed, 2 skips**. New wage/privacy/payroll targeted suite **24 passed**; real synthetic HTTP/PostgreSQL passes rate history, explicit owner exclusion and lost ACK recovery alongside prior financial/command flows. Analysis: no errors/warnings (592 style/deprecation infos). All **42 migrations / 24 SQL suites** pass under superuser and plain non-BYPASSRLS owner, including Claude's existing five-digit PIN migration.
- QA-09 first slice: employee eligibility/current wage and immutable effective-dated history now use the existing atomic employees event, tenant source identities and strict private tables. Explicit owner eligibility changes and departed employees' rates survive. Contract: docs/contracts/v1/employee-wages.md. Payroll payment/review, planned shifts, manual-attendance extensions, weekly submissions and authorized reads remain incomplete; O-03 is not closed.
- Audit fix abbcf31 CI: PostgreSQL 46043308865, auth 46043308605, HTTP 46043308571, PWA 46043308550 and both Android builds 46043308616/46043308668 passed; Windows still running at this check. New integrated-head CI follows push. PR stays draft; no production sync or deployment.

## Codex resume checkpoint — QA-07 / QA-08 / QA-12 (2026-11-27)

- Read all coordination on #39/#44/#45 since e826e06; inspected actual main ed7ccce, Claude 7455259 and Gemini a2cc234. Integrated merged N1 notification work; active agent branches remain untouched. Payroll/workforce parity (QA-09/O-03), quick commands, authorized notifications/daily reads and full snapshot/runtime work remain open. Daily projections must omit staffHours; Claude's five-digit PIN migration and O-11 are reused, not recreated.
- Additive migration 20261127154000 enforces exact combined-payment component sums, cash/card/mixed consistency and received cash. Typed terminal attempts preserve all definitive outcomes (approved/declined/cancelled), including their immutable facts; identical observations still retry safely.
- Added sync_outbox_pending partial index on seq WHERE acked_at IS NULL for new and existing SQLite databases. The upgrade test preserves existing rows and verifies SQLite actually selects the index; Claude's receipt indexes/polling fixes remain his implementation.
- Validation: 40 migrations / 23 SQL suites passed under superuser and non-BYPASSRLS owner; targeted outbox/ledger/terminal Flutter suite 12 passed; actual synthetic HTTP/PostgreSQL flow passed mixed financial ingestion, terminal history and lost ACK recovery. Independent re-review and new CI pending after push. No production deployment or real data.

## Integration checkpoint — Codex, 2026-11-27

- Integrated main PR #42 (f90e284) without conflicts, preserving Claude's accounts, LAN apps, reviews and terminal deletion guards alongside typed cloud synchronization.
- Combined validation: **432 Flutter tests passed, 2 skips** (HTTP integration executed separately); analysis has no errors/warnings (587 existing style/deprecation infos). **39 migrations / 23 SQL suites** pass as superuser and a plain owner without BYPASSRLS. Real HTTP/PostgreSQL integration passes approved installation, concurrent enrollment, lost setup/ingest ACK, typed domain ingestion and authoritative command recovery.
- Previous 6dc0343 Windows/PWA/both Android CI passed; SQL/auth/HTTP CI failed because the PR merge test included main's new ticket requirement while fixtures still used old registration. Fixtures and explicit trusted-bootstrap test-role grants are now corrected; replacement CI remains to verify after push. No security check was bypassed.
- Connectivity remains the owner's final strategy: Windows authority; Android cloud + LAN; local iPhone apps inside without VPN; existing Cloudflare PWAs outside via VPN. No hosting or infrastructure change.
- PR #39 remains draft. Remaining eligible domains, initial snapshot/staging/reconciliation, authorized reads, runtime/auth integration and Phase 7 gates remain incomplete; nothing deployed or uploaded to production.

## Phase status

| Phase | Status | Evidence |
|---|---|---|
| 0 Audit and baseline | ✅ merged (#31) | `phase-0-report.md` |
| 1 Encrypted backup and restore | ✅ merged (#32) | `backup-restore.md`; physical second-PC restore pending (owner) |
| 1B Per-entity tables, soft delete, no ceiling | ✅ merged (#33) | `storage-benchmark.md` (before/after, 1k–100k) |
| 2 PR-04 Transactional outbox | ✅ merged (#34, ChatGPT) | `test/sync_outbox_transaction_test.dart` |
| 2 PR-05A PostgreSQL foundation (private schema, deny-all RLS) | ✅ merged (#35, ChatGPT) | `supabase/tests/*`, `nohut-postgres-foundation.yml` |
| 2 PR-05B Ingest/reconcile RPCs, typed serializers, client grants | 🔄 PR #39: employee/shift, typed finance/catalog/local orders/payments and scoped transports tested; receipt audit increment in progress; platform/settings, remaining registry domains, snapshot and reconciliation still open | `supabase/migrations/`, `supabase/tests/`, `flutter_desktop/test/cloud_http_integration_test.dart` |
| 2 PR-06 SyncWorker (client) | ✅ merged (#37) | `lib/sync_worker.dart`, `test/sync_worker_test.dart` (fake server with #35 rules) |
| 2 PR-06 first-sync wizard + Bulut & Senkronizasyon UI + Supabase transport | ⏳ needs PR-05B RPCs | — |
| 3A Auth control plane in PostgreSQL (users ↔ employees, role templates, per-user grants, devices, sessions, PIN verifier, audit, `authorize()` / `command_actor()` / owner admin functions) | ✅ merged (#40, Claude). Tested locally on PostgreSQL 16 as superuser **and** as a plain owner without BYPASSRLS; PR-05A tests still pass with it applied | `supabase/migrations/20261127005000_nohut_auth_control_plane.sql`, `supabase/tests/auth_control_plane_test.sql`, `.github/workflows/nohut-auth-control-plane.yml`, `tools/permission_catalogue_sql.py` (DB catalogue = contract) |
| 3B-1 Client auth API: `public.nohut_*` wrappers (identity from JWT `sub`/`session_id`/`aal` only; `authenticated` only, anon refused): register device, whoami (grants for that app), authorize, PIN set/verify, logout, owner admin (aal2) | ✅ merged (#41, Claude) | `supabase/migrations/20261127006000_nohut_auth_api.sql`, `supabase/tests/auth_api_test.sql`, `supabase/ci/supabase_auth_stub.sql` (CI-only `auth.uid()`) |
| 3B-2 Login BFF on Cloudflare Pages Functions (same origin, HttpOnly refresh cookie, PIN before token), PWA + Android login, owner TOTP | ⏳ Claude | — |
| 3C Windows owner UI: Kullanıcılar & Yetkiler, Bağlı Cihazlar, Tüm Oturumları Kapat | ⏳ Claude | — |
| 4 PWA — functional Personel + Yönetici clients (§22), Bulut/Yedek removed, Cloudflare Pages deploy | ✅ merged (#37); live at https://nohut-personel.pages.dev and https://nohut-yonetici.pages.dev. Screens built on the Windows projection shapes; **live data waits for PR-05B + Phase 3 login**, writes wait for the Phase 5 command channel | `pwa/src/{personel,yonetici}/app.ts`, `pwa/test/shared.test.ts` (28 tests), labelled synthetic preview `npm run build:fixtures` |
| 4 Android Personel/Yönetici on cloud transport | ⏳ needs Phase 3 auth | — |
| 5A Windows command worker (envelope checks, Windows-only refusal, grants, hash, expiry, idempotent receipts) | 🔄 PR open (Claude) | `flutter_desktop/lib/remote_commands.dart`, `test/remote_commands_test.dart` (18), `lib/permission_catalogue.g.dart` (+ drift test) |
| 5B Cloud command queue RPCs (`claim`/`complete`, lease, server envelope with actor + grants) | 🔄 Public JWT/scoped-agent RPCs, action validation, lease validation and receipt recovery tested; production session/setup wiring and full-scope QA still pending | `supabase/tests/app_commands_test.sql`, `supabase/tests/agent_transport_test.sql`, `flutter_desktop/test/cloud_http_integration_test.dart` |
| 5C Shifts on Windows (entity, Mesai Başlat/Bitir, audited correction, remote `clock_in_out`/`correct_shift`) | 🔄 PR #38 (Claude) | `lib/shifts.dart`, `test/shifts_test.dart` |
| 5D Remote reprint (ambiguous prints only, printer checked), product sale toggle (audited), platform Kabul Et / Hazır with stored attempt and `reconciliation_required` | 🔄 PR open (Claude) | `lib/remote_commands.dart`, `test/remote_operations_test.dart`; table `platform_command_attempts` |
| 5E Menu price/campaign edits from apps (versioned) + QR publish request | ⏳ needs owner-approved QR flow review | — |
| 6 Dashboards and parity | ⏳ | — |
| 7 QA, security, packaging, release | ⏳ | `release.yml` ready; needs signed full build |

## Owner correction 2026-11-27 (spec §22) — applies to every agent

- **Auxiliary ledger final local checkpoint:** full Flutter **389 passed, 2 skips** (benchmark and separately executed HTTP integration); analysis has no errors/warnings (587 infos). Real HTTP integration and all 38 migrations / 22 SQL suites passed. Commit/push follows; fresh CI remains to verify. No production data, terminal call or migration was used.

- **Auxiliary financial increment (S1):** typed combined-payment groups/members, terminal attempts/immutable observed events, and legacy cash sessions/movements are implemented. Archived terminal attempts stay in the projection via `deletedOrders.related`; original local arrays/handlers remain intact. Terminal observations are durable before cloud setup, and duplicate unknown queries do not dispatch another charge or invent new financial history. Cash movement UUIDs persist before upload; closing facts come from the existing Windows calculation. Deferred tenant-scoped FKs and dependency ordering validate group/terminal links to synchronized payments before transaction ACK. No customer accountKey, PAN/CVV, processor configuration or credential is projected.
- Auxiliary validation: targeted Windows ledger/group/registry/terminal tests **18 passed**; actual HTTP/PostgreSQL integration passed lost group ACK, exact mixed cash/card and change, Windows cash closure, uncertain→approved terminal history with one linked payment, and archive retention. **38 migrations / 22 SQL suites** pass as superuser and non-BYPASSRLS owner with forged/omitted/rewritten history and actual client-role denial cases. Full regression/analysis running; commit and CI checkpoint follows. Other registry domains, snapshot/reconciliation/read APIs and auth/runtime gates remain open.
- **Command safety checkpoint:** `d4f1b247186f4d0ea7f7d766d636768cc5dbe00a` all seven CI workflows passed: Windows 46007509590, Android Personel 46007509584, Android Yönetim 46007509843, PWA 46007509519, auth 46007510017, PostgreSQL 46007509656 and HTTP integration 46007509591. This supersedes the Windows job cancelled by a newer push at `73cd3a8`; that cancellation was not a test failure.

- **S2 platform uncertainty hardening:** only `PlatformPreflightException` proves an adapter failure before external I/O. A generic `FormatException` can follow a successful external action and is durably `reconciliation_required`; duplicates after restart/expiry cannot repeat it. Package IDs matching several supplier/store records are rejected before recording an attempt or calling a provider. Existing business operations and platform endpoints are reused. Targeted remote command/operation suite **35 passed**, including new malformed-response restart/expiry and ambiguous-package tests. No live platform calls used; full-scope runtime wiring/lease-aware platform adapter remains a release requirement.

- Platform analysis completed with no errors or warnings (576 style/deprecation infos); new CI results to verify after push.

- **Platform validation checkpoint:** full Flutter **386 passed, 2 skips**. Real HTTP integration confirms immutable source corrections/status versions, cancelled lines, privacy redactions, supplier isolation and lost-ACK recovery. All 34 migrations / 21 SQL suites passed in both privilege modes; final analysis and post-push CI tracked separately. Existing active-order behavior and public QR flow are preserved. This is the normalized Trendyol commercial-data slice, not complete settlement/demo-platform/settings coverage or a production activation.

- **Trendyol commercial projection increment:** typed immutable platform-order and line versions now preserve exact recorded amounts, options/removals/extras, original/cancelled quantities and external item IDs when the authorized source provides them. `normalizeTgoPackage.lineFacts` is additive; existing active `lines`, POS totals, endpoint requests, reviews and Store ID logic are unchanged. Legacy records retain explicit unknown original quantities/amount provenance instead of guessed links. Supplier/store/package identities remain separate; duplicate commercial lines are retained. Known contact values are removed from preparation notes before the outbox, and structured contact/raw API fields remain excluded. Actual bank settlement/net/commission values stay null when absent from this source.
- **Platform scope/validation:** this increment covers normalized `trendyolGoOrders`; demo platform POS orders, settlements and other remaining registry domains still need dedicated serializers. PostgreSQL **34 migrations / 21 suites** pass under both roles, including real Dart-shaped fixtures and forged financial/hash/identity/privacy cases. Targeted platform/registry/normalization tests 16 pass; real HTTP test passes status changes, cancellation retention, commercial correction history, lost ACK and supplier isolation. Final full regression/analysis and post-push CI remain to record.
- **Setup checkpoint:** `810614eb673dc3db9126d30e52bd0e27fe6b272f` all seven workflows passed: Windows 46004071388, Android Personel 46004071027, Android Yönetim 46004071253, PWA 46004071031, auth 46004071283, PostgreSQL 46004070951, HTTP integration 46004071137. Claude's newer review commits remain his; notification/review projections still await his agreed contracts.

- **A1 dependency integrated:** Claude's PR #42 head `53259d722f35284aee1b3fdd3c1f1b4e8c410aec` is merged into this branch without conflict; Claude's branch was not changed. Windows owner-session/MFA SQL contract is available. Added Windows-only scoped setup RPCs and `WindowsAgentSetup` consuming that interface: DPAPI-before-network pending tokens, hash-only enrollment, durable request receipts, lost-ACK recovery, one-time rotation and idempotent revocation. Full Flutter **384 passed, 2 skips**; setup/transport/HTTP tests passed; analysis no errors/warnings (567 infos). Combined SQL **30 migrations / 20 suites** passed in both privilege modes. API: `docs/contracts/v1/windows-agent-setup.md`.
- **A1 dependency resolved in main #42 (`f90e284`), integrated into #39:** approved installation/bootstrap tickets replace unrestricted Windows device registration. The SQL and HTTP agent fixtures now consume the public approval contract; the disposable plain migration owner may explicitly assume `service_role` only for trusted bootstrap fixtures. Its normal identity remains NOSUPERUSER/NOBYPASSRLS. This proves approved installation, not physical OS attestation. Windows login/setup UI remains Claude-owned; first sync and legal/configuration activation remain gated.
- **Receipt checkpoint:** `872787ad5a614c10fa3645f0488e22fd587ab1e9` all seven CI workflows passed: Windows 46001566674, Android Personel 46001566679, Android Yönetim 46001566619, PWA 46001566629, auth 46001566636, PostgreSQL 46001566715 and HTTP integration 46001566631. Receipt audit increment is implemented/tested/pushed, not merged/deployed.

- **Receipt validation checkpoint:** full Flutter suite **379 passed, 2 skips**, with real HTTP integration executed separately and passing. Final targeted receipt tests 3 passed. All **28 migrations / 18 SQL suites** pass as superuser and plain owner; direct `authenticated` table reads are refused. Analysis has no errors/warnings (558 existing/style infos). Receipt source identity is bound to order/batch/kind, frozen content is hash-checked and immutable, and print events have unique persistent IDs and contiguous ordinals. Not merged/deployed; pending CI is verified after push.

- **Owner autonomy authorization:** continue assigned development and GitHub coordination through Phase 7, committing/pushing tested increments and merging only after all gates. Claude retains auth/LAN UI/notification/review/analytics ownership. No real transactions, live platform actions, real-data transfer, destructive production changes or paid services without specific authorization. Record physical tests needing the owner while continuing independent work.
- **Order checkpoint:** pushed `cd127aa729a16bb5124c7c3bdf63b759fc8b0555`; all seven CI workflows passed (Windows 45999468296; Android Personel 45999468208; Android Yönetim 45999468054; PWA 45999468084; auth 45999468009; PostgreSQL 45999468602; HTTP integration 45999468137). Analysis: no errors/warnings, 543 style/deprecation infos. This supersedes the unfinished local-order status in the earlier resume checkpoint; platform and other domains remain pending.
- **Receipt audit increment:** local print identities, privacy-redacted frozen content and immutable observed state/attempt events are persisted even before cloud setup. Typed private receipt/print projections retain history through explicit retry, restart and archive. Spool acknowledgement is `spooled`, never proof of paper delivery; cloud audit cannot dispatch a printer. Missing legacy frozen sources are refused, not reconstructed from mutable orders. No raw original receipt text, customer name/phone, printer bindings or platform receipt payloads are uploaded. SQL 28 migrations + 18 suites pass in both privilege modes; targeted/privacy and real HTTP receipt integration pass. Full regression/analysis results to record before push. Claude has been asked to coordinate any physical reprint job/attempt identity changes; existing business handlers are reused.

- **Local-order increment (PR #39, implemented/tested, not merged/deployed):** durable nested IDs, frozen commercial definitions, customizations/campaign components, partial/mixed payments, guest checks/allocations, refunds, line-edit/void history and atomic audited deletion. Server validates per-order manifests, dependency order, exact totals, Istanbul business dates, immutable financial history and private field schemas before advancing the checkpoint. Platform orders still fail closed pending their dedicated records; receipts/print jobs, remaining registry domains, snapshot staging/reconciliation and read APIs remain open.
- **Order validation:** full Flutter regression suite **376 passed, 2 skips** (benchmark and separately run real HTTP test); targeted identity/campaign tests 3 passed. Expanded real HTTP/PostgreSQL integration passed split checks, mixed cash/card, lost payment ACK, refund totals, historical sale price changes and complete deletion archive. All 24 migrations and 17 SQL suites pass as superuser and non-BYPASSRLS owner, including new adversarial order/privilege tests. Full analysis and new commit CI are tracked separately; no production data or migrations used.

- **Connectivity decision (owner verified on physical iPhone):** retain both Cloudflare PWAs and Supabase, without a hosting change or domain purchase. Windows POS remains authoritative; Android native applications support cloud and authenticated LAN. iPhone inside the restaurant uses Claude-owned local browser applications without VPN; outside it uses the existing Cloudflare PWAs, currently accessible over VPN on the owner's network.
- **Coordination:** before each development increment, read this board, fetch main, review relevant PR/issue discussions, recent commits and CI. Use GitHub comments with FROM / TO / STATUS / TASK / DEPENDENCY / EXPECTED INTERFACE / ACCEPTANCE CRITERIA / RELATED PR / EVIDENCE. Claude owns authentication, local browser UI, Notification 2.0, reviews and Windows analytics. Codex consumes those contracts and does not duplicate them.
- **Resume checkpoint:** `b0e121b68e6a328493165b45a6bd161b4f327f65` independently verified with all seven workflows successful (Windows, both Androids, PWA, auth, PostgreSQL and HTTP integration). Order/payment identity, serializer and schema changes are preserved and in progress; they are not a released or complete ingestion path yet. Windows owner-session/MFA dependency remains requested on PR #39; no response or new published Claude commit at this check.

- **Bulut & Senkronizasyon and Yedekleme & Geri Yükleme are Windows-only.** Do not add them to Android or PWA clients. Catalogue `docs/contracts/v1/permissions.json` (`schemaVersion 2`) gives every operation `clients`; `sync.*`/`backup.*` are `["windows"]` and must be rejected from remote clients by the server and the Windows worker, even for the owner.
- Mobile/web show only read-only indicators: connection, last sync, offline, stale, pending commands, Windows availability.
- Personel opens on **Masalar** (nav: Masalar · Siparişler · Online · Mesailerim · Daha Fazla); Yönetici on **Genel Bakış** (nav: Genel Bakış · Satışlar · Finans · Personel · Daha Fazla).

### Data the clients already render, and who must produce it

| Projection (cloud, read-only) | Shape source | Status |
|---|---|---|
| `staff_state` (tables, open orders with Windows totals, menu, online orders, notices, `platformWritable`) | `lan_server.dart::_staffState` | exists on LAN; cloud projection = PR-05B |
| `owner_overview(day)` | `finance_sync_server.dart::ownerOverview` | exists on LAN; cloud projection = PR-05B |
| `month_view(month)` | `finance_sync_server.dart::monthView` | exists on LAN; cloud projection = PR-05B |
| `sales_daily` + `top_products` + `heatmap` + `platform_sales` (`SalesView` in `pwa/src/shared/model.ts`) | **new — Windows must compute** from orders/payments | ⏳ Phase 6 |
| `shifts` (Mesai Başlat/Bitir, corrections) | `flutter_desktop/lib/shifts.dart` (state key `shifts`, registered + cloud-allowlisted) | ✅ Windows model + commands (PR #38); cloud projection = PR-05B |
| `menu_status` (QR version, publish state), `integrations` status | Windows QR publisher / integration settings | ⏳ Phase 5 |
| `users`, grants, devices, `audit` | Phase 3 auth | ⏳ Phase 3 |

### Commands the clients already send (payloads = Windows `submitStaffOrder`/`submitStaffAction`)

`order` (new/ek sipariş, Gel-Al), `action` (`pay`, `payMixed`, `payProducts`, `splitEqual`, `move`, `close`, `status`) — **handlers exist on Windows**.
New handlers needed on Windows (Phase 5): `print.reprint`, `platform.accept/ready` via the cloud channel, `menu_update`/`stock_update`/`qr_publish`, `shift.clockIn/clockOut`, `finance.managerWrite` over cloud, `admin.*` (Phase 3). Until the cloud command channel exists, clients answer *"Uzaktan işlem kanalı henüz açık değil"* and never show success.

## Auth / authorization contract for PR-05B (Phase 3A, Claude) — read before writing RPCs

Owner decision 2026-11-27: ChatGPT builds PR-05B (cloud functions), Claude builds Phase 3. To avoid overlap:

- **Claude owns** the migration `…005000_nohut_auth_control_plane.sql` (PR #39 uses distinct versions 20261127121000–20261127126000; no dependency on them) and the tables it creates in `nohut_private`: `app_users`, `operation_catalogue`, `user_grants`, `devices`, `sessions`, `security_audit`. **ChatGPT's** `…001000` / `…002000` migrations and `nohut-postgres-foundation.yml` are not modified; Phase 3A has its own workflow that applies all three migrations in order.
- **Every PR-05B RPC that reads or writes for an app user must first call**
  `nohut_private.authorize(p_user_id uuid, p_session_id uuid, p_device_id uuid, p_client text, p_operation text, p_permission_version bigint) returns text`
  and continue only on `'ok'`. Other results (`unknown_user`, `inactive`, `session_revoked`, `device_revoked`, `stale_permissions`, `windows_only`, `client_not_allowed`, `forbidden`, `unknown_operation`) map to a generic 403 with the code in the body. `p_user_id` is `auth.uid()` in the API wrapper — never a client-supplied value.
- **Remote command envelopes** (Phase 5A, `flutter_desktop/lib/remote_commands.dart`) take `actor` from
  `nohut_private.command_actor(p_user_id uuid) returns jsonb` → `{employee_id, is_owner, grants[], permission_version}`; the server adds `client`, `issued_at`, `expires_at`, `payload_sha256` (canonical JSON, sorted keys).
- `sync.*` / `backup.*` are Windows-only: `authorize()` returns `windows_only` for every remote client, including the owner (§22.3).
- Restaurant scoping: every control-plane row carries `restaurant_id`; `authorize()` resolves the user's restaurant itself — RPCs must not trust a client-sent restaurant id.
- Apps call the `public.nohut_*` wrappers (3B-1); PR-05B data RPCs for apps should follow the same pattern: `auth.uid()` + `request.jwt.claims` `session_id`, then `nohut_private.authorize()`.
- Owner administration functions (`admin_create_user`, `admin_set_grant`, `admin_set_active`, `admin_revoke_sessions`, `admin_reset_pin`) take the JWT `aal` claim and require `aal2` (owner MFA). Device login: `enroll_device` after a password login; PIN: `set_pin` / `verify_pin` (bcrypt, 5 failures → PIN cleared, password needed).
- **Heads-up for PR-05B (RLS):** all `nohut_private` tables use FORCE RLS. On a role without BYPASSRLS, SECURITY DEFINER functions see nothing unless a policy allows the owning role. The auth migration adds `control_plane_owner` policies for its own tables (scoped to the migration role); PR-05B functions that read/write the PR-05A tables need the same, or must be verified with a non-BYPASSRLS owner as in `nohut-auth-control-plane.yml`.

## Claims (edit when you start or finish)

| Item | Agent | Since | PR |
|---|---|---|---|
| PR-04 hardening: extra outbox tests; refuse enabling the outbox on a legacy database | Claude Code | 2026-11-27 | this PR |
| PR-06 client side: `SyncTransport` + `SyncWorker` | Claude Code | 2026-11-27 | this PR |
| Phase 3: accounts, PIN, auth, role + per-user permissions (owner: Claude; PR-05B: ChatGPT, must use the auth contract above) | Claude Code | 2026-11-27 | #40 |
| Phase 4: PWA functional clients (§22) + Cloudflare Pages deploy workflow | Claude Code | done | #37 |
| Phase 5A: Windows remote command worker | Claude Code | 2026-11-27 | this PR |
| Phase 5B: cloud command-queue RPCs (`nohut_private.commands`, claim with lease, complete) | ChatGPT | 2026-11-27 | `chatgpt/pr-05b-cloud-rpcs` |
| Phase 6 prerequisite: Windows `sales_daily`/`top_products`/`heatmap` projection functions (pure Dart, tested against `order_reporting.dart`) | **open** | — | — |
| Phase 5 prerequisite: Windows shift entity + clock-in/out commands | Claude Code | done | #38 |
| PR-05B: server RPCs (ingest transaction, reconcile, checkpoint), typed serializers, minimal grants | ChatGPT | 2026-11-27 | `chatgpt/pr-05b-cloud-rpcs` |

## Owner-configured services (2026-11-27, per owner)

| Service | Status |
|---|---|
| Supabase | `nohut-pos`, Free, eu-central-1 (Frankfurt). Project ref and URL in GitHub Secrets. **Migrations not yet applied to production.** |
| Cloudflare | Free; account ID and API token in Secrets. The Pages integration must be re-verified after the repository rename. |
| Android signing | JKS keystore + passwords in Secrets; verified by the "Verify Nohut Configuration" workflow. A full signed release build is still to run. |

**KVKK gate (spec §12.2):** no real personal data goes to Supabase until the owner confirms the legal review. All tests use synthetic data.

### PR #39 coordination (2026-11-27)

Merged main (#40) into the PR #39 working branch, preserving both agents' changes. Auth integration remains internal until scoped transport and revocation tests pass. No production data or deployment.

PR #39: added private `enqueue_command` invoking Phase 3A `authorize()` and `command_actor()` before enqueue or cached duplicate response. It derives restaurant/actor from the control plane and fails closed on unknown actions. No exposed RPC; exact Dart canonicalization, per-action payload allowlists, claim-time revocation and agent credentials are still pending.

PR #39 adds `claim_authorized_commands`: rechecks session/device/permission version at dispatch; revoked pending commands are rejected and previously claimed uncertain commands require reconciliation. Authorization can still change after dispatch; Windows execution/lease fencing and scoped agent transport remain required before release.

PR #39 canonical command hash now generated server-side from sorted JSON, safe integer amounts, booleans, strings, null, and nested lists/objects. Fractional/unsafe numbers and supplementary-codepoint object keys fail closed. Customer contact fields rejected at enqueue; only pickup time is allowed. This is a deliberately restricted contract until action-specific validation and cross-runtime QA are complete.

Integrated #41 and added narrowly scoped migration-owner RLS policies for the private queue/employee ingest and a disposable non-BYPASSRLS CI test. All new results pending. No phone grants or production deployment. Supabase migration versions remain distinct.

PR #39: added private Windows agent enrollment, 30-day opaque hashed credential rotation/revocation and tenant/epoch-derived ingest/claim/complete/checkpoint wrappers. Enrollment requires active manager owner session and MFA; changing PC requires a new epoch. The 30-day lifetime is a proposed engineering default, not deployed. TLS API, DPAPI client storage, agent recovery and all new CI results remain pending.

PR #39: previous head 15316b1 all checks passed (PostgreSQL, auth and Windows build). Added typed shift and immutable correction history projections; employee + shift groups can be committed together, with ACK only after both succeed. Latest tests pending; orders/payments/finance and transport remain incomplete.

### PR #39 continuation — 2026-11-27

- Verified baseline `831f7fe`: PostgreSQL run 45973676444, authentication run 45973676528 and Windows run 45973676430 passed. Main remains `dd64f88` (#40/#41 merged).
- Windows now stores a remote envelope fingerprint and result in the same SQLite transaction as the domain command. Authorized, identical retries return committed receipts even after expiry/restart; changed actor/action/authority cannot reuse that receipt. Failed transactions leave no receipt.
- Platform responses with `verified=false` now require reconciliation. Stored platform attempts are bound to the immutable envelope and returned after expiry without another provider call.
- Local targeted validation: `flutter test test/remote_commands_test.dart test/remote_operations_test.dart test/shifts_test.dart --reporter expanded` — 37 passed. This is implemented/tested on the PR branch, **not merged or deployed**. Full synchronization, public transport, lease integration and end-to-end QA remain in progress; this PR must remain draft.
- Scoped agent HTTP RPCs now authenticate the opaque Windows token before ingest/checkpoint/claim/validate/complete/receipt reconciliation. The PostgREST wrappers require no privileged key on Windows; client roles still have no private schema/table access. Windows transport requires TLS, refuses privileged project keys, binds claims to configured restaurant/epoch/schema, bounds clock skew and response size, and carries the lease generation through validation/completion. Credentials use the existing current-user DPAPI vault. This is a transport implementation, not an activated Windows setup flow.
- The worker reports durable local receipts/attempts before claiming more work and marks them acknowledged only after the cloud accepts the exact result. Expired leases require receipt reconciliation rather than execution. Live claim validation precedes execution.
- Broadened plain-owner coverage exposed previously untested foundation tables without migration-owner RLS policies; added trusted-owner-only policies and expanded PostgreSQL CI to run **all** SQL suites without BYPASSRLS. Local PostgreSQL 16.6: all 14 migrations and 13 SQL suites passed as superuser and plain owner (including actual anon-role scoped agent calls). Flutter full suite: **359 passed, 1 pre-existing skip**; analysis: no errors/warnings (SDK/style infos remain).
- Phase 3 integration dependency posted on PR #39: current device/auth contracts support only `personel`/`yonetici`; a Claude-owned Windows owner session/MFA contract is needed for Windows-only enrollment/first-sync UI. No authentication implementation was duplicated and no remote sync/backup operation was enabled.
- Commit `51be89b`: Windows CI 45977206889, auth CI 45977206965 and PostgreSQL CI 45977206834 all passed.
- Added authenticated `nohut_enqueue_command` / `nohut_command_status`, deriving actor/session from verified JWT and checking permissions before duplicate/status access. Action-specific schemas validate orders/customizations, exact-kuruş custom items, payment/mixed/product splits, table/close operations, shifts/corrections, explicit checked reprints, availability and supported platform actions. Identity overrides and customer contact fields are rejected. Synthetic SQL tests verify revocation, unauthorized cached results, payload errors and pending-only enqueue responses under both database roles.
- PWA and Android command adapters accept a **Phase 3 supplied session provider**, use publishable keys + user JWTs, preserve request IDs after uncertain enqueue, and require authoritative status for confirmation. They are **not wired to a new login flow**: Claude retains that ownership; production PWAs remain gated until authentication and verified first sync exist. PWA typecheck + 36 tests and both production builds passed; Android adapter's 3 targeted tests passed. Stock/print/platform requests fail closed when required identity or explicit safety confirmation is missing; QR publishing is unchanged.
- Restoring a backup now persists a reconciliation fence that blocks remote command execution and both automatic/manual cloud uploads. Local sales remain available. ACK application now atomically records the complete contiguous transaction watermark, source revision and success time. Permanent transport/auth failures stop synchronization without dropping events. Targeted command, backup and sync tests: 57 passed. Full typed domain ingestion, snapshot import/reconciliation, read projections and authenticated UI integration remain incomplete; **do not merge or deploy**.
- Added typed finance serializers and PostgreSQL application for purchases and correction history, expenses, fixed expenses/ranges/amount history, fixed payments/reversals, payroll/advances and manual platform gross/net corrections. Source UUID mappings persist in SQLite; integer facts are validated before database coercion, prior versions are retained, paid payroll/history cannot be rewritten, unknown/missing/conflicting facts abort the transaction. The existing fixed-payment undo/repay feature emits an explicit durable reversal retaining the original amount/time. Raw outbox events remain durable and unmodified; typed encoding is opt-in through `TypedFinanceTransport`.
- Added a **synthetic localhost-only** HTTP/PostgreSQL integration harness and CI workflow. Locally verified actual Dart serializer → scoped HTTP RPC → plain-owner PostgreSQL atomic commit → deliberately lost ACK → duplicate recovery with one expense, then authenticated cloud enqueue → Windows shift commit → confirmed app status → typed shift upload. The bridge explicitly requires a synthetic flag and localhost database and is never a production service.
- Remaining coverage is still substantial: order/catalog/receipt/platform/settings typed serializers and ingestion, first-sync staging/manifests/reconciliation/promotion, read projections, production client-session wiring and full recovery/cutover QA. The finance slice does not enable synchronization or satisfy the PR merge gate by itself.
- Finance slice validation: local PostgreSQL 16.6 all migrations + all SQL suites pass as superuser and plain owner; real HTTP integration passed separately. Full Flutter suite **369 passed, 2 skips** (one pre-existing; the other is the separately executed HTTP integration); analysis has no errors/warnings. Commit `c86222b` CI passed Windows 45978980479, Android Yönetim 45978980691, Android Personel 45978980491, auth 45978980634, PWA 45978980467 and PostgreSQL 45978980642. New finance/integration CI remains to verify after push.
- Commit `d3c2eea` all seven CI checks passed: Windows 45981968319, Android Personel 45981968066, Android Yönetim 45981968077, PWA 45981968047, PostgreSQL 45981968196, auth 45981968051 and real HTTP/PostgreSQL integration 45981968283.
- Added typed products/product versions, categories/category versions and campaigns/campaign versions with exact kuruş, multilingual definitions, private schemas and immutable content verification. Catalog removals use durable source tombstones; reactivation clears the current tombstone while all prior versions remain. `internalMenu` follows the catalog field policy and retains its internal-only flag. No QR publishing code was changed.
- Catalog validation: targeted serializers/privacy/outbox tests passed (16); every SQL suite passes in both privilege modes, including new forged-field/hash/immutable-version/tombstone tests. Expanded real HTTP integration passed for multi-category atomic ingest, price/name change, removal/reactivation with both historical prices retained, lost ACK recovery and Windows shift execution. Catalog analysis has no errors/warnings; full subsequent CI remains to verify. Other domains and the previously documented first-sync/read/session gates remain incomplete.
