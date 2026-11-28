-- Increment D Hardening (resolves all 4 blocking + 3 minor findings from Claude review #7231808318):
--   1. Blocking #1: activate_initial_sync explicitly rejects NULL or negative p_expected_batches (22023).
--   2. Blocking #2: upload_snapshot_batch verifies jsonb_array_length(p_events) = p_item_count AND
--      sha256(canonical_command_json(p_events)) = p_body_sha256; activate_initial_sync recomputes
--      manifest_sha256 = sha256(string_agg(category||':'||batch_id||':'||item_count||':'||body_sha256, '\n' order by batch_id::text))
--      and requires it to match BOTH stored m.manifest_sha256 and p_expected_manifest_sha256.
--   3. Blocking #3: TRUE STAGE + PROMOTE. upload_snapshot_batch stages verified batches into private
--      nohut_private.migration_staged_batches (ZERO writes to live projection tables before activation).
--      abort_initial_sync purges all staged batches and records/audits abort_reason.
--      activate_initial_sync atomically promotes all staged batches in one transaction in dependency order
--      and purges staged payloads upon commit.
--   4. Blocking #4: Second full sync ("Yeniden eşitle") requires rotating the authority epoch via
--      owner-only MFA-gated public.nohut_owner_rotate_authority_epoch(p_device_id, p_permission_version, p_reason),
--      which retires the old epoch, revokes old Windows agents, creates a new active epoch, and audits it.
--   5. Minor #1: Cap p_events to <= 500 events and <= 4 MB (4194304 bytes) per batch.
--   6. Minor #2: Store abort_reason & aborted_at on sync_migrations and write security_audit row.
--   7. Minor #3: Document migration_status behavior with explicit p_migration_id across epochs.
begin;

-- Store abort audit metadata on sync_migrations
alter table nohut_private.sync_migrations
  add column if not exists abort_reason text check (abort_reason is null or length(abort_reason) <= 300),
  add column if not exists aborted_at timestamptz;

-- Private staging table for unactivated initial-sync snapshot batches (zero visibility to phones before activation)
create table nohut_private.migration_staged_batches (
  restaurant_id uuid not null,
  migration_id uuid not null,
  batch_id uuid not null,
  events jsonb not null check (jsonb_typeof(events) = 'array'),
  staged_at timestamptz not null default now(),
  primary key (restaurant_id, migration_id, batch_id),
  foreign key (restaurant_id, migration_id, batch_id)
    references nohut_private.migration_batches(restaurant_id, migration_id, batch_id)
    on delete cascade
);

alter table nohut_private.migration_staged_batches enable row level security;
alter table nohut_private.migration_staged_batches force row level security;
do $$ begin
  execute format(
    'create policy migration_staged_batches_owner on nohut_private.migration_staged_batches for all to %I using(true) with check(true)',
    current_user
  );
end $$;
revoke all on table nohut_private.migration_staged_batches from public, anon, authenticated, service_role;

-- Deterministic manifest digest helper:
--   0 batches -> sha256('')
--   N batches -> sha256(string_agg(category || ':' || batch_id::text || ':' || item_count::text || ':' || body_sha256, E'\n' order by batch_id::text))
create function nohut_private.compute_migration_manifest_sha256(p_restaurant uuid, p_migration_id uuid)
returns text language sql stable security invoker set search_path = '' as $$
  select encode(
    sha256(convert_to(coalesce(
      (select string_agg(
         b.category || ':' || b.batch_id::text || ':' || b.item_count::text || ':' || b.body_sha256,
         E'\n' order by b.batch_id::text
       )
       from nohut_private.migration_batches b
       where b.restaurant_id = p_restaurant and b.migration_id = p_migration_id),
      ''
    ), 'UTF8')),
    'hex'
  );
$$;
revoke all on function nohut_private.compute_migration_manifest_sha256(uuid, uuid)
  from public, anon, authenticated, service_role;

-- Stage-only upload with strict size/count/canonical-hash verification (zero writes to live tables before activation)
create or replace function public.nohut_agent_upload_snapshot_batch(
  p_token text,
  p_migration_id uuid,
  p_batch_id uuid,
  p_category text,
  p_item_count integer,
  p_body_sha256 text,
  p_events jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  a nohut_private.windows_agents;
  m nohut_private.sync_migrations;
  prior nohut_private.migration_batches;
  ev jsonb;
  calc_hash text;
begin
  a := nohut_private.authenticate_windows_agent(p_token);
  if p_migration_id is null or p_batch_id is null or p_category is null or length(trim(p_category)) not between 1 and 64
     or p_item_count is null or p_item_count < 0
     or p_body_sha256 is null or p_body_sha256 !~ '^[0-9a-f]{64}$'
     or p_events is null or jsonb_typeof(p_events) <> 'array' then
    raise exception 'invalid snapshot batch' using errcode = '22023';
  end if;

  -- Size & cardinality caps (Minor #1: <= 500 events and <= 4 MB per batch)
  if jsonb_array_length(p_events) > 500 or octet_length(p_events::text) > 4194304 then
    raise exception 'snapshot batch exceeds cap (max 500 events / 4 MB)' using errcode = '22023';
  end if;

  -- Blocking #2: verify exact item count and canonical SHA-256 of p_events
  if jsonb_array_length(p_events) <> p_item_count then
    raise exception 'batch item_count mismatch: declared %, actual %', p_item_count, jsonb_array_length(p_events)
      using errcode = '22023';
  end if;
  calc_hash := encode(sha256(convert_to(nohut_private.canonical_command_json(p_events), 'UTF8')), 'hex');
  if calc_hash is distinct from p_body_sha256 then
    raise exception 'batch body_sha256 mismatch' using errcode = '22023';
  end if;

  select * into m from nohut_private.sync_migrations sm
   where sm.restaurant_id = a.restaurant_id and sm.migration_id = p_migration_id
     and sm.authority_epoch = a.authority_epoch for update;
  if not found or m.status not in ('uploading', 'paused') then
    raise exception 'migration not accepting batches' using errcode = '42501';
  end if;

  select * into prior from nohut_private.migration_batches b
   where b.restaurant_id = a.restaurant_id and b.migration_id = p_migration_id and b.batch_id = p_batch_id;
  if found then
    if prior.category = p_category and prior.item_count = p_item_count and prior.body_sha256 = p_body_sha256 then
      return jsonb_build_object('status', 'duplicate', 'batch_id', p_batch_id);
    end if;
    return jsonb_build_object('status', 'conflict', 'batch_id', p_batch_id);
  end if;

  -- Validate supported entity types early before staging (never writes to live tables yet)
  for ev in select value from jsonb_array_elements(p_events) loop
    if jsonb_typeof(ev) <> 'object' or ev->>'entity_type' not in (
      'employees','typed_catalog','shiftPlans','shifts','timesheetWeeks','typed_order',
      'typed_platform','typed_print','typed_finance','typed_ledger',
      'workforceSummaries','qrMenuState','dailyReports','notifications'
    ) then
      raise exception 'unsupported snapshot entity type: %', coalesce(ev->>'entity_type', '<null>')
        using errcode = '22023';
    end if;
  end loop;

  insert into nohut_private.migration_batches(
    restaurant_id, migration_id, batch_id, category, item_count, body_sha256, committed_at
  ) values (
    a.restaurant_id, p_migration_id, p_batch_id, p_category, p_item_count, p_body_sha256, clock_timestamp()
  );

  insert into nohut_private.migration_staged_batches(
    restaurant_id, migration_id, batch_id, events, staged_at
  ) values (
    a.restaurant_id, p_migration_id, p_batch_id, p_events, clock_timestamp()
  );

  if m.status = 'paused' then
    update nohut_private.sync_migrations set status = 'uploading'
     where restaurant_id = a.restaurant_id and migration_id = p_migration_id;
  end if;

  return jsonb_build_object('status', 'accepted', 'batch_id', p_batch_id);
end $$;

-- Atomic verification + promotion at activation (Blocking #1, #2, #3)
create or replace function public.nohut_agent_activate_initial_sync(
  p_token text,
  p_migration_id uuid,
  p_expected_batches integer,
  p_expected_manifest_sha256 text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  a nohut_private.windows_agents;
  m nohut_private.sync_migrations;
  committed_cnt integer;
  calc_manifest text;
  ev jsonb;
  rev bigint;
begin
  a := nohut_private.authenticate_windows_agent(p_token);

  -- Blocking #1: explicitly reject NULL or negative p_expected_batches and invalid manifest
  if p_migration_id is null
     or p_expected_batches is null or p_expected_batches < 0
     or p_expected_manifest_sha256 is null or p_expected_manifest_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid activation parameters' using errcode = '22023';
  end if;

  select * into m from nohut_private.sync_migrations sm
   where sm.restaurant_id = a.restaurant_id and sm.migration_id = p_migration_id
     and sm.authority_epoch = a.authority_epoch for update;
  if not found then
    raise exception 'migration not found' using errcode = '42501';
  end if;
  if m.manifest_sha256 is distinct from p_expected_manifest_sha256 then
    raise exception 'manifest mismatch' using errcode = '22023';
  end if;
  if m.status = 'active' then
    return jsonb_build_object(
      'status', 'duplicate', 'migration_status', 'active',
      'snapshot_seq', m.snapshot_seq, 'snapshot_revision', m.snapshot_revision
    );
  end if;
  if m.status not in ('uploading', 'catching_up', 'verifying', 'verified_pending_activation') then
    raise exception 'migration cannot be activated from status %', m.status using errcode = '42501';
  end if;

  select count(*) into committed_cnt from nohut_private.migration_batches b
   where b.restaurant_id = a.restaurant_id and b.migration_id = p_migration_id;
  if committed_cnt is distinct from p_expected_batches then
    raise exception 'incomplete_batches: expected %, got %', p_expected_batches, committed_cnt using errcode = '22023';
  end if;

  -- Blocking #2: recompute manifest from committed batch hashes and verify against declared manifest
  calc_manifest := nohut_private.compute_migration_manifest_sha256(a.restaurant_id, p_migration_id);
  if calc_manifest is distinct from m.manifest_sha256 then
    raise exception 'manifest verification failed: computed % expected %', calc_manifest, m.manifest_sha256
      using errcode = '22023';
  end if;

  -- Blocking #3: atomically promote all staged events in strict dependency order inside this transaction
  rev := greatest(m.snapshot_revision, 1);
  for ev in
    select e.value
      from nohut_private.migration_staged_batches sb,
           lateral jsonb_array_elements(sb.events) with ordinality as e(value, ord)
     where sb.restaurant_id = a.restaurant_id and sb.migration_id = p_migration_id
     order by case e.value->>'entity_type'
       when 'employees' then 0 when 'typed_catalog' then 10 when 'shiftPlans' then 15 when 'shifts' then 20
       when 'timesheetWeeks' then 25 when 'typed_order' then 30 when 'typed_platform' then 40 when 'typed_print' then 50
       when 'typed_finance' then 60 when 'typed_ledger' then 70 when 'workforceSummaries' then 80
       when 'qrMenuState' then 85 when 'dailyReports' then 88 when 'notifications' then 89 else 90 end,
       sb.batch_id::text, e.ord
  loop
    case ev->>'entity_type'
      when 'employees' then perform nohut_private.apply_employee_projection(a.restaurant_id, rev, ev->'payload');
      when 'typed_catalog' then perform nohut_private.apply_typed_projection(a.restaurant_id, rev, ev->>'entity_id', ev->'payload');
      when 'typed_finance' then perform nohut_private.apply_typed_finance(a.restaurant_id, rev, ev->'payload');
      when 'typed_ledger' then perform nohut_private.apply_typed_ledger(a.restaurant_id, rev, ev->>'entity_id', ev->'payload');
      when 'typed_platform' then perform nohut_private.apply_typed_platform(a.restaurant_id, rev, ev->>'entity_id', ev->'payload');
      when 'typed_print' then perform nohut_private.apply_typed_print(a.restaurant_id, rev, ev->>'entity_id', ev->'payload');
      when 'typed_order' then perform nohut_private.apply_typed_order(a.restaurant_id, rev, ev->>'entity_id', ev->'payload');
      when 'shifts' then perform nohut_private.apply_shift_projection(a.restaurant_id, rev, ev->'payload');
      when 'timesheetWeeks' then perform nohut_private.apply_timesheet_projection(a.restaurant_id, rev, ev->'payload');
      when 'shiftPlans' then
        perform nohut_private.apply_plan_projection(a.restaurant_id, rev, ev->'payload');
        perform nohut_private.record_projection_watermark(a.restaurant_id, 'shift_plans', rev, clock_timestamp());
      when 'workforceSummaries' then perform nohut_private.apply_workforce_summary_projection(a.restaurant_id, rev, ev->'payload');
      when 'qrMenuState' then perform nohut_private.apply_qr_menu_projection(a.restaurant_id, rev, ev->'payload');
      when 'dailyReports' then perform nohut_private.apply_daily_report_projection(a.restaurant_id, rev, ev->'payload');
      when 'notifications' then perform nohut_private.apply_notifications_projection(a.restaurant_id, rev, ev->'payload');
    end case;
  end loop;

  -- Purge staged payloads once atomically promoted
  delete from nohut_private.migration_staged_batches
   where restaurant_id = a.restaurant_id and migration_id = p_migration_id;

  update nohut_private.sync_migrations set status = 'active'
   where restaurant_id = a.restaurant_id and migration_id = p_migration_id;

  insert into nohut_private.sync_checkpoints(
    restaurant_id, authority_epoch, last_acked_seq, last_acked_revision, updated_at
  ) values (
    a.restaurant_id, a.authority_epoch, m.snapshot_seq, m.snapshot_revision, clock_timestamp()
  )
  on conflict (restaurant_id, authority_epoch) do update set
    last_acked_seq = excluded.last_acked_seq,
    last_acked_revision = excluded.last_acked_revision,
    updated_at = clock_timestamp();

  return jsonb_build_object(
    'status', 'accepted',
    'migration_status', 'active',
    'authority_epoch', a.authority_epoch,
    'snapshot_seq', m.snapshot_seq,
    'snapshot_revision', m.snapshot_revision,
    'committed_batches', committed_cnt,
    'manifest_sha256', calc_manifest
  );
end $$;

-- Safe abort: purges all staged payloads, stores abort_reason/aborted_at, and writes security_audit (Blocking #3, Minor #2)
create or replace function public.nohut_agent_abort_initial_sync(
  p_token text,
  p_migration_id uuid,
  p_reason text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  a nohut_private.windows_agents;
  m nohut_private.sync_migrations;
  clean_reason text := left(coalesce(nullif(trim(p_reason), ''), 'aborted_by_windows'), 300);
  purged_cnt integer;
begin
  a := nohut_private.authenticate_windows_agent(p_token);
  select * into m from nohut_private.sync_migrations sm
   where sm.restaurant_id = a.restaurant_id and sm.migration_id = p_migration_id
     and sm.authority_epoch = a.authority_epoch for update;
  if not found then
    raise exception 'migration not found' using errcode = '42501';
  end if;
  if m.status = 'active' then
    raise exception 'cannot abort active migration' using errcode = '42501';
  end if;

  delete from nohut_private.migration_staged_batches
   where restaurant_id = a.restaurant_id and migration_id = p_migration_id;
  get diagnostics purged_cnt = row_count;

  update nohut_private.sync_migrations
     set status = 'safely_aborted',
         abort_reason = clean_reason,
         aborted_at = clock_timestamp()
   where restaurant_id = a.restaurant_id and migration_id = p_migration_id;

  insert into nohut_private.security_audit(restaurant_id, actor_user_id, action, detail)
  values (
    a.restaurant_id, null, 'initial_sync_aborted',
    jsonb_build_object('migration_id', p_migration_id, 'authority_epoch', a.authority_epoch,
      'reason', clean_reason, 'purged_staged_batches', purged_cnt)
  );

  return jsonb_build_object(
    'status', 'safely_aborted',
    'migration_id', p_migration_id,
    'reason', clean_reason,
    'purged_staged_batches', purged_cnt
  );
end $$;

-- Blocking #4: Owner-only MFA-gated authority-epoch rotation RPC for a second full sync ("Yeniden eşitle").
-- Retires the current epoch, revokes old-epoch Windows agents, creates a fresh active epoch, and audits it.
-- Windows then re-enrolls its scoped agent against the new epoch and runs begin -> upload -> activate.
create function public.nohut_owner_rotate_authority_epoch(
  p_device_id uuid,
  p_permission_version bigint,
  p_reason text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  sid uuid := public.nohut_jwt_claim('session_id')::uuid;
  aal text := public.nohut_jwt_claim('aal');
  owner_row nohut_private.app_users;
  old_epoch uuid;
  new_epoch uuid := gen_random_uuid();
  clean_reason text := trim(coalesce(p_reason, ''));
begin
  if length(clean_reason) not between 3 and 300 then
    raise exception 'rotation reason required (3-300 chars)' using errcode = '22023';
  end if;
  owner_row := nohut_private.require_owner(uid, aal);
  if nohut_private.authorize(uid, sid, p_device_id, 'windows', 'sync.full_resync', p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select e.authority_epoch into old_epoch
    from nohut_private.authority_epochs e
   where e.restaurant_id = owner_row.restaurant_id and e.retired_at is null
   for update;

  if old_epoch is not null then
    update nohut_private.authority_epochs
       set retired_at = clock_timestamp()
     where restaurant_id = owner_row.restaurant_id and authority_epoch = old_epoch;

    update nohut_private.windows_agents
       set revoked_at = clock_timestamp()
     where restaurant_id = owner_row.restaurant_id
       and authority_epoch = old_epoch
       and revoked_at is null;
  end if;

  insert into nohut_private.authority_epochs(restaurant_id, authority_epoch)
  values (owner_row.restaurant_id, new_epoch);

  insert into nohut_private.security_audit(restaurant_id, actor_user_id, action, detail)
  values (
    owner_row.restaurant_id, uid, 'authority_epoch_rotated',
    jsonb_build_object('old_authority_epoch', old_epoch, 'new_authority_epoch', new_epoch, 'reason', clean_reason)
  );

  return jsonb_build_object(
    'old_authority_epoch', old_epoch,
    'new_authority_epoch', new_epoch,
    'reason', clean_reason
  );
end $$;

revoke all on function public.nohut_owner_rotate_authority_epoch(uuid, bigint, text)
  from public, anon, authenticated, service_role;
grant execute on function public.nohut_owner_rotate_authority_epoch(uuid, bigint, text)
  to authenticated;

commit;
