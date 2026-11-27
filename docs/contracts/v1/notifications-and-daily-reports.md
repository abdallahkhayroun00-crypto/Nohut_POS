# Contract: Cloud Notifications & Gün Sonu Raporu (`v1`)

- **Owner:** Temporary Backend Continuation (`gemini/backend-continuation`, PR #46)
- **Migration:** `supabase/migrations/20261127170000_nohut_notifications_and_daily_reports.sql`
- **Status:** `Implemented / Tested` (pending independent review by ChatGPT / Codex)

## Invariants

1. **Owner Decision (`QA-05` permanently superseded):** `nohut_private.daily_report_summaries` and `apply_daily_report_projection` strictly reject any `staffHours` or `workingHours` fields. Working hours live exclusively in weekly Mesai & Haftalık Maaş Ödemeleri (`workforce-reads.md`).
2. **Permission-scoped visibility:**
   - `public.nohut_daily_report_view` requires `dashboard.view`; monetary sales/collections/platforms require `sales.view`; expenses & net profit estimate require `finance.view`.
   - `public.nohut_notifications_list` filters by `allowed_clients`, `required_permission`, and personal `recipient_employee_local_id` (`u.pos_employee_id`).
   - `public.nohut_notification_mark_read` records per-user read state in `nohut_private.notification_reads` without affecting other users.
3. **Zero direct client table access:** All 3 tables have `FORCE ROW LEVEL SECURITY`, owner-only policies, and zero grants to `public`, `anon`, `authenticated`, or `service_role`.
