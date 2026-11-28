# Contract: Initial Database Synchronization, Resumable Snapshots & Recovery (`v1`)

- **Owner:** Backend Continuation (`gemini/backend-continuation`, PR #46)
- **Migration:** `supabase/migrations/20261127172000_nohut_initial_sync_and_strict_qr_digest.sql`
- **Status:** `Implemented / Tested` (pending independent review by ChatGPT)

## Authority & Security Rules

1. **Windows-only:** Every initial-sync and recovery RPC requires a valid, unrevoked scoped Windows agent token (`nohut_private.authenticate_windows_agent(p_token)`). Remote mobile/browser clients cannot call or enqueue initial-sync or resync operations.
2. **Pre-sync encrypted backup required:** `public.nohut_agent_begin_initial_sync` refuses to start unless `p_backup_verified = true`.
3. **No premature activation:** Cloud `sync_checkpoints` is initialized/updated ONLY when `public.nohut_agent_activate_initial_sync` verifies exact `manifest_sha256` and exact committed `migration_batches` count.
4. **Resumable & Idempotent:** Every RPC (`begin`, `upload_snapshot_batch`, `activate`) is idempotent on its UUID (`accepted` / `duplicate` / `conflict`). After an offline drop or crash, Windows queries `public.nohut_agent_migration_status` and skips already-committed `batch_id`s.
5. **Strict QR Publish Digest:** `qr_menu_publish` now **requires** full 64-hex `draftSha256` whose first 16 hex chars equal `expectedStamp`.

## RPC Surface

| RPC | Purpose |
|---|---|
| `public.nohut_agent_begin_initial_sync(p_token, p_migration_id, p_snapshot_revision, p_snapshot_seq, p_manifest_sha256, p_backup_verified)` | Starts an initial sync migration in `uploading` state after verified backup. |
| `public.nohut_agent_upload_snapshot_batch(p_token, p_migration_id, p_batch_id, p_category, p_item_count, p_body_sha256, p_events)` | Atomically ingests one snapshot category batch and records it in `nohut_private.migration_batches`. |
| `public.nohut_agent_activate_initial_sync(p_token, p_migration_id, p_expected_batches, p_expected_manifest_sha256)` | Verifies batch count & manifest, activates migration, and sets `sync_checkpoints` to `(snapshot_seq, snapshot_revision)`. |
| `public.nohut_agent_abort_initial_sync(p_token, p_migration_id, p_reason)` | Safely aborts an incomplete migration (`safely_aborted`); refuses to abort an active migration. |
| `public.nohut_agent_migration_status(p_token, p_migration_id)` | Returns current migration state, committed batches, and checkpoint for offline resume. |
