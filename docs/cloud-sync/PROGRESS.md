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

**Ownership:** PR #39 / `chatgpt/pr-05b-cloud-rpcs` belongs to **ChatGPT Codex** (has uncommitted local work) — nobody else pushes there. Claude owns auth, local browser UI, notifications, reviews and Windows analytics; Codex consumes those contracts and does not duplicate them.

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
| Q2 | Ayarlar information architecture + premium redesign + settings audit on all platforms (relayed by ChatGPT on #44 comment 7222677347; owner confirmed all relayed instructions 2026-11-27 20:07) | Claude (Codex for shared config/sync contracts) | 🔄 Windows step 1 done: grouped navigation (Genel Bakış; İşletme: Personel, Kullanıcılar & Güvenlik, Telefon Bağlantısı; Operasyon: Yazıcı & Fiş, Bildirimler & Sesler, Entegrasyonlar, Menü & QR; Sistem: Yedekleme & Geri Yükleme) with settings search; only existing, working settings are listed (no Bulut & Senkronizasyon page until Codex's sync UI exists). Step 2 done: settings inventory (`docs/qa/SETTINGS_INVENTORY.md`). Step 3 done on Android: Yönetici Ayarlar grouped (Hesap, Bağlantı, Görünüm, Windows’ta yönetilenler, Bu cihaz) and Personel Daha Fazla (Çalışmam, Hesabım, Bağlantı). Browser PIN change added with a server-side password re-check | Q1, #39 | branch `claude/project-thread-51u0i4` |
| M1 | QR Menü Yönetimi: Windows fix + premium redesign (ChatGPT relay 7226893412), then phones/browser (relay 7226917068) | Claude | 🔄 Windows done: root cause was the page treating an unreachable publisher as "offline" without saying why, and forcing "unpublished changes" on every restored draft. Now: diagnostics (key saved → `/health` on 127.0.0.1:18787 → GitHub catalog), a derived state (Yüklenmedi / Bağlanıyor / Çevrimdışı taslak / Yayındakiyle aynı / Yayın bekliyor / Çakışma var / Yayınlanıyor / Sonuç bilinmiyor) with one primary action each, real diff count, three-way merge of an old draft onto newer GitHub data with explicit per-field conflict choice (no silent overwrite), publish only when validated + revision-bound + changed + connected, a lost answer is persisted (`qrPublisherPendingPublish`) and reconciled against GitHub before any retry, Turkish money, compact rows + edit drawer. Tests: `qr_menu_draft_test` (9), `qr_menu_management_test` (10, fake publisher). Phones done too (D-37): Personel/Yönetici native + browser edit the shared draft over `/api/menu/*` with server-side `menu.*` grants, stale-draft refusal and audit. Parity done (D-38, relay 7226936601 / QA-18): all `menu.*` incl. publish are Personel/Müdür/Yönetici defaults (contract, Windows upgrade, migration `20261127221000`); phones review → confirm → Windows publishes with its own key, verify lost answers, upload photos, POS sync. **Owner (physical):** start the publisher on the Windows PC and save the key; no real publish was made | — | branch `claude/project-thread-51u0i4` |
| UX0 | Premium UI/UX release gate on every surface (relay 7227699704) | Claude (design + implementation), Antigravity (visual/accessibility audit) | 🔄 Inventory + design system: `docs/design/PREMIUM_UI_INVENTORY.md`. Visual acceptance (owner + Antigravity) tracked separately from functional tests. Done so far: Windows QR Menü redesign (review pending), Personel Ana Sayfa (owner chose A "Özet kartı"), Android Mesai/Yönetici/Ayarlar redesign (review pending). Next: shared components, then Masalar / order / payment on Windows and Personel | — | branch `claude/project-thread-51u0i4` |
| W5 | §24.3 Ana Sayfa dashboards (Personel, Yönetici) + personal performance | Claude | ⏳ | W1–W3 | — |
| W6 | §24.2 Activation invites, pending approval, 5-digit trusted-device PIN | Claude (cloud: A2) | ⏳ | A2 | — |
| P6 | Windows sales/top products/heatmap projections (Phase 6) | open | ⏳ | — | — |
| P7 | Phase 7 acceptance incl. spec §23.7 | all | ⏳ | all | — |

**Blockers / owner actions:** live Trendyol read-only check needs explicit owner authorization (R1); physical iPhone HTTPS/Safari test (L4); any FCM project needs owner approval (N4); KVKK gate unchanged.

## Phase status

| Phase | Status | Evidence |
|---|---|---|
| 0 Audit and baseline | ✅ merged (#31) | `phase-0-report.md` |
| 1 Encrypted backup and restore | ✅ merged (#32) | `backup-restore.md`; physical second-PC restore pending (owner) |
| 1B Per-entity tables, soft delete, no ceiling | ✅ merged (#33) | `storage-benchmark.md` (before/after, 1k–100k) |
| 2 PR-04 Transactional outbox | ✅ merged (#34, ChatGPT) | `test/sync_outbox_transaction_test.dart` |
| 2 PR-05A PostgreSQL foundation (private schema, deny-all RLS) | ✅ merged (#35, ChatGPT) | `supabase/tests/*`, `nohut-postgres-foundation.yml` |
| 2 PR-05B Ingest/reconcile RPCs, typed serializers, client grants | ⏳ | — |
| 2 PR-06 SyncWorker (client) | ✅ merged (#37) | `lib/sync_worker.dart`, `test/sync_worker_test.dart` (fake server with #35 rules) |
| 2 PR-06 first-sync wizard + Bulut & Senkronizasyon UI + Supabase transport | ⏳ needs PR-05B RPCs | — |
| 3A Auth control plane in PostgreSQL (users ↔ employees, role templates, per-user grants, devices, sessions, PIN verifier, audit, `authorize()` / `command_actor()` / owner admin functions) | ✅ merged (#40, Claude). Tested locally on PostgreSQL 16 as superuser **and** as a plain owner without BYPASSRLS; PR-05A tests still pass with it applied | `supabase/migrations/20261127005000_nohut_auth_control_plane.sql`, `supabase/tests/auth_control_plane_test.sql`, `.github/workflows/nohut-auth-control-plane.yml`, `tools/permission_catalogue_sql.py` (DB catalogue = contract) |
| 3B-1 Client auth API: `public.nohut_*` wrappers (identity from JWT `sub`/`session_id`/`aal` only; `authenticated` only, anon refused): register device, whoami (grants for that app), authorize, PIN set/verify, logout, owner admin (aal2) | 🔄 PR open (Claude) | `supabase/migrations/20261127006000_nohut_auth_api.sql`, `supabase/tests/auth_api_test.sql`, `supabase/ci/supabase_auth_stub.sql` (CI-only `auth.uid()`) |
| 3B-2 Login BFF on Cloudflare Pages Functions (same origin, HttpOnly refresh cookie, PIN before token), PWA + Android login, owner TOTP | 🔄 Claude: BFF code + tests done (`pwa/functions/_lib/bff.ts`, `pwa/functions/api/auth/[action].ts`, `pwa/test/bff.test.ts`, 7 tests against a synthetic Supabase stand-in): login (password → device register → whoami; refresh token only in `__Host-` HttpOnly/Secure/SameSite=Strict cookie), unlock (refresh rotated, access token released only after `nohut_verify_pin` ok; 5th wrong PIN → password + cookie cleared), PIN set/replace (replacement re-signs in so the JWT has a fresh `amr` password stamp; DB rule migration `20261127211000`), owner TOTP (aal2), logout; same-origin + JSON + size checks, no-store, best-effort throttle. **Not yet:** deploy wiring (the Pages deploy step must run from `pwa/` so `functions/` ships; merging #44 deploys, owner gate), PWA login screens, provider user creation for usernames (`<username>@users.nohut.invalid` in Supabase Auth needs an owner/admin step), live test against a real project (synthetic project only, KVKK gate) | `pwa/functions`, `supabase/migrations/20261127211000_nohut_pin_change_reauth.sql` |
| 3C Windows owner UI: Kullanıcılar & Yetkiler, Bağlı Cihazlar, Tüm Oturumları Kapat | ⏳ Claude | — |
| 4 PWA — functional Personel + Yönetici clients (§22), Bulut/Yedek removed, Cloudflare Pages deploy | ✅ merged (#37); live at https://nohut-personel.pages.dev and https://nohut-yonetici.pages.dev. Screens built on the Windows projection shapes; **live data waits for PR-05B + Phase 3 login**, writes wait for the Phase 5 command channel | `pwa/src/{personel,yonetici}/app.ts`, `pwa/test/shared.test.ts` (28 tests), labelled synthetic preview `npm run build:fixtures` |
| 4 Android Personel/Yönetici on cloud transport | ⏳ needs Phase 3 auth | — |
| 5A Windows command worker (envelope checks, Windows-only refusal, grants, hash, expiry, idempotent receipts) | 🔄 PR open (Claude) | `flutter_desktop/lib/remote_commands.dart`, `test/remote_commands_test.dart` (18), `lib/permission_catalogue.g.dart` (+ drift test) |
| 5B Cloud command queue RPCs (`claim`/`complete`, lease, server envelope with actor + grants) | ⏳ needs PR-05B + Phase 3 | — |
| 5C Shifts on Windows (entity, Mesai Başlat/Bitir, audited correction, remote `clock_in_out`/`correct_shift`) | 🔄 PR #38 (Claude) | `lib/shifts.dart`, `test/shifts_test.dart` |
| 5D Remote reprint (ambiguous prints only, printer checked), product sale toggle (audited), platform Kabul Et / Hazır with stored attempt and `reconciliation_required` | 🔄 PR open (Claude) | `lib/remote_commands.dart`, `test/remote_operations_test.dart`; table `platform_command_attempts` |
| 5E Menu price/campaign edits from apps (versioned) + QR publish request | ⏳ needs owner-approved QR flow review | — |
| 6 Dashboards and parity | ⏳ | — |
| 7 QA, security, packaging, release | ⏳ | `release.yml` ready; needs signed full build |

## Owner correction 2026-11-27 (spec §22) — applies to every agent

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

- **Claude owns** the migration `…005000_nohut_auth_control_plane.sql` (timestamp after ChatGPT's `…003000_nohut_command_queue` and `…004000_nohut_sync_validation` in PR #39, no dependency on them) and the tables it creates in `nohut_private`: `app_users`, `operation_catalogue`, `user_grants`, `devices`, `sessions`, `security_audit`. **ChatGPT's** `…001000` / `…002000` migrations and `nohut-postgres-foundation.yml` are not modified; Phase 3A has its own workflow that applies all three migrations in order.
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
| Phase 5B: cloud command-queue RPCs (`nohut_private.commands`, claim with lease, complete) | **open — suggested: ChatGPT** (continues PR-05B) | — | — |
| Phase 6 prerequisite: Windows `sales_daily`/`top_products`/`heatmap` projection functions (pure Dart, tested against `order_reporting.dart`) | **open** | — | — |
| Phase 5 prerequisite: Windows shift entity + clock-in/out commands | Claude Code | done | #38 |
| PR-05B: server RPCs (ingest transaction, reconcile, checkpoint), typed serializers, minimal grants | **open — suggested: ChatGPT** (continues #35) | — | — |

## Owner-configured services (2026-11-27, per owner)

| Service | Status |
|---|---|
| Supabase | `nohut-pos`, Free, eu-central-1 (Frankfurt). Project ref and URL in GitHub Secrets. **Migrations not yet applied to production.** |
| Cloudflare | Free; account ID and API token in Secrets. The Pages integration must be re-verified after the repository rename. |
| Android signing | JKS keystore + passwords in Secrets; verified by the "Verify Nohut Configuration" workflow. A full signed release build is still to run. |

**KVKK gate (spec §12.2):** no real personal data goes to Supabase until the owner confirms the legal review. All tests use synthetic data.
