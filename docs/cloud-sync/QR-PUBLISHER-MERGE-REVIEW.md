# Independent source review — 2026-11-28

Status: **MERGE HOLD**, not a comprehensive security certification.

## Verified CI and dependency chain

| PR | Reviewed head | CI | Decision |
| --- | --- | --- | --- |
| #39 | 8d918b23b965dbf5b9c100115ec289f891eb949c | 7/7 workflows green | Draft/release gates still open |
| #46 | 3fb60e927c16c5601c07a1c3545d7cde69230306 | 5/5 green | Independent source-review blockers below |
| #49 | 47c6730b301e3a556f94d171feedd29291b7a6dd | 5/5 green | Depends on #46; own release blockers below |

#49 PostgreSQL run 46083987606, job 140789184581, both disposable owner-mode steps passed, including the concurrent-session harness. No formal PR reviews returned at inspection. Gemini's prior source verification of specific #39 slices is recorded in #39 comment 7226886518; it is not complete release approval. Preserve branch ownership, do not merge solely on CI. Master spec §24 reviewed on #44 2c86113.

## Source-review findings

**R1 — blocking financial-field filtering (#46).** `20261127170000_nohut_notifications_and_daily_reports.sql::nohut_daily_report_view` uses top-level subtraction. Actual `flutter_desktop/lib/daily_report.dart` at #44 2c86113 emits `comparison.netCents/diffCents`, `hourlyCents`, `orders.averageCents`, `orders.platforms[*].grossCents/estimatedNetCents`, `openAccounts.dueCents`, `topProduct.cents` and `estimatedResultCents`. These are not removed by current filters. Use typed allowlists per grant and actual producer fixture; reject unknown fields. Nested employee-hours fields also need rejection. No live exposure claimed.

**R2 — blocking freshness semantics (#46).** `sync_freshness` in 20261127167000 marks any non-null summary revision fresh when checkpoint recently updated; it does not verify current-epoch projection provenance or reject an ahead revision. Team schedule and notifications pass null and therefore report summary_missing even when present. Bind freshness to projection-specific state/current authority; distinguish missing from aged and make stale daily reports preliminary. Review notification unread count semantics (currently page-limited).

**R3 — recovery command binding (#49/#46).** Current `qr_menu_reconcile` payload is empty in 20261127169000. #49 accepts targetRequestId and cancel/reconcile operation from the execution body. SQL confirms tenant, actor, active lease, and command type but does not bind target or operation to original command envelope. This is a same-tenant command-scope gap, not demonstrated cross-tenant access. Agree a versioned target+mode contract with Claude/Gemini; verify at SQL authorization and every recovery mutation; reject legacy empty payload for cloud recovery. Test target substitution, cancel/reconcile substitution, revoked actor, expired lease, cross-tenant and replacement authority.

**R4 — remaining #49 release gates.** Current 16-hex draft confirmation plus full receipt digest does not confirm full SHA-256 at owner action. GitHub external side effect cannot be atomically fenced with a database transaction; review lease revocation race and explicit unknown outcome recovery. Image/bootstrap/local Windows-origin workflows and actual client wiring remain incomplete. No production connection, migrations, credential rotation or staging yet. Maintain hard-disabled entrypoint and local fallback until acceptance.

## Routing and next acceptance

- #46 findings posted on PR comment 7230391428; actual report producer coordination on #44 comment 7230391874.
- Gemini/Codex own #46 corrections and independent review; Claude owns producer/UI and versioned client command contract. ChatGPT owns #49 receipt binding after upstream contract agreement. Do not edit other agent branches.
- #39 remains draft pending its existing completion/migration/backup/physical-trust gates. Retest exact heads and combined integration after corrections, then review dependency merges in order.
- All findings are source-level; new regression cases need real execution. No live data or public QR writes.
