-- Hardening migration for PR #46 addressing independent review blockers:
--   1. ChatGPT #7230391428 & Claude #7230678865 (Financial Privacy):
--      * Strict field-by-field allowlist in public.nohut_daily_report_view matching daily_report.dart.
--      * Rejects unknown top-level keys and nested staffHours/workingHours at ANY depth at ingest.
--      * Enforces p_client = 'yonetici' + dashboard.view; emits amountsHidden: true without sales.view.
--   2. ChatGPT #7230391428 (Stale Metadata & unreadCount):
--      * Per-projection provenance table nohut_private.projection_watermarks bound to authority_epoch
--        and source_revision so sync_freshness detects epoch_mismatch, revision_ahead, projection_aged,
--        projection_missing, sync_aged, and no_sync accurately (including empty team schedules/notifications).
--      * Forces preliminary: true on stale Gün Sonu Raporu.
--      * Computes unreadCount across ALL visible unread notifications (not limited to page size).
--   3. ChatGPT #7230501923 & Claude aea2861 (QR Recovery & Digest Alignment):
--      * qr_menu_reconcile requires exact {targetRequestId: UUID, mode: 'reconcile'|'cancel_before_attempt'}
--        and denies legacy {}.
--      * qr_menu_publish supports optional draftSha256 (64-hex) bound to expectedStamp (first 16 hex).
begin;

-- 1. Per-projection provenance watermarks (FORCE RLS + owner-only policy, zero client grants)
create table nohut_private.projection_watermarks (
  restaurant_id uuid not null references nohut_private.restaurants,
  projection_key text not null check (projection_key in (
    'workforce_summaries', 'shift_plans', 'qr_menu_state', 'notifications', 'daily_reports'
  )),
  authority_epoch uuid not null,
  source_revision bigint not null check (source_revision > 0),
  calculated_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (restaurant_id, projection_key)
);

alter table nohut_private.projection_watermarks enable row level security;
alter table nohut_private.projection_watermarks force row level security;
do $$ begin
  execute format(
    'create policy projection_watermarks_owner on nohut_private.projection_watermarks for all to %I using(true) with check(true)',
    current_user
  );
end $$;
revoke all on table nohut_private.projection_watermarks from public, anon, authenticated, service_role;

create function nohut_private.record_projection_watermark(
  p_restaurant uuid,
  p_key text,
  p_revision bigint,
  p_calculated_at timestamptz default null
) returns void language plpgsql security invoker set search_path = pg_catalog, nohut_private as $$
declare
  v_epoch uuid;
begin
  select e.authority_epoch into v_epoch
    from nohut_private.authority_epochs e
   where e.restaurant_id = p_restaurant and e.retired_at is null
   order by e.created_at desc limit 1;
  if not found then
    return;
  end if;
  insert into nohut_private.projection_watermarks(
    restaurant_id, projection_key, authority_epoch, source_revision, calculated_at, updated_at
  ) values (
    p_restaurant, p_key, v_epoch, p_revision, p_calculated_at, clock_timestamp()
  )
  on conflict (restaurant_id, projection_key) do update set
    authority_epoch = excluded.authority_epoch,
    source_revision = excluded.source_revision,
    calculated_at = coalesce(excluded.calculated_at, nohut_private.projection_watermarks.calculated_at),
    updated_at = clock_timestamp()
  where nohut_private.projection_watermarks.authority_epoch <> excluded.authority_epoch
     or nohut_private.projection_watermarks.source_revision <= excluded.source_revision;
end $$;
revoke all on function nohut_private.record_projection_watermark(uuid, text, bigint, timestamptz)
  from public, anon, authenticated, service_role;

-- 2. Provenance-bound sync_freshness(p_restaurant, p_projection_key)
create function nohut_private.projection_freshness(
  p_restaurant uuid,
  p_projection_key text,
  p_row_revision bigint default null,
  p_row_calculated_at timestamptz default null
) returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare
  cp record;
  wm nohut_private.projection_watermarks;
  eff_rev bigint;
  eff_calc timestamptz;
  stale boolean := true;
  reason text := 'no_sync';
begin
  select c.authority_epoch, c.last_acked_revision, c.updated_at into cp
    from nohut_private.sync_checkpoints c
    join nohut_private.authority_epochs a
      on a.restaurant_id = c.restaurant_id and a.authority_epoch = c.authority_epoch
   where c.restaurant_id = p_restaurant and a.retired_at is null
   order by c.updated_at desc limit 1;

  if not found then
    return jsonb_build_object(
      'authorityEpoch', null,
      'checkpointRevision', null,
      'sourceRevision', p_row_revision,
      'calculatedAt', p_row_calculated_at,
      'syncedAt', null,
      'projectionUpdatedAt', null,
      'stale', true,
      'staleReason', 'no_sync'
    );
  end if;

  select * into wm from nohut_private.projection_watermarks w
   where w.restaurant_id = p_restaurant and w.projection_key = p_projection_key;

  eff_rev := coalesce(p_row_revision, wm.source_revision);
  eff_calc := coalesce(p_row_calculated_at, wm.calculated_at);

  if clock_timestamp() - cp.updated_at > interval '15 minutes' then
    stale := true;
    reason := 'sync_aged';
  elsif not found then
    stale := true;
    reason := 'projection_missing';
  elsif wm.authority_epoch is distinct from cp.authority_epoch then
    stale := true;
    reason := 'epoch_mismatch';
  elsif eff_rev is null then
    stale := true;
    reason := 'projection_missing';
  elsif eff_rev > cp.last_acked_revision or wm.source_revision > cp.last_acked_revision then
    stale := true;
    reason := 'revision_ahead';
  elsif clock_timestamp() - wm.updated_at > interval '15 minutes' then
    stale := true;
    reason := 'projection_aged';
  else
    stale := false;
    reason := null;
  end if;

  return jsonb_build_object(
    'authorityEpoch', cp.authority_epoch,
    'checkpointRevision', cp.last_acked_revision,
    'sourceRevision', eff_rev,
    'calculatedAt', eff_calc,
    'syncedAt', cp.updated_at,
    'projectionUpdatedAt', wm.updated_at,
    'stale', stale,
    'staleReason', reason
  );
end $$;
revoke all on function nohut_private.projection_freshness(uuid, text, bigint, timestamptz)
  from public, anon, authenticated, service_role;

