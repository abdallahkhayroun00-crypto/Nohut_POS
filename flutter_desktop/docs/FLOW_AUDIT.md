# Nohut POS flow and branding audit

PR #6 was merged before this audit (main `310925389ff855da0cea10cff9f9b83ae94f3b1f`). This audit targets the native Windows manager and its employee phone page. The preserved HTML prototype remains a separate regression target.

## Screen and control coverage

| Surface | Controls and behavior inspected | Automated evidence |
| --- | --- | --- |
| Navigation/dashboard | All ten manager destinations; wide/compact navigation; new-order entry; recent-order links; day rollover; waiting-print count | widget, UX, midnight and manager audit tests |
| Tables/floor | Five tables; occupied/empty selection; additional batches; drag bounds, overlap and doorway rejection; reset/save; explicit close | UX, floor placement, POS logic and migration tests |
| Cashier composer | Search/categories; independent variants; note/removed ingredients; quantity limits; delete; table occupancy; pickup channel/customer; save/cancel; stale-menu rejection and explicit refresh | UX, manager audit and full logic audit tests |
| Order list/detail | Source/date/status/staff/search filters; historical order links; preparation/ready/delivered; add batch; equal split; allocation; payment; cancel; close; history | navigation, manager audit, migration and control workflow tests |
| Cash/payments | Cash/card selection; amount and cash received; live change; overpayment/invalid input; confirmation/cancel; guest payments; refunds; cash opening, movements, count and closing | payment dialog, control workflow, UX and migration tests |
| Kitchen print queue | Immutable ticket contents; original staff attribution; cancellation notices; preview; ambiguous spool failure; confirmation before manual requeue; old backlog cutoff | receipt/reporting, full logic audit and control workflow tests |
| Employees | Add/edit role/name; retain stable ID; deactivate; duplicate rejection | control workflow and migration tests |
| Reports | Today/7/30-day/calendar ranges; strict dates; source/method/type/staff filters; workload; cash/sales/reconciliation/hourly CSV; UTF-8 BOM | control workflow, receipt/reporting, daily and migration tests |
| LAN/phone | Start/stop/restart; IP discovery fallback; IP selector refresh; QR/URL; limited bootstrap projection; staff selection; table additional order; pickup/customer; categories/search; variants; quantity/remove; filters; refresh; conflict and lost-response retry | real embedded HTTP tests; Playwright 320/390/768px in Windows CI |
| Settings/catalog | QR sync on/off/error; active products; stable IDs; old price snapshots; manual price disabled during auto-sync; printer name/cutoff; consistent SQLite backup | reader/sync/visibility, settings control and migration tests |
| Platform test area | Source and all eight tabs; four fixture payment types; incoming events; accept/ready/cancel; menu mapping/status/category/modifiers/bulk price; hours; claims; review moderation; invoice add/delete; retry/429; settlements | migration and control workflow tests; real SQLite isolation test |

The original source inventory contained 96 callback definitions. Dynamic rows reuse callbacks: this is a control-family audit plus representative success, cancellation, invalid-input and conflict paths, not an assertion that every possible input has been tested.

## Corrections

- Kitchen jobs freeze their content when accepted. Cancelling products can no longer rewrite the original slip. Full cancellation cancels unsent original jobs while allowing correction notices to print. Manual requeue also rejects cancelled originals and platform jobs.
- Employee additions retain employee names in frozen tickets. New items on a served order reset preparation status.
- Saved/new and historical linked orders reset stale filters. Closed historical refunds no longer appear as outstanding debts. Dashboard print count excludes completed work.
- Failed cashier commits preserve the draft. Explicit refresh updates prices and marks withdrawn products for removal; unavailable-row note editing is disabled safely. Cashier and phone row/quantity/note limits align with server validation.
- Money parsing uses integer cents and rejects overflow/malformed input. Cash change updates while typing. Impossible calendar dates and reversed date ranges are rejected. Cash closing uses one boundary timestamp.
- Employee roles and yes/no options use selectors. Platform selections clear when source changes; status/category/acceptance labels are readable Turkish.
- Real reports no longer create demo finance records. Test settlements live only in the isolated platform area.
- Network-interface discovery failure preserves local service. Start/stop/dispose guard in-flight startup. Phones receive ordering data without the cash book, settings, payments or closed-order archive.
- Local price controls explain and prevent auto-sync overwrites. Reenabling auto-print sets a new cutoff. CSV files include a UTF-8 BOM for Turkish Excel headers.

## Branding

Uses the existing original logo and QR-menu colors: green `#123e30`, cream `#f6f2e7`, gold `#a58336`. Barlow Semi Condensed and Bree Serif are bundled from the official QR-menu assets, with their OFL licenses, for both manager and phone. Font delivery does not depend on a public font service. No logo was redesigned.

## Verification and limits

Local Linux validation: 83 Flutter tests passed, one Windows-only invalid-printer test skipped; all 131 preserved HTML assertions passed; analysis has no errors or warnings (SDK informational deprecations remain). The Windows workflow separately runs analysis, all Flutter tests, the HTML suite, three phone browser widths, PowerShell syntax validation and a native release build. See the associated PR checks for its final result and downloadable executable folder.

The Linux host blocked Chromium's local socket setup, so browser execution is delegated to that workflow. A rendered Flutter capture was visually inspected. Printing uses a fake transport in automated queue tests; physical XP-237B output, real restaurant Wi-Fi phones, bank terminals and real platform APIs are not certified by these tests. The platform area remains an explicitly labeled in-memory simulation.
