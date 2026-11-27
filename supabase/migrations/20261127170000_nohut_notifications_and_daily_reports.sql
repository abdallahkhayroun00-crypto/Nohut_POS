-- Increment C (Cloud Synchronization — Notifications & Gün Sonu Raporu Read Projections):
-- 1. Private nohut_private.cloud_notifications + nohut_private.notification_reads (FORCE RLS,
--    owner-only policy, zero direct client grants). Supports permission-filtered listing,
--    personal recipient scoping (recipient_employee_id), and per-user read acknowledgements.
-- 2. Private nohut_private.daily_report_summaries (FORCE RLS, owner-only policy).
--    Strictly enforces owner decision (QA-05 superseded): staffHours is FORBIDDEN in Gün Sonu Raporu.
-- 3. Extends nohut_private.ingest_sync_transaction for entity_type in ('notifications', 'dailyReports').
-- 4. Authenticated RPCs:
--      * public.nohut_notifications_list(p_device_id, p_client, p_permission_version, p_limit)
--      * public.nohut_notification_mark_read(p_device_id, p_client, p_permission_version, p_notification_ids)
--      * public.nohut_daily_report_view(p_device_id, p_client, p_permission_version, p_day)
begin;

-- 1. Cloud notifications projection & per-user read state
create table nohut_private.cloud_notifications (
  restaurant_id uuid not null references nohut_private.restaurants,
  notification_id text not null check (length(trim(notification_id)) between 1 and 160),
  category text not null check (length(trim(category)) between 1 and 80),
  severity text not null check (severity in ('info', 'warning', 'urgent')),
  required_permission text check (required_permission is null or required_permission ~ '^[a-z]+(\.[a-z_]+)+$'),
  allowed_clients text[] not null check (allowed_clients <@ array['windows','personel','yonetici']::text[] and cardinality(allowed_clients) > 0),
  recipient_employee_local_id integer,
  title text not null check (length(trim(title)) between 1 and 200),
  body text not null default '' check (length(body) <= 1000),
  deep_link text check (deep_link is null or length(deep_link) <= 200),
  created_at timestamptz not null,
  source_revision bigint not null check (source_revision > 0),
  updated_at timestamptz not null default now(),
  primary key (restaurant_id, notification_id)
);

create index cloud_notifications_recent_idx
  on nohut_private.cloud_notifications (restaurant_id, created_at desc);

create table nohut_private.notification_reads (
  restaurant_id uuid not null references nohut_private.restaurants,
  user_id uuid not null references nohut_private.app_users(user_id) on delete cascade,
  notification_id text not null,
  read_at timestamptz not null default now(),
  primary key (restaurant_id, user_id, notification_id),
  foreign key (restaurant_id, notification_id)
    references nohut_private.cloud_notifications(restaurant_id, notification_id) on delete cascade
);

-- 2. Authoritative Gün Sonu Raporu (daily_report_summaries) — strictly NO staffHours
create table nohut_private.daily_report_summaries (
  restaurant_id uuid not null references nohut_private.restaurants,
  business_day date not null,
  is_preliminary boolean not null default true,
  report_payload jsonb not null check (
    jsonb_typeof(report_payload) = 'object'
    and not (report_payload ? 'staffHours')
    and not (report_payload ? 'workingHours')
  ),
  calculated_at timestamptz not null,
  source_revision bigint not null check (source_revision > 0),
  updated_at timestamptz not null default now(),
  primary key (restaurant_id, business_day)
);

do $$
declare t text;
begin
  foreach t in array array['cloud_notifications', 'notification_reads', 'daily_report_summaries'] loop
    execute format('alter table nohut_private.%I enable row level security', t);
    execute format('alter table nohut_private.%I force row level security', t);
    execute format('create policy %I on nohut_private.%I for all to %I using(true) with check(true)',
      t || '_owner', t, current_user);
    execute format('revoke all on table nohut_private.%I from public, anon, authenticated, service_role', t);
  end loop;
end $$;