-- 3. Recursive staffHours / workingHours forbidden-key detector (any depth)
create function nohut_private.contains_forbidden_daily_report_key(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  with recursive walk(val) as (
    select p
    union all
    select case jsonb_typeof(w.val)
      when 'object' then e.value
      when 'array' then a.value
      else null
    end
    from walk w
    left join lateral jsonb_each(case when jsonb_typeof(w.val) = 'object' then w.val else '{}'::jsonb end) e on true
    left join lateral jsonb_array_elements(case when jsonb_typeof(w.val) = 'array' then w.val else '[]'::jsonb end) a on true
    where w.val is not null and jsonb_typeof(w.val) in ('object', 'array')
  ), keys as (
    select lower(k) as k
    from walk w, lateral jsonb_object_keys(case when jsonb_typeof(w.val) = 'object' then w.val else '{}'::jsonb end) k
  )
  select exists(
    select 1 from keys
    where k in ('staffhours', 'staff_hours', 'workinghours', 'working_hours', 'employeehours', 'employee_hours')
  );
$$;
revoke all on function nohut_private.contains_forbidden_daily_report_key(jsonb)
  from public, anon, authenticated, service_role;

-- 4. Update projection writers to record watermarks & enforce strict daily report ingest allowlist
create or replace function nohut_private.apply_workforce_summary_projection(
  p_restaurant uuid, p_revision bigint, p_payload jsonb
) returns void language plpgsql security invoker set search_path = pg_catalog, nohut_private as $$
declare
  item jsonb;
  eid uuid;
  ws date;
  we date;
  dd date;
  aod date;
  calc timestamptz;
  sub_at timestamptz;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' or jsonb_typeof(p_payload->'rows') <> 'array' then
    raise exception 'invalid workforce summary payload' using errcode = '22023';
  end if;
  aod := (p_payload->>'as_of_day')::date;
  calc := (p_payload->>'calculated_at')::timestamptz;
  for item in select value from jsonb_array_elements(p_payload->'rows') loop
    if jsonb_typeof(item) <> 'object' then
      raise exception 'invalid workforce summary row' using errcode = '22023';
    end if;
    select employee_id into eid from nohut_private.employee_source_ids
      where restaurant_id = p_restaurant and local_id = (item->>'employeeLocalId')::integer;
    if not found then
      raise exception 'unknown workforce summary employee' using errcode = '22023';
    end if;
    ws := (item->>'weekStart')::date;
    we := (item->>'weekEnd')::date;
    dd := (item->>'dueDate')::date;
    sub_at := case when item->>'submittedAt' is null then null else (item->>'submittedAt')::timestamptz end;
    insert into nohut_private.weekly_workforce_summaries(
      restaurant_id, employee_id, employee_local_id, employee_name,
      week_start, week_end, due_date, as_of_day, calculated_at,
      payroll_eligible, worked_minutes, planned_minutes, missing_rate_minutes, rate_complete,
      pay_type, rate_kurus, earned_kurus, paid_kurus, advance_kurus, overpaid_kurus, remaining_kurus,
      financial_status, review_status, submission_status, submitted_at, overdue, legacy, last_paid_on,
      source_revision, updated_at
    ) values (
      p_restaurant, eid, (item->>'employeeLocalId')::integer, item->>'employeeName',
      ws, we, dd, aod, calc,
      (item->>'payrollEligible')::boolean, (item->>'workedMinutes')::integer,
      (item->>'plannedMinutes')::integer, (item->>'missingRateMinutes')::integer,
      (item->>'rateComplete')::boolean,
      item->>'payType', (item->>'rateKurus')::bigint, (item->>'earnedKurus')::bigint,
      (item->>'paidKurus')::bigint, (item->>'advanceKurus')::bigint, (item->>'overpaidKurus')::bigint,
      (item->>'remainingKurus')::bigint,
      item->>'financialStatus', item->>'reviewStatus', item->>'submissionStatus',
      sub_at, (item->>'overdue')::boolean, (item->>'legacy')::boolean,
      case when item->>'lastPaidOn' is null then null else (item->>'lastPaidOn')::date end,
      p_revision, clock_timestamp()
    )
    on conflict(restaurant_id, employee_id, week_start) do update set
      employee_name = excluded.employee_name,
      week_end = excluded.week_end,
      due_date = excluded.due_date,
      as_of_day = excluded.as_of_day,
      calculated_at = excluded.calculated_at,
      payroll_eligible = excluded.payroll_eligible,
      worked_minutes = excluded.worked_minutes,
      planned_minutes = excluded.planned_minutes,
      missing_rate_minutes = excluded.missing_rate_minutes,
      rate_complete = excluded.rate_complete,
      pay_type = excluded.pay_type,
      rate_kurus = excluded.rate_kurus,
      earned_kurus = excluded.earned_kurus,
      paid_kurus = excluded.paid_kurus,
      advance_kurus = excluded.advance_kurus,
      overpaid_kurus = excluded.overpaid_kurus,
      remaining_kurus = excluded.remaining_kurus,
      financial_status = excluded.financial_status,
      review_status = excluded.review_status,
      submission_status = excluded.submission_status,
      submitted_at = excluded.submitted_at,
      overdue = excluded.overdue,
      legacy = excluded.legacy,
      last_paid_on = excluded.last_paid_on,
      source_revision = excluded.source_revision,
      updated_at = clock_timestamp()
    where nohut_private.weekly_workforce_summaries.source_revision < excluded.source_revision;
  end loop;
  perform nohut_private.record_projection_watermark(p_restaurant, 'workforce_summaries', p_revision, calc);
end $$;

create or replace function nohut_private.apply_qr_menu_projection(
  p_restaurant uuid, p_revision bigint, p_payload jsonb
) returns void language plpgsql security invoker set search_path = pg_catalog, nohut_private as $$
declare
  avail boolean;
  stamp text;
  rev text;
  rev_label text;
  is_off boolean;
  pend boolean;
  lnk text;
  chg jsonb;
  cat jsonb;
  aud jsonb;
  calc timestamptz;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'invalid qr menu payload' using errcode = '22023';
  end if;
  if nohut_private.contains_forbidden_secret_key(p_payload) then
    raise exception 'credentials forbidden in cloud qr menu' using errcode = '42501';
  end if;
  if jsonb_typeof(p_payload->'available') is distinct from 'boolean' then
    raise exception 'available boolean required' using errcode = '22023';
  end if;
  avail := (p_payload->>'available')::boolean;
  calc := coalesce(nullif(p_payload->>'calculated_at', '')::timestamptz, clock_timestamp());
  stamp := nullif(p_payload->>'stamp', '');
  rev := nullif(p_payload->>'revision', '');
  rev_label := nullif(p_payload->>'revisionLabel', '');
  is_off := coalesce((p_payload->>'offline')::boolean, rev is null);
  pend := coalesce((p_payload->>'pendingPublish')::boolean, false);
  lnk := nullif(p_payload->>'link', '');
  chg := coalesce(p_payload->'changes', '[]'::jsonb);
  cat := coalesce(p_payload->'catalog', '{"categories":[],"products":[],"campaigns":[]}'::jsonb);
  aud := coalesce(p_payload->'recentAudit', '[]'::jsonb);

  if avail and (stamp is null or stamp !~ '^[0-9a-f]{16}$') then
    raise exception 'valid draft stamp required' using errcode = '22023';
  end if;
  if lnk is not null and lnk not in ('ready', 'no_key', 'service_down') then
    raise exception 'invalid link status' using errcode = '22023';
  end if;
  if jsonb_typeof(chg) <> 'array' or jsonb_typeof(cat) <> 'object' or jsonb_typeof(aud) <> 'array' then
    raise exception 'invalid qr menu structure' using errcode = '22023';
  end if;
  if jsonb_array_length(aud) > 100 then
    raise exception 'qr menu audit slice too large' using errcode = '22023';
  end if;
  if avail and (
    jsonb_typeof(cat->'categories') <> 'array'
    or jsonb_typeof(cat->'products') <> 'array'
    or jsonb_typeof(cat->'campaigns') <> 'array'
  ) then
    raise exception 'qr menu catalog lists required' using errcode = '22023';
  end if;

  insert into nohut_private.qr_menu_state(
    restaurant_id, available, draft_stamp, revision, revision_label,
    offline, pending_publish, link_status, changes, catalog, recent_audit,
    source_revision, calculated_at, updated_at
  ) values (
    p_restaurant, avail, stamp, rev, rev_label,
    is_off, pend, lnk, chg, cat, aud,
    p_revision, calc, clock_timestamp()
  )
  on conflict (restaurant_id) do update set
    available = excluded.available,
    draft_stamp = excluded.draft_stamp,
    revision = excluded.revision,
    revision_label = excluded.revision_label,
    offline = excluded.offline,
    pending_publish = excluded.pending_publish,
    link_status = excluded.link_status,
    changes = excluded.changes,
    catalog = excluded.catalog,
    recent_audit = excluded.recent_audit,
    source_revision = excluded.source_revision,
    calculated_at = excluded.calculated_at,
    updated_at = clock_timestamp()
  where nohut_private.qr_menu_state.source_revision <= excluded.source_revision;
  perform nohut_private.record_projection_watermark(p_restaurant, 'qr_menu_state', p_revision, calc);
end $$;

create or replace function nohut_private.apply_notifications_projection(
  p_restaurant uuid, p_revision bigint, p_payload jsonb
) returns void language plpgsql security invoker set search_path = pg_catalog, nohut_private as $$
declare
  item jsonb;
  clients_arr text[];
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' or jsonb_typeof(p_payload->'items') <> 'array' then
    raise exception 'invalid notifications payload' using errcode = '22023';
  end if;
  if nohut_private.contains_forbidden_secret_key(p_payload) then
    raise exception 'credentials forbidden in notifications' using errcode = '42501';
  end if;

  for item in select value from jsonb_array_elements(p_payload->'items') loop
    if jsonb_typeof(item) <> 'object' or jsonb_typeof(item->'clients') <> 'array' then
      raise exception 'invalid notification item' using errcode = '22023';
    end if;
    select array_agg(x) into clients_arr from jsonb_array_elements_text(item->'clients') x;
    if clients_arr is null or cardinality(clients_arr) = 0 then
      raise exception 'notification clients required' using errcode = '22023';
    end if;

    insert into nohut_private.cloud_notifications(
      restaurant_id, notification_id, category, severity, required_permission,
      allowed_clients, recipient_employee_local_id, title, body, deep_link,
      created_at, source_revision, updated_at
    ) values (
      p_restaurant,
      item->>'id',
      item->>'category',
      item->>'severity',
      nullif(item->>'requiredPermission', ''),
      clients_arr,
      case when item->>'recipientEmployeeId' is null then null else (item->>'recipientEmployeeId')::integer end,
      item->>'title',
      coalesce(item->>'body', ''),
      nullif(item->>'deepLink', ''),
      (item->>'createdAt')::timestamptz,
      p_revision,
      clock_timestamp()
    )
    on conflict (restaurant_id, notification_id) do update set
      category = excluded.category,
      severity = excluded.severity,
      required_permission = excluded.required_permission,
      allowed_clients = excluded.allowed_clients,
      recipient_employee_local_id = excluded.recipient_employee_local_id,
      title = excluded.title,
      body = excluded.body,
      deep_link = excluded.deep_link,
      source_revision = excluded.source_revision,
      updated_at = clock_timestamp()
    where nohut_private.cloud_notifications.source_revision <= excluded.source_revision;
  end loop;
  perform nohut_private.record_projection_watermark(p_restaurant, 'notifications', p_revision, clock_timestamp());
end $$;

create or replace function nohut_private.apply_daily_report_projection(
  p_restaurant uuid, p_revision bigint, p_payload jsonb
) returns void language plpgsql security invoker set search_path = pg_catalog, nohut_private as $$
declare
  item jsonb;
  bday date;
  calc timestamptz;
  rep jsonb;
  allowed_top text[] := array[
    'businessDate','generatedAt','closingTime','closed','preliminary','preliminaryReason',
    'sales','comparison','hourlyCents','orders','collections','openAccounts',
    'expenses','estimatedResultCents','estimateNote','topProduct','peakHour'
  ];
  bad_key text;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' or jsonb_typeof(p_payload->'reports') <> 'array' then
    raise exception 'invalid daily reports payload' using errcode = '22023';
  end if;
  if nohut_private.contains_forbidden_secret_key(p_payload) then
    raise exception 'credentials forbidden in daily report' using errcode = '42501';
  end if;
  -- Owner decision (QA-05 superseded): reject staffHours/workingHours at ANY nesting depth.
  if nohut_private.contains_forbidden_daily_report_key(p_payload) then
    raise exception 'staffHours forbidden in daily report' using errcode = '22023';
  end if;

  for item in select value from jsonb_array_elements(p_payload->'reports') loop
    if jsonb_typeof(item) <> 'object' then
      raise exception 'invalid daily report item' using errcode = '22023';
    end if;
    rep := item->'report';
    if rep is null or jsonb_typeof(rep) <> 'object' then
      raise exception 'daily report object required' using errcode = '22023';
    end if;
    -- Deny unknown top-level keys so new local fields require an explicit allowlist update.
    select k into bad_key from jsonb_object_keys(rep) k where not (k = any(allowed_top)) limit 1;
    if bad_key is not null then
      raise exception 'unknown daily report key: %', bad_key using errcode = '22023';
    end if;

    bday := (item->>'day')::date;
    calc := coalesce(nullif(item->>'calculatedAt', '')::timestamptz, nullif(rep->>'generatedAt', '')::timestamptz, clock_timestamp());

    insert into nohut_private.daily_report_summaries(
      restaurant_id, business_day, is_preliminary, report_payload,
      calculated_at, source_revision, updated_at
    ) values (
      p_restaurant, bday, coalesce((item->>'preliminary')::boolean, (rep->>'preliminary')::boolean, true), rep,
      calc, p_revision, clock_timestamp()
    )
    on conflict (restaurant_id, business_day) do update set
      is_preliminary = excluded.is_preliminary,
      report_payload = excluded.report_payload,
      calculated_at = excluded.calculated_at,
      source_revision = excluded.source_revision,
      updated_at = clock_timestamp()
    where nohut_private.daily_report_summaries.source_revision <= excluded.source_revision;
  end loop;
  perform nohut_private.record_projection_watermark(p_restaurant, 'daily_reports', p_revision, clock_timestamp());
end $$;

-- Record shift_plans watermark inside ingest_sync_transaction whenever shiftPlans is ingested
create or replace function nohut_private.ingest_sync_transaction(p_restaurant uuid, p_epoch uuid, p_tx jsonb)
returns jsonb language plpgsql security invoker set search_path = pg_catalog, nohut_private
as $$
declare cp nohut_private.sync_checkpoints%rowtype; old_tx nohut_private.sync_transactions%rowtype;
  rev bigint; fst bigint; lst bigint; n integer; tid uuid; ev jsonb;
begin
  perform nohut_private.validate_sync_transaction(p_epoch, p_tx);
  perform 1 from nohut_private.authority_epochs a where a.restaurant_id = p_restaurant
    and a.authority_epoch = p_epoch and a.retired_at is null for share;
  if not found then raise exception 'inactive authority' using errcode = '42501'; end if;
  perform 1 from nohut_private.sync_migrations m where m.restaurant_id = p_restaurant
    and m.authority_epoch = p_epoch and m.status = 'active' for share;
  if not found then raise exception 'migration not active' using errcode = '42501'; end if;
  select * into cp from nohut_private.sync_checkpoints c where c.restaurant_id = p_restaurant
    and c.authority_epoch = p_epoch for update;
  if not found then raise exception 'checkpoint not provisioned' using errcode = '42501'; end if;
  rev := (p_tx->>'source_revision')::bigint; fst := (p_tx->>'first_seq')::bigint;
  lst := (p_tx->>'last_seq')::bigint; n := (p_tx->>'event_count')::integer; tid := (p_tx->>'tx_id')::uuid;
  select * into old_tx from nohut_private.sync_transactions t
    where t.restaurant_id = p_restaurant and t.authority_epoch = p_epoch and t.tx_id = tid;
  if found then
    if old_tx.source_revision <> rev or old_tx.first_seq <> fst or old_tx.last_seq <> lst
       or old_tx.event_count <> n or old_tx.body_sha256 <> p_tx->>'body_sha256'
       or cp.last_acked_seq < lst
       or (select count(*) from nohut_private.sync_event_ids i where i.restaurant_id = p_restaurant
          and i.authority_epoch = p_epoch and i.tx_id = tid) <> n
       or exists(select 1 from jsonb_array_elements(p_tx->'events') v(ev)
         where not exists(select 1 from nohut_private.sync_event_ids i
          where i.restaurant_id = p_restaurant and i.authority_epoch = p_epoch and i.tx_id = tid
          and i.event_id = v.ev->>'event_id' and i.event_ordinal = (v.ev->>'event_ordinal')::integer
          and i.seq = (v.ev->>'seq')::bigint and i.entity_type = v.ev->>'entity_type'
          and i.entity_id = v.ev->>'entity_id' and i.op = v.ev->>'op'
          and i.body_sha256 = v.ev->>'body_sha256')) then
      return jsonb_build_object('status', 'conflict', 'acked_through_seq', cp.last_acked_seq);
    end if;
    return jsonb_build_object('status', 'duplicate', 'acked_through_seq', cp.last_acked_seq);
  end if;
  if fst > cp.last_acked_seq + 1 then
    return jsonb_build_object('status', 'gap', 'acked_through_seq', cp.last_acked_seq);
  end if;
  if fst <> cp.last_acked_seq + 1 or rev <= cp.last_acked_revision then
    return jsonb_build_object('status', 'conflict', 'acked_through_seq', cp.last_acked_seq);
  end if;
  if exists(select 1 from jsonb_array_elements(p_tx->'events') v(ev)
    where not((v.ev->>'entity_type' in ('employees','shifts','timesheetWeeks','shiftPlans','typed_finance','workforceSummaries','qrMenuState','notifications','dailyReports') and v.ev->>'entity_id' = 'core')
      or (v.ev->>'entity_type' = 'typed_catalog' and v.ev->>'entity_id' in ('localMenu','internalMenu','qrCategories','qrCampaigns'))
      or (v.ev->>'entity_type' in ('typed_print','typed_platform'))
      or (v.ev->>'entity_type' = 'typed_ledger' and v.ev->>'entity_id' in ('combinedPayments','terminalAttempts','cashBook'))
      or (v.ev->>'entity_type' in ('typed_order','order_archive_marker') and v.ev->>'entity_id' ~ '^[0-9]+$'))
      or v.ev->>'op' <> 'upsert')
    or (select count(distinct (v.ev->>'entity_type', v.ev->>'entity_id')) from jsonb_array_elements(p_tx->'events') v(ev)) <> n then
    raise exception 'typed projection not supported yet' using errcode = '22023';
  end if;
  if exists(select 1 from jsonb_array_elements(p_tx->'events') marker where marker->>'entity_type' = 'order_archive_marker'
    and (marker->'payload' is distinct from jsonb_build_object('local_order_id', marker->>'entity_id', 'archive_required', true)
      or not exists(select 1 from jsonb_array_elements(p_tx->'events') archive where archive->>'entity_type' = 'typed_order'
        and archive->>'entity_id' = marker->>'entity_id' and archive->'payload'->'counts'->'deleted_order_audit' = '1'::jsonb))) then
    raise exception 'order deletion without full archive' using errcode = '22023'; end if;
  for ev in select value from jsonb_array_elements(p_tx->'events') order by case value->>'entity_type'
    when 'employees' then 0 when 'typed_catalog' then 10 when 'shiftPlans' then 15 when 'shifts' then 20
    when 'timesheetWeeks' then 25 when 'typed_order' then 30 when 'typed_platform' then 40 when 'typed_print' then 50
    when 'typed_finance' then 60 when 'typed_ledger' then 70 when 'workforceSummaries' then 80
    when 'qrMenuState' then 85 when 'dailyReports' then 88 when 'notifications' then 89 else 90 end loop
    case ev->>'entity_type'
      when 'employees' then perform nohut_private.apply_employee_projection(p_restaurant, rev, ev->'payload');
      when 'typed_catalog' then perform nohut_private.apply_typed_projection(p_restaurant, rev, ev->>'entity_id', ev->'payload');
      when 'typed_finance' then perform nohut_private.apply_typed_finance(p_restaurant, rev, ev->'payload');
      when 'typed_ledger' then perform nohut_private.apply_typed_ledger(p_restaurant, rev, ev->>'entity_id', ev->'payload');
      when 'typed_platform' then perform nohut_private.apply_typed_platform(p_restaurant, rev, ev->>'entity_id', ev->'payload');
      when 'typed_print' then perform nohut_private.apply_typed_print(p_restaurant, rev, ev->>'entity_id', ev->'payload');
      when 'typed_order' then perform nohut_private.apply_typed_order(p_restaurant, rev, ev->>'entity_id', ev->'payload');
      when 'order_archive_marker' then null;
      when 'shifts' then perform nohut_private.apply_shift_projection(p_restaurant, rev, ev->'payload');
      when 'timesheetWeeks' then perform nohut_private.apply_timesheet_projection(p_restaurant, rev, ev->'payload');
      when 'shiftPlans' then
        perform nohut_private.apply_plan_projection(p_restaurant, rev, ev->'payload');
        perform nohut_private.record_projection_watermark(p_restaurant, 'shift_plans', rev, clock_timestamp());
      when 'workforceSummaries' then perform nohut_private.apply_workforce_summary_projection(p_restaurant, rev, ev->'payload');
      when 'qrMenuState' then perform nohut_private.apply_qr_menu_projection(p_restaurant, rev, ev->'payload');
      when 'dailyReports' then perform nohut_private.apply_daily_report_projection(p_restaurant, rev, ev->'payload');
      when 'notifications' then perform nohut_private.apply_notifications_projection(p_restaurant, rev, ev->'payload');
    end case;
  end loop;
  insert into nohut_private.sync_transactions(restaurant_id, authority_epoch, tx_id, source_revision, first_seq, last_seq, event_count, schema_version, body_sha256)
    values(p_restaurant, p_epoch, tid, rev, fst, lst, n, 1, p_tx->>'body_sha256');
  insert into nohut_private.sync_event_ids(restaurant_id, authority_epoch, tx_id, event_id, event_ordinal, seq, entity_type, entity_id, op, body_sha256)
    select p_restaurant, p_epoch, tid, v.ev->>'event_id', (v.ev->>'event_ordinal')::integer, (v.ev->>'seq')::bigint,
      v.ev->>'entity_type', v.ev->>'entity_id', v.ev->>'op', v.ev->>'body_sha256'
    from jsonb_array_elements(p_tx->'events') v(ev);
  update nohut_private.sync_checkpoints c set last_acked_seq = lst, last_acked_revision = rev, updated_at = clock_timestamp()
    where c.restaurant_id = p_restaurant and c.authority_epoch = p_epoch;
  return jsonb_build_object('status', 'accepted', 'acked_through_seq', lst);
end $$;

-- 5. Hardened public.nohut_daily_report_view (Yönetici only, explicit field-by-field allowlist, stale -> preliminary)
create or replace function public.nohut_daily_report_view(
  p_device_id uuid,
  p_client text,
  p_permission_version bigint,
  p_day date default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  sid uuid := public.nohut_jwt_claim('session_id')::uuid;
  u nohut_private.app_users;
  target_day date := coalesce(p_day, (clock_timestamp() at time zone 'Europe/Istanbul')::date);
  r nohut_private.daily_report_summaries;
  can_sales boolean;
  can_finance boolean;
  fresh jsonb;
  is_stale boolean;
  eff_prelim boolean;
  eff_reason text;
  rep jsonb;
  orders_in jsonb;
  platforms_out jsonb;
  orders_out jsonb;
  open_in jsonb;
  open_out jsonb;
  top_in jsonb;
  top_out jsonb;
  out_report jsonb;
begin
  if p_client is distinct from 'yonetici' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if nohut_private.authorize(uid, sid, p_device_id, p_client, 'dashboard.view', p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into u from nohut_private.app_users where user_id = uid;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;

  can_sales := nohut_private.authorize(uid, sid, p_device_id, p_client, 'sales.view', p_permission_version) = 'ok';
  can_finance := nohut_private.authorize(uid, sid, p_device_id, p_client, 'finance.view', p_permission_version) = 'ok';

  select * into r from nohut_private.daily_report_summaries
    where restaurant_id = u.restaurant_id and business_day = target_day;

  fresh := nohut_private.projection_freshness(u.restaurant_id, 'daily_reports', r.source_revision, r.calculated_at);
  if not found then
    return jsonb_build_object(
      'available', false,
      'day', to_char(target_day, 'YYYY-MM-DD'),
      'syncMeta', fresh
    );
  end if;

  is_stale := coalesce((fresh->>'stale')::boolean, true);
  rep := r.report_payload;
  eff_prelim := r.is_preliminary or coalesce((rep->>'preliminary')::boolean, false) or is_stale;
  eff_reason := coalesce(nullif(rep->>'preliminaryReason', ''), case when is_stale then 'Veriler güncel değil' else null end);

  -- Build orders strictly via allowlist
  orders_in := coalesce(rep->'orders', '{}'::jsonb);
  if jsonb_typeof(orders_in->'platforms') = 'array' then
    select coalesce(jsonb_agg(
      case when can_sales then
        jsonb_strip_nulls(jsonb_build_object(
          'source', p->'source',
          'orders', p->'orders',
          'grossCents', p->'grossCents',
          'estimatedNetCents', p->'estimatedNetCents'
        ))
      else
        jsonb_strip_nulls(jsonb_build_object(
          'source', p->'source',
          'orders', p->'orders'
        ))
      end
    ), '[]'::jsonb) into platforms_out
    from jsonb_array_elements(orders_in->'platforms') p;
  else
    platforms_out := '[]'::jsonb;
  end if;

  orders_out := jsonb_build_object(
    'total', orders_in->'total',
    'masa', orders_in->'masa',
    'gelAl', orders_in->'gelAl',
    'online', orders_in->'online',
    'cancelled', orders_in->'cancelled',
    'platforms', platforms_out
  );
  if can_sales and orders_in ? 'averageCents' then
    orders_out := orders_out || jsonb_build_object('averageCents', orders_in->'averageCents');
  end if;

  -- Build openAccounts strictly via allowlist
  open_in := coalesce(rep->'openAccounts', '{}'::jsonb);
  open_out := jsonb_build_object('count', open_in->'count');
  if can_sales and open_in ? 'dueCents' then
    open_out := open_out || jsonb_build_object('dueCents', open_in->'dueCents');
  end if;

  -- Build topProduct strictly via allowlist
  if jsonb_typeof(rep->'topProduct') = 'object' then
    top_in := rep->'topProduct';
    top_out := jsonb_build_object('name', top_in->'name', 'qty', top_in->'qty');
    if can_sales and top_in ? 'cents' then
      top_out := top_out || jsonb_build_object('cents', top_in->'cents');
    end if;
  else
    top_out := null;
  end if;

  -- Assemble base report (always allowed with dashboard.view)
  out_report := jsonb_build_object(
    'businessDate', coalesce(rep->>'businessDate', to_char(r.business_day, 'YYYY-MM-DD')),
    'generatedAt', rep->'generatedAt',
    'closingTime', rep->'closingTime',
    'closed', rep->'closed',
    'preliminary', eff_prelim,
    'preliminaryReason', eff_reason,
    'orders', orders_out,
    'openAccounts', open_out,
    'topProduct', top_out,
    'peakHour', rep->'peakHour'
  );

  if not can_sales then
    out_report := out_report || jsonb_build_object('amountsHidden', true);
  else
    if rep ? 'sales' then out_report := out_report || jsonb_build_object('sales', rep->'sales'); end if;
    if rep ? 'comparison' then out_report := out_report || jsonb_build_object('comparison', rep->'comparison'); end if;
    if rep ? 'hourlyCents' then out_report := out_report || jsonb_build_object('hourlyCents', rep->'hourlyCents'); end if;
    if rep ? 'collections' then out_report := out_report || jsonb_build_object('collections', rep->'collections'); end if;
    if can_finance then
      if rep ? 'expenses' then out_report := out_report || jsonb_build_object('expenses', rep->'expenses'); end if;
      if rep ? 'estimatedResultCents' then out_report := out_report || jsonb_build_object('estimatedResultCents', rep->'estimatedResultCents'); end if;
      if rep ? 'estimateNote' then out_report := out_report || jsonb_build_object('estimateNote', rep->'estimateNote'); end if;
    end if;
  end if;

  return jsonb_build_object(
    'available', true,
    'day', to_char(r.business_day, 'YYYY-MM-DD'),
    'preliminary', eff_prelim,
    'permissions', jsonb_build_object('sales', can_sales, 'finance', can_finance),
    'report', out_report,
    'syncMeta', fresh
  );
end $$;

-- 6. Hardened public.nohut_notifications_list (full unreadCount across all visible items + provenance syncMeta)
create or replace function public.nohut_notifications_list(
  p_device_id uuid,
  p_client text,
  p_permission_version bigint,
  p_limit integer default 50
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  sid uuid := public.nohut_jwt_claim('session_id')::uuid;
  u nohut_private.app_users;
  lim integer := greatest(1, least(coalesce(p_limit, 50), 100));
  items_json jsonb;
  unread_cnt integer;
  fresh jsonb;
begin
  if nohut_private.authorize(uid, sid, p_device_id, p_client, 'menu.view', p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into u from nohut_private.app_users where user_id = uid;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;

  with all_visible as (
    select n.*, (r.read_at is not null) as is_read, r.read_at
      from nohut_private.cloud_notifications n
      left join nohut_private.notification_reads r
        on r.restaurant_id = n.restaurant_id and r.user_id = uid and r.notification_id = n.notification_id
     where n.restaurant_id = u.restaurant_id
       and p_client = any(n.allowed_clients)
       and (n.recipient_employee_local_id is null or n.recipient_employee_local_id = u.pos_employee_id)
       and (
         n.required_permission is null
         or nohut_private.authorize(uid, sid, p_device_id, p_client, n.required_permission, p_permission_version) = 'ok'
       )
  ), paged as (
    select * from all_visible order by created_at desc limit lim
  )
  select
    coalesce((select jsonb_agg(jsonb_build_object(
      'id', p.notification_id,
      'category', p.category,
      'severity', p.severity,
      'title', p.title,
      'body', p.body,
      'deepLink', p.deep_link,
      'createdAt', p.created_at,
      'read', p.is_read,
      'readAt', p.read_at
    ) order by p.created_at desc) from paged p), '[]'::jsonb),
    (select count(*) from all_visible a where not a.is_read)
  into items_json, unread_cnt;

  fresh := nohut_private.projection_freshness(u.restaurant_id, 'notifications');
  return jsonb_build_object(
    'items', items_json,
    'unreadCount', coalesce(unread_cnt, 0),
    'syncMeta', fresh
  );
end $$;

-- 7. Wire provenance-bound freshness into workforce & QR read RPCs
create or replace function public.nohut_workforce_own_week(
  p_device_id uuid, p_client text, p_permission_version bigint, p_week_start date default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  u nohut_private.app_users;
  eid uuid;
  emp nohut_private.employees;
  today_day date := (clock_timestamp() at time zone 'Europe/Istanbul')::date;
  ws date;
  we date;
  s nohut_private.weekly_workforce_summaries;
  can_pay boolean;
  plans_json jsonb;
  work_json jsonb;
  pay_json jsonb;
  status_json jsonb;
  fresh jsonb;
begin
  if nohut_private.authorize(auth.uid(), public.nohut_jwt_claim('session_id')::uuid,
      p_device_id, p_client, 'shifts.self', p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into u from nohut_private.app_users where user_id = auth.uid();
  if not found or u.pos_employee_id is null then
    raise exception 'actor not linked' using errcode = '42501';
  end if;
  select employee_id into eid from nohut_private.employee_source_ids
    where restaurant_id = u.restaurant_id and local_id = u.pos_employee_id;
  if not found then
    raise exception 'actor not linked' using errcode = '42501';
  end if;
  select * into emp from nohut_private.employees
    where restaurant_id = u.restaurant_id and employee_id = eid;

  ws := nohut_private.monday_of(coalesce(p_week_start, today_day));
  we := ws + 6;

  select * into s from nohut_private.weekly_workforce_summaries
    where restaurant_id = u.restaurant_id and employee_id = eid and week_start = ws;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.plan_id,
    'date', to_char(p.planned_day, 'YYYY-MM-DD'),
    'start', lpad((p.start_minute / 60)::text, 2, '0') || ':' || lpad((p.start_minute % 60)::text, 2, '0'),
    'end', lpad((p.end_minute / 60)::text, 2, '0') || ':' || lpad((p.end_minute % 60)::text, 2, '0'),
    'endsNextDay', p.ends_next_day,
    'dayOff', p.day_off,
    'breakMinutes', p.break_minutes,
    'note', p.note,
    'cancelled', p.cancelled
  ) order by p.planned_day, p.start_minute), '[]'::jsonb)
  into plans_json
  from nohut_private.shift_plans p
  where p.restaurant_id = u.restaurant_id and p.employee_id = eid
    and p.planned_day between ws and we and not p.cancelled;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', sh.shift_id,
    'start', sh.started_at,
    'end', sh.ended_at,
    'source', sh.source,
    'breakMinutes', sh.break_minutes,
    'note', sh.note,
    'voided', sh.voided
  ) order by sh.started_at), '[]'::jsonb)
  into work_json
  from nohut_private.shifts sh
  where sh.restaurant_id = u.restaurant_id and sh.employee_id = eid
    and not sh.voided
    and (sh.started_at at time zone 'Europe/Istanbul')::date between ws and we;

  can_pay := nohut_private.authorize(auth.uid(), public.nohut_jwt_claim('session_id')::uuid,
    p_device_id, p_client, 'payroll.self.view', p_permission_version) = 'ok';

  if can_pay and s.employee_id is not null then
    pay_json := jsonb_build_object(
      'payrollEligible', s.payroll_eligible,
      'payType', s.pay_type,
      'rateCents', s.rate_kurus,
      'earnedCents', s.earned_kurus,
      'paidCents', s.paid_kurus,
      'advanceCents', s.advance_kurus,
      'overpaidCents', s.overpaid_kurus,
      'remainingCents', s.remaining_kurus,
      'missingRateMinutes', s.missing_rate_minutes,
      'rateComplete', s.rate_complete,
      'financialStatus', s.financial_status,
      'reviewStatus', s.review_status,
      'dueDate', to_char(s.due_date, 'YYYY-MM-DD'),
      'overdue', s.overdue,
      'lastPaidOn', case when s.last_paid_on is null then null else to_char(s.last_paid_on, 'YYYY-MM-DD') end
    );
  else
    pay_json := null;
  end if;

  status_json := jsonb_build_object(
    'submission', coalesce(s.submission_status, 'Taslak'),
    'submittedAt', s.submitted_at,
    'workedMinutes', coalesce(s.worked_minutes, 0),
    'plannedMinutes', coalesce(s.planned_minutes, 0)
  );

  fresh := nohut_private.projection_freshness(u.restaurant_id, 'workforce_summaries', s.source_revision, s.calculated_at);

  return jsonb_build_object(
    'employee', jsonb_build_object(
      'id', u.pos_employee_id,
      'name', emp.display_name,
      'active', emp.active
    ),
    'week', jsonb_build_object(
      'weekStart', to_char(ws, 'YYYY-MM-DD'),
      'weekEnd', to_char(we, 'YYYY-MM-DD'),
      'plans', plans_json,
      'work', work_json,
      'status', status_json,
      'pay', pay_json
    ),
    'syncMeta', fresh
  );
end $$;

create or replace function public.nohut_team_schedule(
  p_device_id uuid, p_client text, p_permission_version bigint,
  p_from date default null, p_to date default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  u nohut_private.app_users;
  today_day date := (clock_timestamp() at time zone 'Europe/Istanbul')::date;
  d_from date := coalesce(p_from, nohut_private.monday_of(today_day));
  d_to date := coalesce(p_to, d_from + 6);
  plans_json jsonb;
  fresh jsonb;
begin
  if nohut_private.authorize(auth.uid(), public.nohut_jwt_claim('session_id')::uuid,
      p_device_id, p_client, 'shifts.self', p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into u from nohut_private.app_users where user_id = auth.uid();
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;
  if d_to < d_from or d_to - d_from > 62 then
    raise exception 'invalid schedule range' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'employeeName', p.employee_label,
    'date', to_char(p.planned_day, 'YYYY-MM-DD'),
    'start', case when p.day_off then null else lpad((p.start_minute / 60)::text, 2, '0') || ':' || lpad((p.start_minute % 60)::text, 2, '0') end,
    'end', case when p.day_off then null else lpad((p.end_minute / 60)::text, 2, '0') || ':' || lpad((p.end_minute % 60)::text, 2, '0') end,
    'endsNextDay', p.ends_next_day,
    'dayOff', p.day_off
  ) order by p.planned_day, p.start_minute, p.employee_label), '[]'::jsonb)
  into plans_json
  from nohut_private.shift_plans p
  where p.restaurant_id = u.restaurant_id
    and p.planned_day between d_from and d_to
    and not p.cancelled;

  fresh := nohut_private.projection_freshness(u.restaurant_id, 'shift_plans');
  return jsonb_build_object(
    'from', to_char(d_from, 'YYYY-MM-DD'),
    'to', to_char(d_to, 'YYYY-MM-DD'),
    'plans', plans_json,
    'syncMeta', fresh
  );
