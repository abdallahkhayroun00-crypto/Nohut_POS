# Nohut POS 2.0 — Shared Progress & Coordination

The **single shared status board** for every agent (Claude Code, ChatGPT automation) and the owner. Update it in the same PR as the work it describes.

Repository: `abdallahkhayroun00-crypto/Nohut_POS` (renamed from `brand-management-proposal`; same repository ID).

## Rules (all agents)

1. **Fetch first.** Before each iteration, read `main`, the open PRs and their latest CI, and this file.
2. **One branch per agent; never push to another agent's branch.**
   - Claude Code: `claude/inspiring-mccarthy-t5ywuv`.
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

## Phase status

| Phase | Status | Evidence |
|---|---|---|
| 0 Audit and baseline | ✅ merged (#31) | `phase-0-report.md` |
| 1 Encrypted backup and restore | ✅ merged (#32) | `backup-restore.md`; physical second-PC restore pending (owner) |
| 1B Per-entity tables, soft delete, no ceiling | ✅ merged (#33) | `storage-benchmark.md` (before/after, 1k–100k) |
| 2 PR-04 Transactional outbox | ✅ merged (#34, ChatGPT) | `test/sync_outbox_transaction_test.dart` |
| 2 PR-05A PostgreSQL foundation (private schema, deny-all RLS) | ✅ merged (#35, ChatGPT) | `supabase/tests/*`, `nohut-postgres-foundation.yml` |
| 2 PR-05B Ingest/reconcile RPCs, typed serializers, client grants | 🔄 PR #39: private validator CI green (45969097410); employee-only atomic ingest + checkpoint CI green (45969330484); other typed projections, snapshot and reconcile still open | `supabase/migrations/20261127123000_nohut_employee_ingest.sql`, `supabase/tests/employee_ingest_test.sql` |
| 2 PR-06 SyncWorker (client) | ✅ merged (#37) | `lib/sync_worker.dart`, `test/sync_worker_test.dart` (fake server with #35 rules) |
| 2 PR-06 first-sync wizard + Bulut & Senkronizasyon UI + Supabase transport | ⏳ needs PR-05B RPCs | — |
| 3A Auth control plane in PostgreSQL (users ↔ employees, role templates, per-user grants, devices, sessions, PIN verifier, audit, `authorize()` / `command_actor()` / owner admin functions) | ✅ merged (#40, Claude). Tested locally on PostgreSQL 16 as superuser **and** as a plain owner without BYPASSRLS; PR-05A tests still pass with it applied | `supabase/migrations/20261127005000_nohut_auth_control_plane.sql`, `supabase/tests/auth_control_plane_test.sql`, `.github/workflows/nohut-auth-control-plane.yml`, `tools/permission_catalogue_sql.py` (DB catalogue = contract) |
| 3B Login BFF / Edge Function (username → provider identifier, rate limit, generic errors), PWA + Android login, PIN unlock, owner MFA | ⏳ Claude, after 3A | — |
| 3C Windows owner UI: Kullanıcılar & Yetkiler, Bağlı Cihazlar, Tüm Oturumları Kapat | ⏳ Claude | — |
| 4 PWA — functional Personel + Yönetici clients (§22), Bulut/Yedek removed, Cloudflare Pages deploy | ✅ merged (#37); live at https://nohut-personel.pages.dev and https://nohut-yonetici.pages.dev. Screens built on the Windows projection shapes; **live data waits for PR-05B + Phase 3 login**, writes wait for the Phase 5 command channel | `pwa/src/{personel,yonetici}/app.ts`, `pwa/test/shared.test.ts` (28 tests), labelled synthetic preview `npm run build:fixtures` |
| 4 Android Personel/Yönetici on cloud transport | ⏳ needs Phase 3 auth | — |
| 5A Windows command worker (envelope checks, Windows-only refusal, grants, hash, expiry, idempotent receipts) | 🔄 PR open (Claude) | `flutter_desktop/lib/remote_commands.dart`, `test/remote_commands_test.dart` (18), `lib/permission_catalogue.g.dart` (+ drift test) |
| 5B Cloud command queue RPCs (`claim`/`complete`, lease, server envelope with actor + grants) | 🔄 private lease/complete primitives; private SQL CI green (45969330484); private auth-aware enqueue CI green (45969681887); claim-time reauthorization implemented; latest CI pending; scoped transport still blocked | `supabase/migrations/20261127121000_nohut_command_queue.sql`, `supabase/tests/command_queue_test.sql` |
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

- **Claude owns** the migration `…005000_nohut_auth_control_plane.sql` (PR #39 uses distinct versions `20261127121000`–`20261127123000`; no dependency on them) and the tables it creates in `nohut_private`: `app_users`, `operation_catalogue`, `user_grants`, `devices`, `sessions`, `security_audit`. **ChatGPT's** `…001000` / `…002000` migrations and `nohut-postgres-foundation.yml` are not modified; Phase 3A has its own workflow that applies all three migrations in order.
- **Every PR-05B RPC that reads or writes for an app user must first call**
  `nohut_private.authorize(p_user_id uuid, p_session_id uuid, p_device_id uuid, p_client text, p_operation text, p_permission_version bigint) returns text`
  and continue only on `'ok'`. Other results (`unknown_user`, `inactive`, `session_revoked`, `device_revoked`, `stale_permissions`, `windows_only`, `client_not_allowed`, `forbidden`, `unknown_operation`) map to a generic 403 with the code in the body. `p_user_id` is `auth.uid()` in the API wrapper — never a client-supplied value.
- **Remote command envelopes** (Phase 5A, `flutter_desktop/lib/remote_commands.dart`) take `actor` from
  `nohut_private.command_actor(p_user_id uuid) returns jsonb` → `{employee_id, is_owner, grants[], permission_version}`; the server adds `client`, `issued_at`, `expires_at`, `payload_sha256` (canonical JSON, sorted keys).
- `sync.*` / `backup.*` are Windows-only: `authorize()` returns `windows_only` for every remote client, including the owner (§22.3).
- Restaurant scoping: every control-plane row carries `restaurant_id`; `authorize()` resolves the user's restaurant itself — RPCs must not trust a client-sent restaurant id.
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
