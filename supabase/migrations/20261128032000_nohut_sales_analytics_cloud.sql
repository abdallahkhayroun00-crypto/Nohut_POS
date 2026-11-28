-- Increment F (Phase 6 — Cloud Sales Analytics Read Projection: SalesView):
-- 1. Private table nohut_private.sales_analytics_snapshots (FORCE RLS, owner-only policy,
--    zero direct client grants) storing Windows-computed authoritative sales projections
--    (daily, topProducts, 7x24 heatmap, platforms, totals) per range ('week','last4','month','today').
-- 2. Windows agent push RPC: public.nohut_agent_report_sales_analytics(p_token, p_payload)
--    with strict schema/heatmap/secret-key validation and monotonic source_revision guard.
-- 3. Authenticated client read RPC: public.nohut_sales_analytics_view(p_device_id, p_client, p_permission_version, p_range)
--    enforcing nohut_private.authorize(..., 'sales.view', ...), tenant isolation, and clean null on empty.
begin;

create table nohut_private.sales_analytics_snapshots (
  restaurant_id uuid not null references nohut_private.restaurants,
  range_key text not null check (range_key in ('week', 'last4', 'month', 'today')),
  business_day date not null,
  from_day date not null,
  to_day date not null,
  daily jsonb not null check (jsonb_typeof(daily) = 'array'),
  top_products jsonb not null check (jsonb_typeof(top_products) = 'array'),
  heatmap jsonb not null check (jsonb_typeof(heatmap) = 'array' and jsonb_array_length(heatmap) = 7),
  platforms jsonb not null check (jsonb_typeof(platforms) = 'array'),
  totals jsonb not null check (jsonb_typeof(totals) = 'object'),
  note text not null default '' check (length(note) <= 400),
  calculated_at timestamptz not null,
  source_revision bigint not null check (source_revision > 0),
  updated_at timestamptz not null default now(),
  primary key (restaurant_id, range_key),
  check (from_day <= to_day)
);

alter table nohut_private.sales_analytics_snapshots enable row level security;
alter table nohut_private.sales_analytics_snapshots force row level security;
do $$
begin
  execute format(
    'create policy sales_analytics_snapshots_owner on nohut_private.sales_analytics_snapshots for all to %I using(true) with check(true)',
    current_user
  );
end $$;
revoke all on table nohut_private.sales_analytics_snapshots from public, anon, authenticated, service_role;

-- Helper: validate 7x24 non-negative integer heatmap matrix
create function nohut_private.is_valid_sales_heatmap(p_heatmap jsonb)
returns boolean language plpgsql immutable set search_path = '' as $$
declare
  row_val jsonb;
  cell_val jsonb;
  num_val numeric;
begin
  if p_heatmap is null or jsonb_typeof(p_heatmap) <> 'array' or jsonb_array_length(p_heatmap) <> 7 then
    return false;
  end if;
  for row_val in select value from jsonb_array_elements(p_heatmap) loop
    if jsonb_typeof(row_val) <> 'array' or jsonb_array_length(row_val) <> 24 then
      return false;
    end if;
    for cell_val in select value from jsonb_array_elements(row_val) loop
      if jsonb_typeof(cell_val) <> 'number' then
        return false;
      end if;
      num_val := cell_val::text::numeric;
      if num_val < 0 or num_val <> trunc(num_val) then
        return false;
      end if;
    end loop;
  end loop;
  return true;
end $$;