end $$;

create or replace function public.nohut_payroll_week(
  p_device_id uuid, p_client text, p_permission_version bigint, p_week_start date default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  u nohut_private.app_users;
  today_day date := (clock_timestamp() at time zone 'Europe/Istanbul')::date;
  ws date := nohut_private.monday_of(coalesce(p_week_start, today_day));
  we date := ws + 6;
  rows_json jsonb;
  payments_json jsonb;
  max_rev bigint;
  max_calc timestamptz;
  fresh jsonb;
begin
  if nohut_private.authorize(auth.uid(), public.nohut_jwt_claim('session_id')::uuid,
      p_device_id, p_client, 'payroll.view', p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into u from nohut_private.app_users where user_id = auth.uid();
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;

  select max(s.source_revision), max(s.calculated_at)
    into max_rev, max_calc
    from nohut_private.weekly_workforce_summaries s
   where s.restaurant_id = u.restaurant_id and s.week_start = ws;

  select coalesce(jsonb_agg(jsonb_build_object(
    'employeeId', s.employee_local_id,
    'employeeName', s.employee_name,
    'active', coalesce(e.active, false),
    'weekStart', to_char(s.week_start, 'YYYY-MM-DD'),
    'weekEnd', to_char(s.week_end, 'YYYY-MM-DD'),
    'dueDate', to_char(s.due_date, 'YYYY-MM-DD'),
    'workedMinutes', s.worked_minutes,
    'plannedMinutes', s.planned_minutes,
    'missingRateMinutes', s.missing_rate_minutes,
    'rateComplete', s.rate_complete,
    'payType', s.pay_type,
    'rateCents', s.rate_kurus,
    'earnedCents', s.earned_kurus,
    'paidCents', s.paid_kurus,
    'advanceCents', s.advance_kurus,
    'overpaidCents', s.overpaid_kurus,
    'remainingCents', s.remaining_kurus,
    'financialStatus', s.financial_status,
    'reviewStatus', s.review_status,
    'submissionStatus', s.submission_status,
    'submittedAt', s.submitted_at,
    'overdue', s.overdue,
    'legacy', s.legacy,
    'lastPaidOn', case when s.last_paid_on is null then null else to_char(s.last_paid_on, 'YYYY-MM-DD') end
  ) order by s.employee_name, s.employee_local_id), '[]'::jsonb)
  into rows_json
  from nohut_private.weekly_workforce_summaries s
  left join nohut_private.employees e
    on e.restaurant_id = s.restaurant_id and e.employee_id = s.employee_id
  where s.restaurant_id = u.restaurant_id
    and s.week_start = ws
    and (s.payroll_eligible or s.paid_kurus > 0 or s.legacy)
    and (coalesce(e.active, false) or s.worked_minutes > 0 or s.paid_kurus <> 0);

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.source_reference,
    'employeeId', x.local_id,
    'employeeName', p.employee_name_at_record,
    'weekStart', to_char(p.week_start, 'YYYY-MM-DD'),
    'paidOn', to_char(p.paid_on, 'YYYY-MM-DD'),
    'kind', p.kind,
    'method', p.method,
    'cashCents', p.cash_kurus,
    'bankCents', p.bank_kurus,
    'amountCents', p.amount_kurus,
    'reverses', orig.source_reference,
    'note', p.note,
    'createdAt', p.recorded_at,
    'createdBy', p.actor_label
  ) order by p.recorded_at, p.source_reference), '[]'::jsonb)
  into payments_json
  from nohut_private.payroll_payments p
  join nohut_private.employee_source_ids x
    on x.restaurant_id = p.restaurant_id and x.employee_id = p.employee_id
  left join nohut_private.payroll_payments orig
    on orig.restaurant_id = p.restaurant_id and orig.payment_id = p.reverses_id
  where p.restaurant_id = u.restaurant_id and p.week_start = ws;

  fresh := nohut_private.projection_freshness(u.restaurant_id, 'workforce_summaries', max_rev, max_calc);

  return jsonb_build_object(
    'ok', true,
    'weekStart', to_char(ws, 'YYYY-MM-DD'),
    'weekEnd', to_char(we, 'YYYY-MM-DD'),
    'today', to_char(today_day, 'YYYY-MM-DD'),
    'rows', rows_json,
    'payments', payments_json,
    'syncMeta', fresh
  );
