# Contract: Cloud Notifications & Gün Sonu Raporu (`v1`)

- **Owner:** Temporary Backend Continuation (`gemini/backend-continuation`, PR #46)
- **Migrations:**
  - `supabase/migrations/20261127170000_nohut_notifications_and_daily_reports.sql`
  - `supabase/migrations/20261127171000_nohut_read_privacy_freshness_hardening.sql`
- **Status:** `Implemented / Tested` (pending independent review by ChatGPT / Codex)

## Invariants

1. **Owner Decision (`QA-05` permanently superseded):** `nohut_private.apply_daily_report_projection` rejects `staffHours`, `workingHours`, and `employeeHours` at **any nesting depth** (`contains_forbidden_daily_report_key`), and rejects any unknown top-level key outside Claude's `buildDailyReport` schema (`daily_report.dart`).
2. **Strict Field-by-Field Financial Privacy Allowlist (`public.nohut_daily_report_view`):**
   - Requires `p_client = 'yonetici'` AND `dashboard.view`.
   - **Counts-only (`dashboard.view`, no `sales.view`):** emits `businessDate`, `generatedAt`, `closingTime`, `closed`, `preliminary`, `preliminaryReason`, `orders.{total,masa,gelAl,online,cancelled,platforms[].{source,orders}}`, `openAccounts.count`, `topProduct.{name,qty}`, `peakHour`, and **`amountsHidden: true`**. All monetary fields (`sales`, `comparison`, `hourlyCents`, `orders.averageCents`, `orders.platforms[].grossCents`, `orders.platforms[].estimatedNetCents`, `collections`, `openAccounts.dueCents`, `topProduct.cents`, `expenses`, `estimatedResultCents`, `estimateNote`) are strictly **absent**.
   - **Sales (`dashboard.view` + `sales.view`, no `finance.view`):** adds `sales`, `comparison`, `hourlyCents`, `orders.averageCents`, `orders.platforms[].{grossCents,estimatedNetCents}`, `collections`, `openAccounts.dueCents`, `topProduct.cents`. `expenses`, `estimatedResultCents`, `estimateNote` remain **absent**.
   - **Full (`sales.view` + `finance.view`):** adds `expenses`, `estimatedResultCents`, `estimateNote`.
3. **Provenance-Bound Stale Metadata (`nohut_private.projection_watermarks` & `projection_freshness`):**
   - Every read RPC binds `syncMeta` to the active `authority_epoch`, `sync_checkpoints.last_acked_revision`, and per-projection watermark (`workforce_summaries`, `shift_plans`, `qr_menu_state`, `notifications`, `daily_reports`), surfacing `no_sync`, `sync_aged`, `projection_missing`, `epoch_mismatch`, `revision_ahead`, or `projection_aged`.
   - Whenever `syncMeta.stale = true`, `nohut_daily_report_view` forces `preliminary = true`.
4. **Full `unreadCount` & Scoped Notifications (`public.nohut_notifications_list` / `mark_read`):**
   - Filters by `allowed_clients`, `required_permission`, and personal `recipient_employee_local_id`.
   - `unreadCount` counts **all** visible unread notifications for the caller, regardless of `p_limit` page size.