-- 1. Windows Agent Push RPC
create or replace function public.nohut_agent_report_sales_analytics(
  p_token text,
  p_payload jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  ag nohut_private.windows_agents;
  v_range text;
  v_business_day date;
  v_from_day date;
  v_to_day date;
  v_daily jsonb;
  v_top jsonb;
  v_heatmap jsonb;
  v_platforms jsonb;
  v_totals jsonb;
  v_note text;
  v_calculated_at timestamptz;
  v_revision bigint;
  v_existing_rev bigint;
  v_now timestamptz := clock_timestamp();
begin
  ag := nohut_private.authenticate_windows_agent(p_token);

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'invalid_sales_analytics_payload' using errcode = '22023';
  end if;
  if nohut_private.contains_forbidden_secret_key(p_payload) then
    raise exception 'credentials_forbidden_in_sales_analytics' using errcode = '42501';
  end if;

  v_range := nullif(btrim(coalesce(p_payload->>'range', '')), '');
  if v_range is null or v_range not in ('week', 'last4', 'month', 'today') then
    raise exception 'invalid_sales_range' using errcode = '22023';
  end if;

  begin
    v_business_day := (p_payload->>'businessDay')::date;
    v_from_day := (p_payload->>'from')::date;
    v_to_day := (p_payload->>'to')::date;
    v_calculated_at := coalesce((p_payload->>'calculatedAt')::timestamptz, v_now);
    v_revision := (p_payload->>'sourceRevision')::bigint;
  exception when others then
    raise exception 'invalid_sales_dates_or_revision' using errcode = '22023';
  end;

  if v_business_day is null or v_from_day is null or v_to_day is null
     or v_from_day > v_to_day or v_revision is null or v_revision <= 0 then
    raise exception 'invalid_sales_dates_or_revision' using errcode = '22023';
  end if;

  v_daily := p_payload->'daily';
  v_top := p_payload->'topProducts';
  v_heatmap := p_payload->'heatmap';
  v_platforms := p_payload->'platforms';
  v_totals := p_payload->'totals';
  v_note := coalesce(p_payload->>'note', '');

  if v_daily is null or jsonb_typeof(v_daily) <> 'array'
     or v_top is null or jsonb_typeof(v_top) <> 'array'
     or v_platforms is null or jsonb_typeof(v_platforms) <> 'array'
     or v_totals is null or jsonb_typeof(v_totals) <> 'object'
     or not nohut_private.is_valid_sales_heatmap(v_heatmap)
     or length(v_note) > 400 then
    raise exception 'invalid_sales_analytics_shape' using errcode = '22023';
  end if;

  select source_revision into v_existing_rev
    from nohut_private.sales_analytics_snapshots
   where restaurant_id = ag.restaurant_id and range_key = v_range;

  if v_existing_rev is not null and v_revision < v_existing_rev then
    return jsonb_build_object(
      'status', 'stale_ignored',
      'range', v_range,
      'currentRevision', v_existing_rev
    );
  end if;

  insert into nohut_private.sales_analytics_snapshots(
    restaurant_id, range_key, business_day, from_day, to_day,
    daily, top_products, heatmap, platforms, totals, note,
    calculated_at, source_revision, updated_at
  ) values (
    ag.restaurant_id, v_range, v_business_day, v_from_day, v_to_day,
    v_daily, v_top, v_heatmap, v_platforms, v_totals, v_note,
    v_calculated_at, v_revision, v_now
  )
  on conflict (restaurant_id, range_key) do update set
    business_day = excluded.business_day,
    from_day = excluded.from_day,
    to_day = excluded.to_day,
    daily = excluded.daily,
    top_products = excluded.top_products,
    heatmap = excluded.heatmap,
    platforms = excluded.platforms,
    totals = excluded.totals,
    note = excluded.note,
    calculated_at = excluded.calculated_at,
    source_revision = excluded.source_revision,
    updated_at = v_now;

  return jsonb_build_object(
    'status', 'ok',
    'range', v_range,
    'sourceRevision', v_revision
  );
end $$;
revoke all on function public.nohut_agent_report_sales_analytics(text, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.nohut_agent_report_sales_analytics(text, jsonb) to anon, authenticated;

-- 2. Authenticated Client Read RPC (gated behind sales.view)
create or replace function public.nohut_sales_analytics_view(
  p_device_id uuid,
  p_client text,
  p_permission_version bigint,
  p_range text default 'week'
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  sid uuid := public.nohut_jwt_claim('session_id')::uuid;
  auth_code text;
  u nohut_private.app_users;
  v_range text := coalesce(nullif(btrim(p_range), ''), 'week');
  snap nohut_private.sales_analytics_snapshots;
begin
  if v_range not in ('week', 'last4', 'month', 'today') then
    raise exception 'invalid_sales_range' using errcode = '22023';
  end if;

  auth_code := nohut_private.authorize(uid, sid, p_device_id, p_client, 'sales.view', p_permission_version);
  if auth_code <> 'ok' then
    return jsonb_build_object('status', 'forbidden', 'code', auth_code);
  end if;

  select * into u from nohut_private.app_users where user_id = uid;

  select * into snap
    from nohut_private.sales_analytics_snapshots
   where restaurant_id = u.restaurant_id and range_key = v_range;

  if snap.restaurant_id is null then
    return jsonb_build_object(
      'status', 'ok',
      'sales', null,
      'syncMeta', jsonb_build_object('range', v_range, 'hasData', false)
    );
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'sales', jsonb_build_object(
      'range', snap.range_key,
      'businessDay', to_char(snap.business_day, 'YYYY-MM-DD'),
      'from', to_char(snap.from_day, 'YYYY-MM-DD'),
      'to', to_char(snap.to_day, 'YYYY-MM-DD'),
      'daily', snap.daily,
      'topProducts', snap.top_products,
      'heatmap', snap.heatmap,
      'platforms', snap.platforms,
      'totals', snap.totals,
      'note', snap.note,
      'calculatedAt', to_char(snap.calculated_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
    ),
    'syncMeta', jsonb_build_object(
      'range', snap.range_key,
      'hasData', true,
      'sourceRevision', snap.source_revision,
      'updatedAt', to_char(snap.updated_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
    )
  );
end $$;
revoke all on function public.nohut_sales_analytics_view(uuid, text, bigint, text) from public, anon, service_role;
grant execute on function public.nohut_sales_analytics_view(uuid, text, bigint, text) to authenticated;

commit;
