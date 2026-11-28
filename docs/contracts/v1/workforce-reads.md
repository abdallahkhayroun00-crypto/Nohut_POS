# Authorized weekly workforce & payroll reads — `gemini/backend-continuation` (QA-09 / O-03)

Status: **Implemented & Synthetic Tested** (awaiting independent review by ChatGPT/Codex; not merged/deployed).

## Principles
- **Windows is the sole calculator.** `flutter_desktop/lib/cloud_workforce_summary.dart::serializeWorkforceSummaries` reuses Claude's authoritative `payrollStatus`, `ownWeek`, `payRateOn`, and `weekStartOf` functions — cloud SQL never recomputes wages independently.
- **No fabricated financial data.** Missing wages stay `null` (`Ücret belirlenmedi`), never `0`. Owner accounts with `payrollEligible = false` are excluded from `nohut_payroll_week` and see `payrollEligible: false` on their own week.
- **Gün Sonu Raporu remains untouched** and omits `staffHours`.

## Migrations (`20261127166000` – `20261127167000`)
- `20261127166000_nohut_workforce_summaries.sql`: Private `nohut_private.weekly_workforce_summaries` (`FORCE ROW LEVEL SECURITY`, revoked from all client roles) + `apply_workforce_summary_projection` + atomic `ingest_sync_transaction` support for `entity_type = 'workforceSummaries', entity_id = 'core'`.
- `20261127167000_nohut_workforce_read_rpcs.sql`: Three JWT-authenticated `SECURITY DEFINER` RPCs (granted only to `authenticated`), all checking verified `session_id`, `device_id`, `client`, and `permission_version`:
  1. `public.nohut_workforce_own_week(p_device_id, p_client, p_permission_version, p_week_start)` — requires `shifts.self` + linked `pos_employee_id`; strictly self-scoped; matches `/api/work/week` shape + `syncMeta` (`sourceRevision`, `calculatedAt`, `syncedAt`, `stale`, `staleReason`).
  2. `public.nohut_team_schedule(p_device_id, p_client, p_permission_version, p_from, p_to)` — requires `shifts.self`; returns shared team planned shifts (`employeeName`, `date`, `start`, `end`, `endsNextDay`, `dayOff`) ONLY — never wages, worked hours, or private notes.
  3. `public.nohut_payroll_week(p_device_id, p_client, p_permission_version, p_week_start)` — requires `payroll.view` (or owner); matches `ownerPayroll` shape (`weekStart`, `today`, `rows[]`, `payments[]`, `syncMeta`); retains departed employees with unpaid dues and excludes owner by default.
