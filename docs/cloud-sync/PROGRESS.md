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

### Active ownership (owner decision 2026-11-28 ~00:45Z, relayed 7231136936 / 7231152161 / 7231170702)

Active engineers: **Claude** (Windows, Android, PWA/LAN, auth UI, UI/UX, all client integration) and **Gemini/Antigravity** (backend, Supabase, security, QR publisher #49, Trendyol proxy #50, independent frontend QA #45). Codex and ChatGPT no longer hold active assignments; their branches (#39, #47/#48, #49, #50) and evidence are preserved. Cross-review: Claude reviews Gemini's backend, Gemini reviews Claude's frontend; nobody self-certifies release. Rows below that name Codex/ChatGPT for open work now mean Gemini. Shared 49-item checklist: #44 comment 7231119516.

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
| G1 | §24.8 Simplified Giderler: only **Hızlı Gider Ekle** on Windows, Yönetici, Personel (history kept) | Claude | ✅ client (SQL catalogue row pending Gemini) Windows Finans › Günlük Malzeme: itemized *Malzeme Ekle* removed, one **Hızlı Gider Ekle**; old itemized rows still listed/editable. Manager actions `quick_save` / `quick_void` (versioned, idempotent request id) serve LAN `/yonetici` (new Giderler card: date, market, Tutar 1 + Tutar Ekle, method, note, live Toplam) and Android Yönetici (shared `QuickExpenseDialog`; *Detaylı Malzeme Ekle* removed, quick rows now editable/voidable). Personel: new grant `expenses.quick_add` (defaults Müdür, Yönetici; Personel only when the owner grants it). LAN `GET /api/work/expenses` (own rows, 30 days) and `POST /api/work/expense` (create only, idempotent `requestId`, submitter stamped from the session, kept on manager edit). Personel Çalışmam › Hızlı Gider with a safe "Tekrar Gönder" after a lost answer; editing/voiding stays with the Yönetici. SQL `permission_catalogue` row is Gemini's | — | `workforce_test` (403 before grant, retry no duplicate, submitter, 422), `staff_expense_page_test` (3), `finance_sync_test` (create/retry/stale/edit/void/legacy untouched), `finance_store_picker_test`; LAN smoke on iPhone 13 viewport |
| D1 | §24.7 Gün Sonu Raporu: 21:30 notification (configurable, deduped) + green/cream Yönetici report | Claude (cloud projection: Codex) | 🔄 LAN/Windows done: `lib/daily_report.dart` (exact-kuruş projection: Net = Brüt − İadeler, sales vs collections separate, open accounts, platform breakdown without invented settlement, estimate only when all deductions known, ön rapor while trading/open accounts, previous-day comparison only when final); event `daily:<day>` category `report.daily` (contract + mirror), generic text; Windows Ayarlar › Bildirimler › Gün Sonu Raporu (default 21:30, weekday + special-date/closed); `/api/yonetici/daily` (dashboard.view; amounts need sales.view + finance gate; expenses need finance.view); Yönetici report screen + Özet card + notification deep link, PDF/share. Remaining: cloud projection/push (Codex #39, N3). No staff hours in this report (owner decision 2026-11-27; hours live in weekly Mesai/payroll). **2026-11-28:** producer-field allowlist matrix posted on #46 (7230678865): the #46 RPC is a denylist with wrong key names and leaks `comparison`, `hourlyCents`, `orders.averageCents`, `orders.platforms[].grossCents/estimatedNetCents`, `openAccounts.dueCents`, `topProduct.cents`, `estimatedResultCents`; nested `staffHours` not rejected at ingest. Fix owned by #46; Windows `dailyReports` emitter waits for that fix | N1 | `daily_report_test` (7), `yonetici_api_test`; Playwright phone/dark/desktop render |
| W1 | §24.4 Vardiya (own planned shifts, shared schedule, no approvals) | Claude UI / Codex sync | 🔄 LAN done: `lib/workforce.dart` `shiftPlans` (own future plans, overnight, break, day off, bounded repeat ≤8 weeks, copy last week, confirmable own-overlap warning, manager edits audited), `/api/work/*`; Personel › Mesai › Vardiyalarım + Ekip programı (names/times only); Yönetici › Personel › Vardiya Planlama (view). Remaining: manager editing another person's plan in the UI, optional manual notification, Android/cloud (Codex) | — | `workforce_test` |
| W2 | §24.4 Mesai (own actual hours, manual only) + weekly Taslak/Gönderildi submission | Claude UI / Codex sync | 🔄 LAN done: manual records in `shifts` (source `manual`; past days, break, no future/overlap, edits keep previous values, void with reason), `timesheetWeeks` (Taslak / Gönderildi / Değişti / Çalışma yok, every snapshot kept); Personel › Mesai (week view, Mesai Ekle/Düzenle/İptal, Haftalık Mesailerimi Gönder, estimated earnings when hourly rate exists); Yönetici › Personel › Mesai Takibi. Existing Mesai Başlat/Bitir kept (explicit, user-operated). Remaining: Windows screen, Android/cloud (Codex) | W1 | `workforce_test` (8); Playwright phone smoke |
| W3 | §24.5 Hourly rates with effective dates + payroll payment ledger (Nakit/Havale/Karma, derived status) | Codex ledger / Claude UI | 🔄 Windows/LAN done: `lib/payroll.dart` (`employees[].payHistory` effective-dated rates, kuruş earnings rounded once per week, missing rate = incomplete not 0, `finance.payrollPayments` append-only ledger with Avans and audited reversal `pr_<id>`, `finance.payrollReviews` explicit Ödenmedi; legacy `weeklyPayroll` weeks refuse ledger rows so nothing is double counted); finance summary + PDF include ledger payroll; Personel › Mesai shows own Kazanılan/Ödenen/Kalan. Remaining: Android/cloud projection of the ledger (Codex), Windows payroll screen | W2 | `payroll_test` (8) |
| W4 | §24.6 Haftalık Maaş Ödemeleri panel + Sunday/Monday reminders | Claude | 🔄 LAN done: Yönetici › Personel › Haftalık Maaş Ödemeleri (Ödeme Kaydet Nakit/Havale/Karma/Avans, Düzelt with reason, Ödenmedi, Ücret), persistent Özet warning until every status is resolved; `lib/payroll_reminders.dart` Sunday 18:00/21:30 own-week reminders, payday 09/14/20 then daily 09:00, stable ids, generic lock-screen text, `personal` category scoped by `recipientEmployeeId`. Remaining: Windows reminder-time settings, FCM push (not approved) | W2, W3, N1 | `payroll_test`; Playwright phone smoke (partial → reverse → full) |
| Q1 | Cross-platform logic audit + QA matrix (owner mandates 2026-11-27 18:50/18:53) | Claude (Codex for sync/ledger rows) | 🔄 `docs/qa/FUNCTIONAL_QA_MATRIX.md`: 12 defects fixed in #44 (identity bound to session, owner excluded from payroll via `employees[].payrollEligible`, honest statuses Çalışma kaydı yok / Ücret belirlenmedi, reminders only for real outstanding pay, effective-dated Windows rate edits, no seeded names on fresh installs). Orders/payments/analytics/Android re-audit still open. D-46: hesap İptal vs Sil side by side with explanation; composer categories wrap | — | `payroll_test` (13), `lan_auth_gate_test`, `workforce_test`, `control_workflows_test`; Playwright synthetic scenarios |
| Q2 | Ayarlar information architecture + premium redesign + settings audit on all platforms (relayed by ChatGPT on #44 comment 7222677347; owner confirmed all relayed instructions 2026-11-27 20:07) | Claude (Codex for shared config/sync contracts) | 🔄 Windows step 1 done: grouped navigation (Genel Bakış; İşletme: Personel, Kullanıcılar & Güvenlik, Telefon Bağlantısı; Operasyon: Yazıcı & Fiş, Bildirimler & Sesler, Entegrasyonlar, Menü & QR; Sistem: Yedekleme & Geri Yükleme) with settings search; only existing, working settings are listed (no Bulut & Senkronizasyon page until Codex's sync UI exists). Step 2 done: settings inventory (`docs/qa/SETTINGS_INVENTORY.md`). Step 3 done on Android: Yönetici Ayarlar grouped (Hesap, Bağlantı, Görünüm, Windows’ta yönetilenler, Bu cihaz) and Personel Daha Fazla (Çalışmam, Hesabım, Bağlantı). Browser PIN change added with a server-side password re-check | Q1, #39 | branch `claude/project-thread-51u0i4` |
| M1 | QR Menü Yönetimi: Windows fix + premium redesign (ChatGPT relay 7226893412), then phones/browser (relay 7226917068) | Claude | 🔄 Windows done: root cause was the page treating an unreachable publisher as "offline" without saying why, and forcing "unpublished changes" on every restored draft. Now: diagnostics (key saved → `/health` on 127.0.0.1:18787 → GitHub catalog), a derived state (Yüklenmedi / Bağlanıyor / Çevrimdışı taslak / Yayındakiyle aynı / Yayın bekliyor / Çakışma var / Yayınlanıyor / Sonuç bilinmiyor) with one primary action each, real diff count, three-way merge of an old draft onto newer GitHub data with explicit per-field conflict choice (no silent overwrite), publish only when validated + revision-bound + changed + connected, a lost answer is persisted (`qrPublisherPendingPublish`) and reconciled against GitHub before any retry, Turkish money, compact rows + edit drawer. Tests: `qr_menu_draft_test` (9), `qr_menu_management_test` (10, fake publisher). Phones done too (D-37): Personel/Yönetici native + browser edit the shared draft over `/api/menu/*` with server-side `menu.*` grants, stale-draft refusal and audit. Parity done (D-38, relay 7226936601 / QA-18): all `menu.*` incl. publish are Personel/Müdür/Yönetici defaults (contract, Windows upgrade, migration `20261127221000`); phones review → confirm → Windows publishes with its own key, verify lost answers, upload photos, POS sync. **Owner (physical):** start the publisher on the Windows PC and save the key; no real publish was made | — | branch `claude/project-thread-51u0i4` |
| M2 | Windows transport for the cloud QR publisher (#49) | Claude (Windows/UI), ChatGPT (#49 Edge), Gemini/Codex (#46 enqueue/lease) | 🔄 `lib/qr_publish_transport.dart` (a63dd55): local + cloud transports, router with no fallback after an ambiguous write, 5xx = unknown (bug fixed). Agreed 7230811119: `draftSha256` (64 hex of exact UTF-8 `draftJson`) + `expectedStamp` = first 16, both in `commandPayload()`; recovery payload exactly `qrRecoveryPayload(target, mode)`; lease always backend-issued per command. **Cloud stays disabled** (not wired to UI) until the dispatcher accepts `draftSha256`, Windows-origin commands are leased via #46/#39, and both local and remote origins are supported | #46, #49 | `qr_publish_transport_test` (11) |
| T1 | Portable Trendyol credentials in owner backup/restore (relay 7230877753) | Claude | ✅ code + tests: format-2 backup section, allowlist, DPAPI re-wrap on restore, keep-existing, set-aside, baseline poll; UI status. Owner physical second-PC test pending (D-47). **Owner decision 2026-11-28 00:31Z:** keep this interim path until the server-side Trendyol proxy is verified; remove the backup section in the cutover change | — | `integration_secrets_test` (8), `docs/cloud-sync/backup-restore.md` |
| T2 | Trendyol Cloud Proxy v1 Windows client (#50 contract) | Claude (Windows), ChatGPT (#50 Edge), Gemini/Codex (authority/receipts) | 🔄 **disabled** (`NOHUT_TRENDYOL_CLOUD_PROXY` build flag off): `lib/trendyol_transport.dart` exact v1 envelopes (verify/poll/execute/reconcile), `x-nohut-agent-token` only, https fixed path, 2 MB response cap, status-only verify, poll pages limited to the fields `normalizeTgoPackage` reads, execute ambiguity = unknown (never retried). `TrendyolSourceMode` (`settings.trendyolSource {mode, epoch}`) gives one polling path; `TrendyolGoReadonly` never polls locally when cloud is the authority. Local DPAPI integration unchanged | #50, #39/#46 | `trendyol_transport_test` (7) |
| UX0 | Premium UI/UX release gate on every surface (relay 7227699704) | Claude (design + implementation), Antigravity (visual/accessibility audit) | 🔄 Inventory + design system: `docs/design/PREMIUM_UI_INVENTORY.md`. Visual acceptance (owner + Antigravity) tracked separately from functional tests. Done so far: Windows QR Menü redesign (review pending), Personel Ana Sayfa (owner chose A "Özet kartı"), Android Mesai/Yönetici/Ayarlar redesign (review pending). Next: shared components, then Masalar / order / payment on Windows and Personel | — | branch `claude/project-thread-51u0i4` |
| W5 | §24.3 Ana Sayfa dashboards (Personel, Yönetici) + personal performance | Claude | 🔄 Personel Ana Sayfa A ✅ (owner). **Performansım** (LAN + Android): `lib/personal_performance.dart` + `GET /api/work/performance?range=day|week|month` (session employee only): own orders (first-batch owner), Masa/Gel-Al, additions on any order, own sales total and average, open/cancelled, worked minutes from own Mesai; collections not attributed (payments are recorded by the till) and said so; platform orders excluded. Android `performance_page.dart` from Daha Fazla › Çalışmam. **Ekip Performansı** (Yönetici): `teamPerformance()` reuses the same rules so each row equals that person's Performansım; older orders without `staffId` shown once as *Atanmamış*; owner channel `ownerTeamPerformance` (Android Yönetici › Personel › Ekip Performansı, tap a person for details) and LAN `GET /api/yonetici/team-performance` (`staff.view`; amounts only with finance gate + `sales.view`). Remaining: cloud projection, `/yonetici` browser card | W1–W3 | `personal_performance_test` (4), `workforce_test` endpoint, `yonetici_api_test` (team gate), `performance_page_test` (3), `team_performance_page_test` (3 incl. light/dark render) |
| W6 | §24.2 Activation invites, pending approval, 5-digit trusted-device PIN | Claude (cloud: A2) | 🔄 **Local ✅**: Windows › Kullanıcılar creates staff *Aktivasyon koduyla* (default) or issues a new code from the menu; code `XXXX-XXXX` shown once, PBKDF2 verifier only, 72 h, 5 tries, issuing = reset (old password/sessions end). LAN `POST /api/auth/activate` (throttled) sets own password + this device's 5-digit PIN and signs in. Android Personel: login sheet › *İlk kez mi? Aktivasyon kodum var* › 3-step Hesabımı Etkinleştir. LAN browser Personel page: *İlk kez mi? Aktivasyon kodum var* mode on the sign-in card (Playwright-checked: code formatting, refusal message, sign-in). Remaining: cloud invites (A2) | A2 (cloud only) | `local_accounts_test` (activation, expiry/5 tries), `lan_auth_gate_test` (route + cookie), `accounts_ui_test` (pending + menu), `activation_page_test` (4 incl. light/dark render) |
| P6 | Windows sales/top products/heatmap projections (Phase 6) | open | 🔄 Heatmap ✅ (Claude): `lib/demand_view.dart` reuses Windows Raporlar › Yoğunluk counts (weekday × Istanbul hour, cancelled excluded) for week / last 4 weeks / month; owner channel `ownerDemand`, LAN `GET /api/yonetici/demand` (`dashboard.view`, counts only); Android Yönetici › Raporlar › *Yoğunluk · Gün ve Saat* and Ana Sayfa *Saatlik yoğunluk › Haftalık*. **Satış Analizi ✅** (Claude): `lib/sales_view.dart` from the same `ledger`/`sales`/`ReportActivity` rows as Windows Raporlar: per-day Masa/Gel-Al cash, card, refunds, net, order counts; top 10 products; delivered online totals; owner channel `ownerSales`, LAN `GET /api/yonetici/sales` (`sales.view` + finance gate); Android Yönetici › Raporlar › *Satış Analizi*. Remaining: cloud projection ; tests `sales_view_test` (2), `yonetici_api_test`, `sales_page_test` (4) | — | `demand_view_test` (2), `yonetici_api_test`, `demand_page_test` (4 incl. light/dark/compact render) |
| P7 | Phase 7 acceptance incl. spec §23.7 | all | ⏳ | all | — |

**Blockers / owner actions:** live Trendyol read-only check needs explicit owner authorization (R1); physical iPhone HTTPS/Safari test (L4); any FCM project needs owner approval (N4); KVKK gate unchanged.

## Antigravity (Gemini) Backend — Increment E: Standalone Platform Yönetimi Control Plane (2026-11-28)

- **Branch / PR:** `gemini/backend-continuation` (**PR #46** targeting `main`).
- **Status:** `Implemented / Tested` (NOT self-verified; independent review requested from Claude).
- **Implemented (`supabase/migrations/20261128030000_nohut_platform_management.sql`, `docs/contracts/v1/platform-management.md`):**
  1. **Idempotent `platform.*` permissions:** `platform.view`, `platform.store.toggle`, `platform.schedule.edit`, `platform.catalog.toggle` mirrored in `docs/contracts/v1/permissions.json` and `flutter_desktop/lib/permission_roles.g.dart` (byte-for-byte compatible with PR #51 `20261128020000`).
  2. **Authoritative Read Model (`public.nohut_platform_cards_view`):** Requires `platform.view`, returns all 3 providers in fixed order (`trendyol_go`, `yemeksepeti`, `migros_yemek`) matching `PlatformCard.fromJson` field-for-field.
  3. **Durable Idempotent Store `Aç/Kapat` (`public.nohut_platform_enqueue_status_set`):** Requires `platform.store.toggle` + `p_confirmed = true`; enforces connected + `can_toggle_store`, verified store ID, ≤10 min fresh readback, no pending/unknown mutation in flight, and `expectedStatus == working_status`; enqueues `platform_store_status_set` (5m TTL) in `nohut_private.commands`; locks `pendingMutation`; appends to immutable `platform_status_audit`.
  4. **Read-Only Refresh & Unknown-Outcome Reconciliation:** `public.nohut_platform_enqueue_refresh`, `public.nohut_platform_enqueue_reconcile`, and Windows-agent RPCs `public.nohut_agent_report_platform_state` & `public.nohut_agent_resolve_platform_mutation`.
- **Validation (synthetic data only):**
  - Local Docker Postgres 16 (exact CI harness): **66/66 migrations & 33/33 SQL test suites PASS** under both `postgres` superuser and `cloud_migrator` (`NOSUPERUSER NOBYPASSRLS`).

## Antigravity (Gemini) Backend — Increment D Clean Resync & Canonical JSON Contract (2026-11-28)

- **Branch / PR:** `gemini/backend-continuation` (**PR #46** draft targeting `chatgpt/pr-05b-cloud-rpcs`).
- **Status:** `Implemented / Tested` (NOT self-verified; independent re-review requested from ChatGPT & Claude).
- **Resolves Claude #7235779939 (1 blocking + 2 medium + 1 note) via `supabase/migrations/20261127174000_nohut_initial_sync_clean_resync.sql`:**
  1. **Blocking #1 (Canonical JSON for snapshot payloads):** Confirmed strict **integer-only canonical JSON** (`nohut_private.canonical_command_json`: safe integers in `[-9007199254740991, 9007199254740991]`, no floats/exponents, UTF-8 byte-ordered object keys, no whitespace, Postgres string escaping, no keys > `U+FFFF`) documented in `docs/contracts/v1/initial-sync-and-recovery.md`.
  2. **Medium #1 (Clean projection replacement on resync):** Added private `nohut_private.clear_restaurant_projections(uuid)` invoked inside `nohut_agent_activate_initial_sync` before promoting staged batches (within the same transaction) so rows deleted locally on Windows are cleanly removed instead of surviving as ghosts after a second full sync.
  3. **Medium #2 (`statement_timeout` on activation):** `nohut_agent_activate_initial_sync` now sets `set local statement_timeout = '120s'` deterministically for large staged promotions.
  4. **Note (Orphaned staged batches on epoch rotation):** `nohut_owner_rotate_authority_epoch` now purges any orphaned `migration_staged_batches` and marks incomplete old-epoch `sync_migrations` as `'safely_aborted'` (`abort_reason = 'epoch_rotated'`).
- **Validation (synthetic data only):**
  - Local Docker Postgres 16: **61/61 migrations & 32/32 SQL test suites** (including Epoch 1 → Epoch 3 clean replacement and orphaned staged-batch purge tests) executed under both `postgres` superuser and `cloud_migrator` (`NOSUPERUSER NOBYPASSRLS`).

## Antigravity (Gemini) Backend — Increment D Hardening: Claude #7231808318 Blockers Fixed (2026-11-28)

- **Branch / PR:** `gemini/backend-continuation` (**PR #46** draft targeting `chatgpt/pr-05b-cloud-rpcs`).
- **Status:** `Implemented / Tested` (NOT self-verified; independent re-review requested from ChatGPT & Claude).
- **Resolves all 4 blocking + 3 minor findings (`supabase/migrations/20261127173000_nohut_initial_sync_hardening.sql`):**
  1. **Blocking #1:** `nohut_agent_activate_initial_sync` explicitly rejects `NULL` or negative `p_expected_batches` (`22023`).
  2. **Blocking #2:** `nohut_agent_upload_snapshot_batch` enforces `jsonb_array_length(p_events) = p_item_count` and `sha256(utf8(canonical_command_json(p_events))) = p_body_sha256`. Activation recomputes `manifest_sha256 = sha256(string_agg(category||':'||batch_id||':'||item_count||':'||body_sha256, '\n' order by batch_id::text))` and requires exact match against both stored and expected manifest.
  3. **Blocking #3 (Stage + Promote):** `upload_snapshot_batch` stages verified events in private `nohut_private.migration_staged_batches` (ZERO writes to live projection tables before activation). `abort_initial_sync` purges all staged batches and stores/audits `abort_reason`. `activate_initial_sync` atomically promotes all staged batches in dependency order in one transaction and purges staged payloads.
  4. **Blocking #4 (Second Full Sync / "Yeniden eşitle"):** Added owner-only, `aal2` MFA, Windows-only `public.nohut_owner_rotate_authority_epoch(p_device_id, p_permission_version, p_reason)` (`sync.full_resync`), which retires the old epoch, revokes old-epoch Windows agents, creates a fresh epoch, and audits it.
  5. **Minor #1–#3:** Batch capped at ≤500 events / ≤4 MB; `abort_reason`/`aborted_at` stored & audited; `migration_status` cross-epoch semantics documented in `docs/contracts/v1/initial-sync-and-recovery.md`.
  6. **Compatibility (`expenses.quick_add`):** Confirmed PR #46 does not duplicate PR #44's `20261128010000_nohut_expenses_quick_add.sql` (`on conflict do nothing`).

## Antigravity (Gemini) Backend Ownership — Increment D: Initial Sync, Resumable Snapshots, Recovery & Strict QR Digest (2026-11-28)

- **Ownership Acknowledged (`#7231137435` / `#7231119516`):** Codex removed from active assignments (historical PR #39 `8d918b2` preserved untouched). Gemini owns remaining P0 Backend & Security on **PR #46 (`gemini/backend-continuation`)** and separate Independent QA on **PR #45 (`gemini/independent-qa`)**. ChatGPT reviews Gemini's backend work independently.
- **Status:** `Implemented / Tested` (NOT self-verified; independent review requested from ChatGPT).
- **Implemented (`supabase/migrations/20261127172000_nohut_initial_sync_and_strict_qr_digest.sql`):**
  1. **Strict QR Publish Digest (P0 checklist):** `qr_menu_publish` now **requires** full 64-hex `draftSha256` (prefix matching 16-hex `expectedStamp`); omitting `draftSha256` is rejected (`22023`).
  2. **First Database Synchronization & Snapshot/Recovery RPCs (Windows-agent authenticated only):**
     - `public.nohut_agent_begin_initial_sync` (requires `p_backup_verified = true`, idempotent on `migration_id`, prevents concurrent active/uploading migrations per epoch).
     - `public.nohut_agent_upload_snapshot_batch` (atomic multi-entity typed batch ingestion + `migration_batches` recording, idempotent/resumable across crashes/offline drops).
     - `public.nohut_agent_activate_initial_sync` (verifies exact `manifest_sha256` and committed batch count before transitioning to `'active'` and initializing `sync_checkpoints`).
     - `public.nohut_agent_abort_initial_sync` (marks incomplete migration `'safely_aborted'`; refuses to abort `'active'`).
     - `public.nohut_agent_migration_status` (returns migration state, committed batches, and checkpoint for deterministic offline resume).
  3. Contract & tests: `docs/contracts/v1/initial-sync-and-recovery.md`, `supabase/tests/initial_sync_and_recovery_test.sql`.
- **Validation (synthetic data only):**
  - Local Docker Postgres 16: **59/59 migrations & 32/32 SQL test suites passed** under both `postgres` superuser and `cloud_migrator` (`NOSUPERUSER NOBYPASSRLS`).

## Antigravity (Gemini) temporary backend continuation — Hardening Pass: Privacy Allowlist, Provenance Freshness & QR v2 Reconcile Alignment (2026-11-28)

- **Branch / PR:** `gemini/backend-continuation` (**PR #46** draft targeting `chatgpt/pr-05b-cloud-rpcs`).
- **Status:** `Implemented / Tested` (NOT self-verified; independent re-review requested from ChatGPT / Codex & Claude).
- **Resolves review blockers `#7230391428`, `#7230501923`, `#7230678865`:**
  - `supabase/migrations/20261127171000_nohut_read_privacy_freshness_hardening.sql`:
    1. **Financial Privacy Allowlist (`public.nohut_daily_report_view`):** Enforces `p_client = 'yonetici'` + `dashboard.view`, constructs output strictly field-by-field matching Claude's `daily_report.dart` `redactDailyReport` matrix (`amountsHidden: true` without `sales.view`; all 12 monetary fields strictly absent without `sales.view`; `expenses`/`estimatedResultCents`/`estimateNote` absent without `finance.view`). Ingest rejects unknown top-level keys and rejects `staffHours`/`workingHours`/`employeeHours` at **any nesting depth**.
    2. **Provenance-Bound Stale Metadata (`nohut_private.projection_watermarks` + `projection_freshness`):** Tracks `(restaurant_id, projection_key, authority_epoch, source_revision, calculated_at, updated_at)` across all 5 projections (`workforce_summaries`, `shift_plans`, `qr_menu_state`, `notifications`, `daily_reports`), detecting `no_sync`, `sync_aged`, `projection_missing`, `epoch_mismatch`, `revision_ahead`, and `projection_aged`. Forces `preliminary: true` on stale daily reports.
    3. **Full `unreadCount`:** `public.nohut_notifications_list` computes `unreadCount` across ALL visible unread items (independent of `p_limit`).
    4. **QR Recovery & Digest Alignment (`#7230501923` / Claude `aea2861`):** `qr_menu_reconcile` enforces exact `{targetRequestId: UUID, mode: 'reconcile' | 'cancel_before_attempt'}` and denies legacy `{}`; `qr_menu_publish` supports optional `draftSha256` (64-hex) validated against `expectedStamp` (first 16 hex).
- **Validation (synthetic data only):**
  - Local Docker Postgres 16: **58/58 migrations & 31/31 SQL test suites passed** under both `postgres` superuser and `cloud_migrator` (`NOSUPERUSER NOBYPASSRLS`).

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

### Owner-approved QR settings consolidation (2026-11-28)

- ChatGPT — PR #47 (stacked on #44): **Implemented / CI pending**. Removed duplicate Ayarlar > Menü & QR navigation and product list. QR Menü Yönetimi owns the POS sync status, last successful check, Eşitleme Ayarları and Şimdi Eşitle; local-only prices remain editable only with auto-sync disabled. Existing auto-sync service, historical order snapshots and public QR publication are unchanged. Added widget regression. Claude to integrate after CI; Gemini to independently verify. No production data or public menu edits.

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
| Phase 5B: cloud command-queue RPCs (`nohut_private.commands`, claim with lease, complete) + Increments A–E (Workforce/Payroll, QR Menu Cloud, Notifications & Daily Report, Clean Resync, Platform Yönetimi, atomic claim read & expired-lock reap) | Gemini / Antigravity (`Implemented / Tested`, 7/7 CI GREEN, awaiting Claude independent review) | 2026-11-28 | #46 (`659267b`) |
| Trendyol Cloud Proxy v1 (Edge Function: `verify`, `poll`, `execute` Kabul Et/Hazır, `reconcile`, `store_status_read`, `store_status_set` Aç/Kapat; Supabase Secrets; disabled by default) | Gemini / Antigravity (`Implemented / Tested`, 5/5 CI GREEN, B1–B4 & N1–N4 fixed, awaiting Claude re-review) | 2026-11-28 | #52 (`f35f796`) |
| Cloud QR Publisher v2 (Edge Function: GitHub App via Supabase Secrets, 64-hex `draftSha256` binding, `NOHUT_QR_PUBLISHER_ENABLED` gate, `qr-publisher-check` read-only verifier) | Gemini / Antigravity (`Implemented / Tested`, 4/4 CI GREEN, awaiting Claude independent review) | 2026-11-28 | #53 (`eeda48f`) |
| Cloud Capabilities v1 (`GET`/`POST /functions/v1/cloud-capabilities`: tenant-scoped booleans for `qrPublish` + `providers.{trendyol_go,yemeksepeti,migros_yemek,uber_eats}`, fail-closed, zero secret material) | Gemini / Antigravity (`Implemented / Tested`, 7/7 synthetic tests PASS, CI GREEN; Windows client wired by Claude on #51 `7bedb7c`) | 2026-11-28 | #46 (`61b6743`) |
| Manual Edge Function Deploy & Safe Read-Only Verify Workflow (`nohut-supabase-edge-deploy-verify.yml`: `workflow_dispatch` only, disabled-by-default deploy + read-only `cloud-capabilities`/`trendyol-proxy verify`/`qr-publisher-check`) | Gemini / Antigravity (`Implemented / Tested`, awaiting Claude independent review & owner trigger) | 2026-11-28 | #46 |
| Phase 6: Cloud Sales Analytics Projection (`SalesView`: `sales_analytics_snapshots`, `nohut_agent_report_sales_analytics`, `nohut_sales_analytics_view` gated on `sales.view` for `daily`, `topProducts`, 7×24 `heatmap`, `platforms`) | Gemini / Antigravity (`Implemented / Tested`, 68/68 migrations & 34/34 SQL tests PASS, awaiting Claude independent review) | 2026-11-28 | #46 |
| Phase 5 prerequisite: Windows shift entity + clock-in/out commands | Claude Code | done | #38 |
| PR-05B: server RPCs (ingest transaction, reconcile, checkpoint), typed serializers, minimal grants | Gemini / Antigravity (merged into #46, 68/68 migrations & 34/34 SQL tests PASS) | 2026-11-28 | #46 |

## Owner-configured services (2026-11-27, per owner)

| Service | Status |
|---|---|
| Supabase | `nohut-pos`, Free, eu-central-1 (Frankfurt). Project ref and URL in GitHub Secrets. **Migrations not yet applied to production.** |
| Cloudflare | Free; account ID and API token in Secrets. The Pages integration must be re-verified after the repository rename. |
| Android signing | JKS keystore + passwords in Secrets; verified by the "Verify Nohut Configuration" workflow. A full signed release build is still to run. |

**KVKK gate (spec §12.2):** no real personal data goes to Supabase until the owner confirms the legal review. All tests use synthetic data.