-- 3. Projection helpers
create function nohut_private.apply_notifications_projection(
  p_restaurant uuid,
  p_revision bigint,
  p_payload jsonb
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
end $$;
revoke all on function nohut_private.apply_notifications_projection(uuid, bigint, jsonb)
  from public, anon, authenticated, service_role;

create function nohut_private.apply_daily_report_projection(
  p_restaurant uuid,
  p_revision bigint,
  p_payload jsonb
) returns void language plpgsql security invoker set search_path = pg_catalog, nohut_private as $$
declare
  item jsonb;
  bday date;
  calc timestamptz;
  rep jsonb;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' or jsonb_typeof(p_payload->'reports') <> 'array' then
    raise exception 'invalid daily reports payload' using errcode = '22023';
  end if;
  if nohut_private.contains_forbidden_secret_key(p_payload) then
    raise exception 'credentials forbidden in daily report' using errcode = '42501';
  end if;

  for item in select value from jsonb_array_elements(p_payload->'reports') loop
    if jsonb_typeof(item) <> 'object' then
      raise exception 'invalid daily report item' using errcode = '22023';
    end if;
    rep := item->'report';
    if rep is null or jsonb_typeof(rep) <> 'object' then
      raise exception 'daily report object required' using errcode = '22023';
    end if;
    -- Owner decision (QA-05 superseded): Gün Sonu Raporu must NEVER include employee working hours.
    if rep ? 'staffHours' or rep ? 'workingHours' or item ? 'staffHours' then
      raise exception 'staffHours forbidden in daily report' using errcode = '22023';
    end if;
    bday := (item->>'day')::date;
    calc := coalesce(nullif(item->>'calculatedAt', '')::timestamptz, clock_timestamp());

    insert into nohut_private.daily_report_summaries(
      restaurant_id, business_day, is_preliminary, report_payload,
      calculated_at, source_revision, updated_at
    ) values (
      p_restaurant, bday, coalesce((item->>'preliminary')::boolean, true), rep,
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
end $$;
revoke all on function nohut_private.apply_daily_report_projection(uuid, bigint, jsonb)
  from public, anon, authenticated, service_role;

-- 4. Extend atomic sync ingest to accept notifications & dailyReports
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
      when 'shiftPlans' then perform nohut_private.apply_plan_projection(p_restaurant, rev, ev->'payload');
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

-- 5. Authenticated Notifications Read & Mark-Read RPCs
create function public.nohut_notifications_list(
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
  -- Verify session/device/permission_version via baseline operation allowed on caller's client
  if nohut_private.authorize(uid, sid, p_device_id, p_client, 'menu.view', p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into u from nohut_private.app_users where user_id = uid;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;

  with visible as (
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
     order by n.created_at desc
     limit lim
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'id', v.notification_id,
      'category', v.category,
      'severity', v.severity,
      'title', v.title,
      'body', v.body,
      'deepLink', v.deep_link,
      'createdAt', v.created_at,
      'read', v.is_read,
      'readAt', v.read_at
    ) order by v.created_at desc), '[]'::jsonb),
    count(*) filter (where not v.is_read)
  into items_json, unread_cnt
  from visible v;

  fresh := nohut_private.sync_freshness(u.restaurant_id, null, null);
  return jsonb_build_object(
    'items', items_json,
    'unreadCount', coalesce(unread_cnt, 0),
    'syncMeta', fresh
  );
end $$;

create function public.nohut_notification_mark_read(
  p_device_id uuid,
  p_client text,
  p_permission_version bigint,
  p_notification_ids text[]
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  sid uuid := public.nohut_jwt_claim('session_id')::uuid;
  u nohut_private.app_users;
  marked integer := 0;
begin
  if nohut_private.authorize(uid, sid, p_device_id, p_client, 'menu.view', p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into u from nohut_private.app_users where user_id = uid;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_notification_ids is null or cardinality(p_notification_ids) = 0 then
    return jsonb_build_object('marked', 0);
  end if;

  with ins as (
    insert into nohut_private.notification_reads(restaurant_id, user_id, notification_id, read_at)
    select n.restaurant_id, uid, n.notification_id, clock_timestamp()
      from nohut_private.cloud_notifications n
     where n.restaurant_id = u.restaurant_id
       and n.notification_id = any(p_notification_ids)
       and (n.recipient_employee_local_id is null or n.recipient_employee_local_id = u.pos_employee_id)
    on conflict (restaurant_id, user_id, notification_id) do nothing
    returning 1
  )
  select count(*) into marked from ins;

  return jsonb_build_object('marked', marked);
end $$;

-- 6. Authenticated Gün Sonu Raporu Read RPC (Yönetici only; amounts gated on sales.view / finance.view; zero staffHours)
create function public.nohut_daily_report_view(
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
  payload jsonb;
  fresh jsonb;
begin
  if nohut_private.authorize(uid, sid, p_device_id, p_client, 'dashboard.view', p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into u from nohut_private.app_users where user_id = uid;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;

  can_sales := nohut_private.authorize(uid, sid, p_device_id, p_client, 'sales.view', p_permission_version) = 'ok';
  can_finance := nohut_private.authorize(uid, sid, p_device_id, p_client, 'finance.view', p_permission_version) = 'ok';

  select * into r from nohut_private.daily_report_summaries
    where restaurant_id = u.restaurant_id and business_day = target_day;

  fresh := nohut_private.sync_freshness(u.restaurant_id, r.source_revision, r.calculated_at);
  if not found then
    return jsonb_build_object(
      'available', false,
      'day', to_char(target_day, 'YYYY-MM-DD'),
      'syncMeta', fresh
    );
  end if;

  payload := r.report_payload - 'staffHours' - 'workingHours';
  if not can_sales then
    payload := payload - 'sales' - 'collections' - 'platforms' - 'netProfitEstimate';
  end if;
  if not can_finance then
    payload := payload - 'expenses' - 'netProfitEstimate';
  end if;

  return jsonb_build_object(
    'available', true,
    'day', to_char(r.business_day, 'YYYY-MM-DD'),
    'preliminary', r.is_preliminary,
    'permissions', jsonb_build_object('sales', can_sales, 'finance', can_finance),
    'report', payload,
    'syncMeta', fresh
  );
end $$;

revoke all on function
  public.nohut_notifications_list(uuid, text, bigint, integer),
  public.nohut_notification_mark_read(uuid, text, bigint, text[]),
  public.nohut_daily_report_view(uuid, text, bigint, date)
  from public, anon, authenticated, service_role;

grant execute on function
  public.nohut_notifications_list(uuid, text, bigint, integer),
  public.nohut_notification_mark_read(uuid, text, bigint, text[]),
  public.nohut_daily_report_view(uuid, text, bigint, date)
  to authenticated;

commit;
