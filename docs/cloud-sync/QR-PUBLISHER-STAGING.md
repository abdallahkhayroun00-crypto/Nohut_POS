# QR Publisher v2 — staging and cutover checklist

Status: REVIEW ONLY. No production provisioning, migration, deployment or publication authorized by this document.

## Evidence at bfa77d0
- All five PR #49 CI workflows passed. QR publisher run 46083642769 includes actual disposable PostgreSQL TLS with trusted certificate, wrong CA rejection, plaintext rejection and Deno typecheck (job 140788117923).
- Owner-provided live diagnostic verified read-only GitHub App authentication and catalog retrieval (55 products, 9 categories, 3 campaigns). No live write evidence.
- New two-session concurrency harness is pending CI; tests cross-tenant denial, repository lock serialization, rollback, one unresolved claim.

## Blocking prerequisites
- Merge and verify #39 then #46 in dependency order, reconcile branch changes before promoting #49. Review the latest master requirements and progress board.
- Independent Gemini security review: actual authority/grant/epoch revocation, command binding including recovery target, full SHA-256 confirmation compatibility, in-flight external side effect boundary, unknown outcome recovery, dependency integrity, inherited role privileges, no public Data API exposure.
- Allocate numbered migrations using reviewed migration tooling. Review-only SQL is not a migration and must not be applied as-is to production.
- Review image upload support, initial activation/bootstrap and Windows local-origin publish/sync path. Current increment does not implement them; keep existing publisher until parity verified.
- Rotate previously exposed legacy service-role credential safely after dependency inventory. Remove temporary diagnostic credential. Never copy secrets into chat/repository.
- Use disposable staging DB and isolated synthetic Git transport/repository. No writes to live public QR repository for development.

## Staging procedure (after gates above)
1. Provision dedicated non-superuser, NOBYPASSRLS login with only private wrapper grants. Verify no inherited business-data access. Generate password locally; use server secret NOHUT_QR_DB_PASSWORD. Obtain verified DB CA from dashboard and save NOHUT_QR_DB_CA; no credentials in commits or client configuration.
2. Pin and lock Postgres.js dependency. Verify Deno runtime TLS to the dedicated staging connection, correct session/current role, restricted permissions and actual committed transactions. Reject wrong CA and plaintext.
3. Build deployable staging configuration without changing the production hard-disabled entrypoint. Verify safe default and explicit enable gate. No reuse of production GitHub write token in staging.
4. Exercise real Windows-authoritative draft serialization and projection ACK before publish. Test stale revision, changed draft, removed permission, expired lease, agent replacement, parallel requests, restart, lost ACK, unavailable GitHub, and unknown result lock. Exercise Android/PWA command initiation without independent draft writer or secrets.
5. Verify audit actor/device/epoch and receipt history, recovery under a fresh authorized command, Pages status distinct from commit status. Verify image parity and initial activation separately.
6. Owner explicitly approves cutover and any real public publication. Confirm no outstanding local/cloud operation before switching. Keep existing local publisher as temporary fallback only before cutover; never auto-fallback from an uncertain cloud outcome.
7. Physically verify Windows install and employee/manager paths. Remove bundled Node/PEM dependency only after verified cloud parity. Revoke obsolete GitHub key after successful cutover. Preserve ten-minute/startup menu sync and historical sale prices.

## Rollback
Disable cloud execution; keep receipts/audit and unresolved lock. Reconcile actual Git commit before any local fallback. Never force ref, revert public content, replay payment or run destructive database operations automatically. Owner review required for any actual public rollback.