end $$;

create or replace function public.nohut_qr_menu_view(
  p_device_id uuid, p_client text, p_permission_version bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  sid uuid := public.nohut_jwt_claim('session_id')::uuid;
  u nohut_private.app_users;
  q nohut_private.qr_menu_state;
  can_map jsonb;
  fresh jsonb;
  out_obj jsonb;
begin
  if nohut_private.authorize(uid, sid, p_device_id, p_client, 'menu.view', p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into u from nohut_private.app_users where user_id = uid;
  if not found then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  can_map := jsonb_build_object(
    'menu.product.edit', nohut_private.authorize(uid, sid, p_device_id, p_client, 'menu.product.edit', p_permission_version) = 'ok',
    'menu.price.edit', nohut_private.authorize(uid, sid, p_device_id, p_client, 'menu.price.edit', p_permission_version) = 'ok',
    'menu.category.edit', nohut_private.authorize(uid, sid, p_device_id, p_client, 'menu.category.edit', p_permission_version) = 'ok',
    'menu.campaign.edit', nohut_private.authorize(uid, sid, p_device_id, p_client, 'menu.campaign.edit', p_permission_version) = 'ok',
    'menu.stock.toggle', nohut_private.authorize(uid, sid, p_device_id, p_client, 'menu.stock.toggle', p_permission_version) = 'ok',
    'menu.qr.publish', nohut_private.authorize(uid, sid, p_device_id, p_client, 'menu.qr.publish', p_permission_version) = 'ok'
  );

  select * into q from nohut_private.qr_menu_state where restaurant_id = u.restaurant_id;
  fresh := nohut_private.projection_freshness(u.restaurant_id, 'qr_menu_state', q.source_revision, q.calculated_at);

  if not found or not q.available then
    return jsonb_build_object(
      'available', false,
      'can', can_map,
      'message', 'Menü henüz Windows’ta yüklenmedi. Windows › QR Menü Yönetimi sayfasını açıp GitHub’a bağlanınca burada görünür.',
      'syncMeta', fresh
    );
  end if;

  out_obj := jsonb_build_object(
    'available', true,
    'stamp', q.draft_stamp,
    'revision', q.revision,
    'revisionLabel', q.revision_label,
    'offline', q.offline,
    'pendingPublish', q.pending_publish,
    'can', can_map,
    'publish', case when q.link_status is null then 'windows' else 'here' end,
    'changes', q.changes,
    'catalog', q.catalog,
    'recentAudit', q.recent_audit,
    'syncMeta', fresh
  );
  if q.link_status is not null then
    out_obj := out_obj || jsonb_build_object('link', q.link_status);
  end if;
  return out_obj;
end $$;

-- 8. Align qr_menu_reconcile ({targetRequestId, mode}, deny legacy {}) and qr_menu_publish (optional draftSha256)
create or replace function nohut_private.validate_command_payload(p_action text, p jsonb)
returns void language plpgsql immutable set search_path = '' as $$
declare
  line jsonb;
  action text := p->>'action';
  required_fields jsonb;
  optional_fields jsonb := '{}';
  k text;
  v jsonb;
  stamp text;
  sha text;
  img_path text;
begin
  if p is null or octet_length(p::text) > 65536 then
    raise exception 'invalid command size' using errcode = '22023';
  end if;
  if nohut_private.contains_forbidden_secret_key(p) then
    raise exception 'credentials forbidden in command' using errcode = '42501';
  end if;
  if p_action ~ '^(sync_|backup_|restore_)' or p_action in ('first_sync', 'full_resync') then
    raise exception 'windows_only' using errcode = '42501';
  end if;

  if p_action in ('create_order', 'add_order_items') then
    required_fields := '{"expectedRevision":"integer","source":"string","lines":"array"}';
    if p_action = 'add_order_items' then required_fields := required_fields || '{"orderId":"integer"}'; end if;
    optional_fields := '{"table":"nullable_integer","pickupChannel":"string","customer":"object","expectedTableOrderId":"nullable_integer"}';
  elsif p_action in ('record_payment','split_bill','move_order','close_order','mark_delivered','edit_order_line','delete_order','print_payment_receipt') then
    required_fields := '{"expectedRevision":"integer","orderId":"integer","action":"string"}';
    case p_action
      when 'record_payment' then
        if action not in ('pay','payMixed','payProducts') or action is null then raise exception 'action mismatch' using errcode = '22023'; end if;
        required_fields := required_fields || '{"amountCents":"integer","confirmed":"boolean"}';
        optional_fields := '{"guestId":"nullable_integer","receivedCents":"nullable_integer"}';
        if action = 'payMixed' then required_fields := required_fields || '{"cashCents":"integer","printReceipt":"boolean"}';
        else required_fields := required_fields || '{"method":"string"}'; end if;
        if action = 'pay' then required_fields := required_fields || '{"printReceipt":"boolean"}'; end if;
        if action = 'payProducts' then required_fields := required_fields || '{"shares":"object"}'; optional_fields := optional_fields || '{"cashCents":"nullable_integer"}'; end if;
      when 'split_bill' then
        case action
          when 'splitEqual' then required_fields := required_fields || '{"count":"integer"}';
          when 'addGuest' then required_fields := required_fields || '{"name":"string"}';
          when 'allocate' then required_fields := required_fields || '{"guestId":"integer","key":"string","cents":"integer"}';
          when 'resetGuests' then null;
          else raise exception 'action mismatch' using errcode = '22023';
        end case;
      when 'move_order' then
        if action is distinct from 'move' then raise exception 'action mismatch' using errcode = '22023'; end if;
        required_fields := required_fields || '{"table":"integer"}';
      when 'close_order' then if action is distinct from 'close' then raise exception 'action mismatch' using errcode = '22023'; end if;
      when 'mark_delivered' then if action is distinct from 'status' then raise exception 'action mismatch' using errcode = '22023'; end if;
      when 'edit_order_line' then
        if action is distinct from 'editLine' then raise exception 'action mismatch' using errcode = '22023'; end if;
        required_fields := required_fields || '{"key":"string","qty":"integer","note":"string","removed":"array"}';
        optional_fields := '{"adjustmentCents":"integer","components":"array"}';
      when 'delete_order' then
        if action is distinct from 'delete' then raise exception 'action mismatch' using errcode = '22023'; end if;
        required_fields := required_fields || '{"confirmed":"boolean","reason":"string"}';
      when 'print_payment_receipt' then
        if action is distinct from 'printProductPayment' then raise exception 'action mismatch' using errcode = '22023'; end if;
        required_fields := required_fields || '{"paymentId":"string"}';
    end case;
  elsif p_action = 'clock_in_out' then
    required_fields := '{"action":"string"}';
    if action is null or action not in ('clockIn','clockOut') then raise exception 'action mismatch' using errcode = '22023'; end if;
  elsif p_action = 'correct_shift' then
    required_fields := '{"shiftId":"string","reason":"string"}';
    optional_fields := '{"start":"string","end":"nullable_string"}';
  elsif p_action = 'retry_print' then
    required_fields := '{"target":"string","checked":"boolean"}';
    case p->>'target'
      when 'kitchen' then required_fields := required_fields || '{"orderId":"integer","batchId":"integer"}';
      when 'payment' then required_fields := required_fields || '{"receiptRequestId":"string"}';
      when 'platform' then required_fields := required_fields || '{"orderKey":"string"}';
      else raise exception 'invalid print target' using errcode = '22023';
    end case;
  elsif p_action = 'set_product_sale' then
    required_fields := '{"productId":"integer","active":"boolean"}';
  elsif p_action = 'platform_action' then
    required_fields := '{"action":"string","packageId":"string"}';
    optional_fields := '{"preparationMinutes":"integer"}';
    if action is null or action not in ('accept','ready') then raise exception 'action mismatch' using errcode = '22023'; end if;
  elsif p_action = 'qr_menu_write' then
    required_fields := '{"expectedStamp":"string","action":"string"}';
    case action
      when 'set_price' then
        required_fields := required_fields || '{"id":"string","priceCents":"integer"}';
      when 'set_stock' then
        required_fields := required_fields || '{"id":"string","available":"boolean"}';
      when 'set_visible' then
        required_fields := required_fields || '{"id":"string","active":"boolean"}';
      when 'set_image' then
        required_fields := required_fields || '{"id":"string","image":"string"}';
        optional_fields := '{"target":"string"}';
      when 'save_product' then
        required_fields := required_fields || '{"category":"string","name":"object","priceCents":"integer","available":"boolean","active":"boolean"}';
        optional_fields := '{"id":"string","displayName":"object","description":"object","image":"nullable_string","order":"integer"}';
      when 'save_category' then
        required_fields := required_fields || '{"name":"object","active":"boolean"}';
        optional_fields := '{"id":"string","description":"object","order":"integer"}';
      when 'save_campaign' then
        required_fields := required_fields || '{"title":"object","priceCents":"integer","active":"boolean"}';
        optional_fields := '{"id":"string","description":"object","poster":"nullable_string","thumbnail":"nullable_string"}';
      else
        raise exception 'action mismatch' using errcode = '22023';
    end case;
  elsif p_action = 'qr_menu_publish' then
    required_fields := '{"expectedStamp":"string","confirmed":"boolean"}';
    optional_fields := '{"draftSha256":"string","expectedRevision":"nullable_string"}';
  elsif p_action = 'qr_menu_reconcile' then
    -- Aligned with PR #49 & Claude aea2861: exact {targetRequestId, mode}, denies legacy {}.
    required_fields := '{"targetRequestId":"string","mode":"string"}';
  elsif p_action = 'qr_menu_sync' then
    required_fields := '{}';
  elsif p_action = 'qr_menu_image' then
    required_fields := '{"expectedStamp":"string","id":"string","mime":"string"}';
    optional_fields := '{"storagePath":"string","base64":"string","sizeBytes":"integer","target":"string"}';
  else
    raise exception 'unsupported action' using errcode = '42501';
  end if;

  perform nohut_private.command_shape(p, required_fields, optional_fields);
  if p ? 'expectedRevision' and jsonb_typeof(p->'expectedRevision') = 'number' and (p->>'expectedRevision')::bigint < 0 then
    raise exception 'invalid revision' using errcode = '22023';
  end if;
  if p ? 'table' and p->'table' <> 'null'::jsonb and (p->>'table')::bigint not between 1 and 5 then raise exception 'invalid table' using errcode = '22023'; end if;
  if p ? 'orderId' and (p->>'orderId')::bigint < 1 then raise exception 'invalid order' using errcode = '22023'; end if;
  if p ? 'confirmed' and p->'confirmed' <> 'true'::jsonb then raise exception 'confirmation required' using errcode = '22023'; end if;

  if p_action in ('create_order', 'add_order_items') then
    if p->>'source' not in ('Masa','Gel-Al') or (p->>'source' = 'Masa' and (p->'table' is null or p->'table' = 'null'::jsonb))
      or (p->>'source' = 'Gel-Al' and p->'table' is not null and p->'table' <> 'null'::jsonb)
      or jsonb_array_length(p->'lines') not between 1 and 200 then raise exception 'invalid order' using errcode = '22023'; end if;
    if p ? 'pickupChannel' and p->>'pickupChannel' not in ('Tezgahtan','Telefon') then raise exception 'invalid pickup channel' using errcode = '22023'; end if;
    if p ? 'customer' then
      perform nohut_private.command_shape(p->'customer','{}','{"time":"string"}');
      if length(coalesce(p->'customer'->>'time','')) > 40 then raise exception 'invalid pickup time' using errcode = '22023'; end if;
    end if;
    for line in select * from jsonb_array_elements(p->'lines') loop perform nohut_private.command_line(line); end loop;
  elsif p_action = 'record_payment' then
    if (p->>'amountCents')::bigint not between 1 and 100000000000 or p->'confirmed' <> 'true'::jsonb then raise exception 'invalid payment' using errcode = '22023'; end if;
    if p ? 'method' and p->>'method' not in ('Nakit','Kart','Karışık') then raise exception 'invalid payment method' using errcode = '22023'; end if;
    if action = 'pay' and p->>'method' = 'Karışık' then raise exception 'mixed payment route required' using errcode = '22023'; end if;
    if action = 'payMixed' or p->>'method' = 'Karışık' then
      if p->>'cashCents' is null or (p->>'cashCents')::bigint <= 0 or (p->>'cashCents')::bigint >= (p->>'amountCents')::bigint then raise exception 'invalid mixed payment' using errcode = '22023'; end if;
    end if;
    if p ? 'receivedCents' and (p->>'receivedCents')::bigint < 0 then raise exception 'invalid received cash' using errcode = '22023'; end if;
    if action = 'payProducts' then
      if (select count(*) from jsonb_object_keys(p->'shares')) not between 1 and 200 then raise exception 'invalid shares' using errcode = '22023'; end if;
      for k, v in select * from jsonb_each(p->'shares') loop
        perform nohut_private.command_shape(jsonb_build_object('cents', v), '{"cents":"integer"}');
        if length(k) > 200 or (v::text)::bigint <= 0 then raise exception 'invalid product share' using errcode = '22023'; end if;
      end loop;
    end if;
  elsif p_action = 'split_bill' then
    if action = 'splitEqual' and (p->>'count')::bigint not between 2 and 100 then raise exception 'invalid split count' using errcode = '22023'; end if;
    if action = 'allocate' and (p->>'cents')::bigint < 0 then raise exception 'invalid allocation' using errcode = '22023'; end if;
    if action = 'addGuest' and length(p->>'name') > 100 then raise exception 'guest name too long' using errcode = '22023'; end if;
  elsif p_action = 'correct_shift' then
    if length(trim(p->>'reason')) not between 1 and 300 then raise exception 'correction reason required' using errcode = '22023'; end if;
    if p ? 'start' then perform nohut_private.shift_timestamp(p->'start'); end if;
    if p ? 'end' then perform nohut_private.shift_timestamp(p->'end'); end if;
  elsif p_action = 'retry_print' and p->'checked' <> 'true'::jsonb then
    raise exception 'printer check required' using errcode = '22023';
  elsif p_action = 'platform_action' then
    if length(trim(p->>'packageId')) not between 1 and 200 or
      (p ? 'preparationMinutes' and (p->>'preparationMinutes')::bigint not between 1 and 180) then raise exception 'invalid platform target' using errcode = '22023'; end if;
  elsif p_action = 'edit_order_line' then
    if (p->>'qty')::bigint not between 0 and 1000 or length(p->>'note') > 500 then raise exception 'invalid line edit' using errcode = '22023'; end if;
    perform nohut_private.command_removed(p->'removed');
    if p ? 'components' then
      perform nohut_private.command_line(jsonb_build_object('productId', 0, 'qty', 1, 'components', p->'components'));
    end if;
  elsif p_action = 'qr_menu_reconcile' then
    if (p->>'targetRequestId') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'invalid targetRequestId' using errcode = '22023';
    end if;
    if (p->>'mode') not in ('reconcile', 'cancel_before_attempt') then
      raise exception 'invalid reconcile mode' using errcode = '22023';
    end if;
  elsif p_action in ('qr_menu_write', 'qr_menu_publish', 'qr_menu_image') then
    stamp := p->>'expectedStamp';
    if stamp is null or stamp !~ '^[0-9a-f]{16}$' then
      raise exception 'invalid expectedStamp' using errcode = '22023';
    end if;
    if p_action = 'qr_menu_publish' and p ? 'draftSha256' then
      sha := p->>'draftSha256';
      if sha !~ '^[0-9a-f]{64}$' or left(sha, 16) <> stamp then
        raise exception 'draftSha256 mismatch with expectedStamp' using errcode = '22023';
      end if;
    elsif p_action = 'qr_menu_write' then
      if p ? 'priceCents' and (p->>'priceCents')::bigint not between 0 and 10000000 then
        raise exception 'invalid qr price' using errcode = '22023';
      end if;
      if p ? 'id' and length(trim(p->>'id')) not between 1 and 120 then
        raise exception 'invalid qr entity id' using errcode = '22023';
      end if;
      if action = 'set_image' then
        img_path := p->>'image';
        if img_path !~ '^assets/[A-Za-z0-9_./-]+\.(png|jpg|jpeg|webp)$' or position('..' in img_path) > 0 then
          raise exception 'invalid qr image path' using errcode = '22023';
        end if;
      end if;
    elsif p_action = 'qr_menu_image' then
      if p->>'mime' not in ('image/png', 'image/jpeg', 'image/webp') then
        raise exception 'unsupported image mime' using errcode = '22023';
      end if;
      if length(trim(p->>'id')) not between 1 and 120 then
        raise exception 'invalid qr entity id' using errcode = '22023';
      end if;
      if not (p ? 'storagePath' or p ? 'base64') then
        raise exception 'image payload required' using errcode = '22023';
      end if;
      if p ? 'storagePath' then
        img_path := p->>'storagePath';
        if img_path !~ '^qr-uploads/[A-Za-z0-9_-]+\.(png|jpg|jpeg|webp)$' or position('..' in img_path) > 0 then
          raise exception 'invalid image storagePath' using errcode = '22023';
        end if;
      end if;
      if p ? 'sizeBytes' and (p->>'sizeBytes')::bigint not between 1 and 6291456 then
        raise exception 'image exceeds 6MB limit' using errcode = '22023';
      end if;
    end if;
  end if;

  perform nohut_private.canonical_command_json(p);
end $$;

commit;
