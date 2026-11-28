# Platform Yönetimi — Cloud Control Plane Contract (v1)

- **Migration:** `supabase/migrations/20261128030000_nohut_platform_management.sql`
- **Tests:** `supabase/tests/platform_management_test.sql`
- **Client Alignment:** `packages/nohut_core/lib/platform_status.dart` (`PlatformCard.fromJson`) & `flutter_desktop/lib/platform_management.dart` (`PlatformControl`) on PR #51 (`5d86127`, `31b304d`)
- **Status:** `Implemented / Tested` (pending independent review by Claude)

## Permissions (Separate Grants)
Seeded idempotently (`on conflict do nothing`, compatible with PR #51 `20261128020000`):
- `platform.view` — view standalone **Platform Yönetimi** + `Ana Sayfa` quick widget + read-only refresh/reconcile.
- `platform.store.toggle` — open/close restaurant on an online platform (`Aç/Kapat`, explicit confirmation required).
- `platform.schedule.edit` — update working hours (separate future grant).
- `platform.catalog.toggle` — toggle provider product/category availability (separate future grant; never touches local POS/QR).

## Verified Official Trendyol GO Meal Endpoints (`developers.tgoapps.com`)
- **Readback:** `GET https://api.tgoapis.com/integrator/store/meal/suppliers/{supplierid}/stores?page={page}&size={size}`
- **Store Status (`Aç/Kapat`):** `PUT https://api.tgoapis.com/integrator/store/meal/suppliers/{supplierid}/stores/{storeId}/status` with `{"status": "OPEN"}` or `{"status": "CLOSED"}` (no timed pause / busy mode in official API).
- **Yemeksepeti & Migros Yemek:** Honest `not_connected` / `UNKNOWN` cards until official partner contracts & credentials are authorized.

## RPCs

### 1. `public.nohut_platform_cards_view(p_device_id, p_client, p_permission_version)` (`authenticated`, `platform.view`)
Returns `{ "cards": [ ... ], "syncMeta": ... }` with all 3 providers in fixed order (`trendyol_go`, `yemeksepeti`, `migros_yemek`). Each card matches `PlatformCard.fromJson` field-for-field (`provider`, `connectionState`, `workingStatus`, `verifiedStoreId`, `verifiedStoreName`, `lastVerifiedAt`, `scheduleState`, `workingHours`, `pendingMutation`, `auditHistory`, `capabilities`, `note`).

### 2. `public.nohut_platform_enqueue_status_set(...)` (`authenticated`, `platform.store.toggle`)
Durable idempotent command (`nohut_private.commands`, `action_type = 'platform_store_status_set'`, 5 min TTL):
- Enforces `p_confirmed = true`, `p_target_status <> p_expected_status`, `connection_state = 'connected'`, `can_toggle_store = true`, `verified_store_id` present, `last_verified_at >= now() - 10 minutes` (matching `platformStatusFreshFor`), `pending_request_id is null`, and `working_status = p_expected_status`.
- Returns `{ "status": "accepted" | "duplicate" | "conflict", "request_id": ... }`.
- Atomically locks `pendingMutation` (`pending`) and appends a `'pending'` row to `platform_status_audit`.

### 3. `public.nohut_platform_enqueue_refresh(...)` & `public.nohut_platform_enqueue_reconcile(...)` (`authenticated`, `platform.view`)
- `refresh`: read-only provider verification (`platform_store_status_refresh`).
- `reconcile`: readback-only reconciliation (`platform_store_status_reconcile`) permitted only when `pending_request_id = p_target_request_id` and `pending_outcome = 'unknown'`. Never retries mutation.

### 4. `public.nohut_agent_report_platform_state(...)` & `public.nohut_agent_resolve_platform_mutation(...)` (`anon` + scoped Windows agent token)
- `report_platform_state`: upserts verified readback state & `workingHours` without prematurely clearing an active `unknown` pending mutation.
- `resolve_platform_mutation`: records `confirmed` / `unknown` / `failed` / `rejected`, updates `working_status` + `last_verified_at` when verified, keeps `pending_outcome = 'unknown'` locked on ambiguous responses, and appends an immutable audit row to `platform_status_audit`.
