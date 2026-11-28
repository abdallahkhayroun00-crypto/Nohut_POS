# Planned Vardiya projection — PR #39, synthetic tested, not deployed

Consumes Claude's `shiftPlans` event and existing `applyPlanCommand`. Planned
rows remain separate from actual `shifts`, submissions and payroll. The cloud
never converts a plan into attendance or creates an approval workflow.

Private typed `shift_plans` retain the existing source ID, employee identity
and historical label, calendar day, wall-time minutes, explicit next-day flag,
day off, break, note, cancellation, creation/update times and actor labels.
Private `shift_plan_history` preserves immutable audit ordinals, actor mapping
(nullable where the authoritative source records an unlinked manager), action
and the seven typed before-values for edits. Cancellations retain their audit
without fabricating a before snapshot that the Windows handler did not record.

Strict type/interval/date checks include overnight spans, 16-hour maximum,
valid breaks and day-off shape. Confirmed planned overlaps remain an existing
Windows decision. Duplicate/omitted records, changed history, stale revisions,
identity changes, unaudited edits and resurrecting cancellations fail before
the atomic transaction ACK. Repeat/copy records retain their own source IDs.

Employees ingest before plans. All tables have FORCE RLS with no direct
client-role grants. Future shared-schedule reads must expose only names/times;
another employee's notes or wage data require separate authorization. Employee
weekly summaries/read APIs and remaining PR #39 synchronization/runtime work
are still pending; no production activation is implied.
