# Contract: Initial Database Synchronization, Resumable Snapshots & Recovery (`v1`)

- **Owner:** Backend (`gemini/backend-continuation`, PR #46)
- **Migrations:**
  - `supabase/migrations/20261127172000_nohut_initial_sync_and_strict_qr_digest.sql`
  - `supabase/migrations/20261127173000_nohut_initial_sync_hardening.sql`
  - `supabase/migrations/20261127174000_nohut_initial_sync_clean_resync.sql`
- **Status:** `Implemented / Tested` (pending independent re-review)

## Authority, Privacy & Integrity Guarantees

1. **Windows-only:** Initial-sync RPCs require a valid, unrevoked scoped Windows agent token (`nohut_private.authenticate_windows_agent(p_token)`). Remote mobile/browser clients cannot call or enqueue initial-sync or resync operations.
2. **Pre-sync encrypted backup required:** `public.nohut_agent_begin_initial_sync` refuses to start unless `p_backup_verified = true`.
3. **Strict Batch & Manifest Verification (Integer-Only Canonical JSON):**
   - Each batch is capped at **≤ 500 events** and **≤ 4 MB** (`4,194,304` bytes).
   - **Confirmed integer-only rule (`nohut_private.canonical_command_json`):** Snapshot payloads MUST contain **safe integers only** (no floating-point numbers, decimals, or scientific notation; all numbers within `[-9007199254740991, 9007199254740991]`). All money values are integer kuruş; any remaining decimal rates/percentages must be encoded as strings.
   - **Exact canonical JSON form required from the Windows client:**
     - Object keys sorted in **UTF-8 byte order**, no whitespace (`:` and `,` with zero surrounding spaces).
     - Standard Postgres/JSON string escaping (`to_jsonb(text)::text`).
     - No object keys containing characters above `U+FFFF`.
   - On upload, Postgres verifies `jsonb_array_length(p_events) = p_item_count` AND `sha256(utf8(canonical_command_json(p_events))) = p_body_sha256`.
   - At activation, Postgres rejects `NULL` or negative `p_expected_batches`, verifies exact committed batch count, and recomputes:
     ```text
     manifest_sha256 = sha256(utf8(
       join('\n', sort_by_batch_id_asc(
         "${category}:${batch_id}:${item_count}:${body_sha256}"
       ))
     ))
     ```
     (For 0 batches: `sha256(utf8(""))`.) Activation succeeds only when the recomputed manifest equals BOTH stored `sync_migrations.manifest_sha256` and `p_expected_manifest_sha256`.
4. **Stage + Promote (Zero Premature Visibility, Clean Replace & Clean Abort):**
   - `nohut_agent_upload_snapshot_batch` stages verified batches in private `nohut_private.migration_staged_batches` — **zero writes to live projection tables occur while `uploading`**, so phones never see partial/unactivated snapshot data.
   - `nohut_agent_abort_initial_sync` purges all staged batches for that migration, stores `abort_reason` & `aborted_at`, and records an `initial_sync_aborted` entry in `nohut_private.security_audit`.
   - `nohut_agent_activate_initial_sync` sets a local `120 s` `statement_timeout`, **cleanly clears the restaurant's prior business projection rows** (leaving auth control-plane, audit, and sync metadata intact), atomically promotes all staged events in strict dependency order inside a single Postgres transaction, purges staged payloads, marks the migration `'active'`, and initializes `sync_checkpoints` to `(snapshot_seq, snapshot_revision)`.
5. **Second Full Sync ("Yeniden eşitle") — Authority Epoch Rotation:**
   - Within an authority epoch, only one migration can be `'active'`.
   - To perform a second full sync (*Yeniden eşitle* or replacement-PC restore), the owner calls **`public.nohut_owner_rotate_authority_epoch(p_device_id, p_permission_version, p_reason)`** from Windows with an **owner `aal2` MFA session** (`sync.full_resync`).
   - This atomically purges any orphaned `migration_staged_batches` on the retiring epoch, marks non-active migrations of that epoch `safely_aborted` (`abort_reason = 'epoch_rotated'`), retires the old `authority_epoch`, revokes all old-epoch `windows_agents`, creates a fresh active `authority_epoch`, and writes an `authority_epoch_rotated` audit row. Windows then re-enrolls its scoped agent against `new_authority_epoch` and runs `begin` → `upload_snapshot_batch` → `activate_initial_sync`.
6. **Status Query Semantics (`nohut_agent_migration_status`):**
   - With `p_migration_id = NULL`: returns the latest migration for the agent's current active `authority_epoch`.
   - With an explicit `p_migration_id`: returns that migration even if it belongs to a retired epoch of the same restaurant (useful for audit/diagnostics).
7. **Strict QR Publish Digest:** `qr_menu_publish` requires full 64-hex `draftSha256` whose first 16 hex chars equal `expectedStamp`.
