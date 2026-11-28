-- Increment D Clean Resync (resolves all remaining items from Claude re-review #7235779939):
--   1. Blocking #1 (Contract): Confirmed integer-only canonical JSON for snapshot payloads
--      (documented in docs/contracts/v1/initial-sync-and-recovery.md).
--   2. Medium #2: Second full sync ("Yeniden eşitle") cleanly REPLACES the restaurant's business
--      projections inside the activation transaction (never leaves deleted/stale rows from a
--      prior epoch behind), while keeping auth control-plane, audit, and sync metadata intact.
--   3. Medium #3: Rotating the authority epoch purges orphaned migration_staged_batches from
--      in-progress old-epoch migrations and marks them safely_aborted (abort_reason = 'epoch_rotated').
--   4. Note #4: Sets local statement_timeout = '120000' (120 s) during atomic batch promotion.
begin;

-- Clears all business projection tables for one restaurant in strict child-before-parent order.
-- NEVER touches auth control-plane (app_users, user_grants, devices, sessions, security_audit),
-- Windows agent credentials, authority_epochs, sync_migrations, migration_batches, or commands.
create function nohut_private.clear_restaurant_projections(p_restaurant uuid)
returns void language plpgsql security invoker set search_path = pg_catalog, nohut_private as $$
begin
  -- Read-model & summary projections
  delete from nohut_private.notification_reads where restaurant_id = p_restaurant;
  delete from nohut_private.cloud_notifications where restaurant_id = p_restaurant;
  delete from nohut_private.daily_report_summaries where restaurant_id = p_restaurant;
  delete from nohut_private.qr_menu_state where restaurant_id = p_restaurant;
  delete from nohut_private.weekly_workforce_summaries where restaurant_id = p_restaurant;
  delete from nohut_private.projection_watermarks where restaurant_id = p_restaurant;

  -- Workforce projections (children -> parents)
  delete from nohut_private.shift_plan_history where restaurant_id = p_restaurant;
  delete from nohut_private.shift_plans where restaurant_id = p_restaurant;
  delete from nohut_private.timesheet_entries where restaurant_id = p_restaurant;
  delete from nohut_private.timesheet_submissions where restaurant_id = p_restaurant;
  delete from nohut_private.timesheet_weeks where restaurant_id = p_restaurant;
  delete from nohut_private.shift_corrections where restaurant_id = p_restaurant;
  delete from nohut_private.shifts where restaurant_id = p_restaurant;
  delete from nohut_private.payroll_reviews where restaurant_id = p_restaurant;
  delete from nohut_private.payroll_payments where restaurant_id = p_restaurant;
  delete from nohut_private.employee_wage_history where restaurant_id = p_restaurant;

  -- Print, platform, ledger & order projections (children -> parents)
  delete from nohut_private.print_job_events where restaurant_id = p_restaurant;
  delete from nohut_private.print_jobs where restaurant_id = p_restaurant;
  delete from nohut_private.receipt_snapshots where restaurant_id = p_restaurant;
  delete from nohut_private.platform_line_versions where restaurant_id = p_restaurant;
  delete from nohut_private.platform_order_versions where restaurant_id = p_restaurant;
  delete from nohut_private.platform_order_records where restaurant_id = p_restaurant;
  delete from nohut_private.terminal_attempt_events where restaurant_id = p_restaurant;
  delete from nohut_private.terminal_attempts where restaurant_id = p_restaurant;
  delete from nohut_private.combined_payment_members where restaurant_id = p_restaurant;
  delete from nohut_private.combined_payment_groups where restaurant_id = p_restaurant;
  delete from nohut_private.cash_movements where restaurant_id = p_restaurant;
  delete from nohut_private.cash_sessions where restaurant_id = p_restaurant;
  delete from nohut_private.payment_guest_allocations where restaurant_id = p_restaurant;
  delete from nohut_private.payment_refunds where restaurant_id = p_restaurant;
  delete from nohut_private.payments where restaurant_id = p_restaurant;
  delete from nohut_private.guest_allocations where restaurant_id = p_restaurant;
  delete from nohut_private.guest_checks where restaurant_id = p_restaurant;
  delete from nohut_private.order_line_edits where restaurant_id = p_restaurant;
  delete from nohut_private.order_voids where restaurant_id = p_restaurant;
  delete from nohut_private.order_events where restaurant_id = p_restaurant;
  delete from nohut_private.deleted_order_audit where restaurant_id = p_restaurant;
  delete from nohut_private.order_items where restaurant_id = p_restaurant;
  delete from nohut_private.order_batches where restaurant_id = p_restaurant;
  delete from nohut_private.orders where restaurant_id = p_restaurant;

  -- Finance projections (children -> parents)
  delete from nohut_private.typed_record_history where restaurant_id = p_restaurant;
  delete from nohut_private.typed_record_versions where restaurant_id = p_restaurant;
  delete from nohut_private.manual_platform_sales_history where restaurant_id = p_restaurant;
  delete from nohut_private.manual_platform_sales where restaurant_id = p_restaurant;
  delete from nohut_private.weekly_payroll where restaurant_id = p_restaurant;
  delete from nohut_private.fixed_expense_payments where restaurant_id = p_restaurant;
  delete from nohut_private.fixed_expense_amount_history where restaurant_id = p_restaurant;
  delete from nohut_private.fixed_expense_active_ranges where restaurant_id = p_restaurant;
  delete from nohut_private.fixed_expenses where restaurant_id = p_restaurant;
  delete from nohut_private.expenses where restaurant_id = p_restaurant;
  delete from nohut_private.material_purchase_history where restaurant_id = p_restaurant;
  delete from nohut_private.material_purchases where restaurant_id = p_restaurant;

  -- Catalog & employee projections (children -> parents)
  delete from nohut_private.campaign_versions where restaurant_id = p_restaurant;
  delete from nohut_private.campaigns where restaurant_id = p_restaurant;
  delete from nohut_private.category_versions where restaurant_id = p_restaurant;
  delete from nohut_private.categories where restaurant_id = p_restaurant;
  delete from nohut_private.product_versions where restaurant_id = p_restaurant;
  delete from nohut_private.products where restaurant_id = p_restaurant;
  delete from nohut_private.employee_source_ids where restaurant_id = p_restaurant;
  delete from nohut_private.employees where restaurant_id = p_restaurant;
end $$;
revoke all on function nohut_private.clear_restaurant_projections(uuid)
  from public, anon, authenticated, service_role;

-- Update activate_initial_sync: deterministic 120s statement_timeout + clean projection replace
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
  perform set_config('statement_timeout', '120000', true);
  a := nohut_private.authenticate_windows_agent(p_token);

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

  calc_manifest := nohut_private.compute_migration_manifest_sha256(a.restaurant_id, p_migration_id);
  if calc_manifest is distinct from m.manifest_sha256 then
    raise exception 'manifest verification failed: computed % expected %', calc_manifest, m.manifest_sha256
      using errcode = '22023';
  end if;

  -- Medium #2: cleanly replace business projections for this restaurant inside the same atomic transaction
  perform nohut_private.clear_restaurant_projections(a.restaurant_id);

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

-- Update rotate_authority_epoch: purge orphaned staged batches & safely_abort in-progress old-epoch migrations (Medium #3)
create or replace function public.nohut_owner_rotate_authority_epoch(
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
  aborted_cnt integer := 0;
  purged_cnt integer := 0;
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
    -- Purge orphaned staged batches from non-active migrations on the retiring epoch
    delete from nohut_private.migration_staged_batches sb
     using nohut_private.sync_migrations sm
     where sb.restaurant_id = owner_row.restaurant_id
       and sm.restaurant_id = sb.restaurant_id
       and sm.migration_id = sb.migration_id
       and sm.authority_epoch = old_epoch
       and sm.status <> 'active';
    get diagnostics purged_cnt = row_count;

    update nohut_private.sync_migrations
       set status = 'safely_aborted',
           abort_reason = 'epoch_rotated',
           aborted_at = clock_timestamp()
     where restaurant_id = owner_row.restaurant_id
       and authority_epoch = old_epoch
       and status in ('preflight','backup_verified','snapshot_ready','uploading','paused','catching_up','verifying','verified_pending_activation');
    get diagnostics aborted_cnt = row_count;

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
    jsonb_build_object(
      'old_authority_epoch', old_epoch,
      'new_authority_epoch', new_epoch,
      'reason', clean_reason,
      'aborted_migrations', aborted_cnt,
      'purged_staged_batches', purged_cnt
    )
  );

  return jsonb_build_object(
    'old_authority_epoch', old_epoch,
    'new_authority_epoch', new_epoch,
    'reason', clean_reason,
    'aborted_migrations', aborted_cnt,
    'purged_staged_batches', purged_cnt
  );
end $$;

commit;
