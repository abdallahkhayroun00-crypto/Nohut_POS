-- Increment E (Platform Yönetimi — Standalone Online Platform Control Plane):
-- Owner decisions #7236242716, #7236317297, #7236345814; aligned with Claude's
-- PlatformCard (`packages/nohut_core/lib/platform_status.dart`) and PlatformControl
-- (`flutter_desktop/lib/platform_management.dart`) on PR #51 (5d86127, 31b304d).
--
-- Guarantees:
--   1. One authoritative provider read model (`nohut_platform_cards_view`) serving
--      always all three providers in fixed order (trendyol_go, yemeksepeti, migros_yemek).
--   2. Separate permission grants (idempotent with PR #51 20261128020000):
--      platform.view, platform.store.toggle, platform.schedule.edit, platform.catalog.toggle.
--   3. Durable idempotent commands in nohut_private.commands (5m TTL):
--      platform_store_status_set, platform_store_status_refresh, platform_store_status_reconcile.
--   4. Fail-closed pre-enqueue guards: confirmed=true, connected + can_toggle_store,
--      verified_store_id present, readback <= 10 min fresh, no pending/unknown mutation
--      in flight, and expectedStatus == current working_status.
--   5. Append-only audit history (UPDATE/DELETE blocked); unknown outcomes stay locked
--      until explicit readback reconciliation (never blind retry or silent overwrite).
begin;

-- 1. Idempotent permission catalogue rows (matches PR #51 20261128020000)
insert into nohut_private.operation_catalogue(operation_id, section, sensitivity, clients, default_roles) values
  ('platform.view', 'platform', 'normal', array['windows','personel','yonetici']::text[], array['Müdür','Yönetici']::text[]),
  ('platform.store.toggle', 'platform', 'elevated', array['windows','personel','yonetici']::text[], array['Yönetici']::text[]),
  ('platform.schedule.edit', 'platform', 'elevated', array['windows','personel','yonetici']::text[], array['Yönetici']::text[]),
  ('platform.catalog.toggle', 'platform', 'elevated', array['windows','personel','yonetici']::text[], array['Yönetici']::text[])
on conflict (operation_id) do nothing;

-- 2. Private provider readback state table
create table if not exists nohut_private.platform_provider_state (
  restaurant_id uuid not null references nohut_private.restaurants(restaurant_id) on delete cascade,
  provider text not null check (provider in ('trendyol_go', 'yemeksepeti', 'migros_yemek')),
  connection_state text not null default 'not_connected'
    check (connection_state in ('connected', 'not_connected', 'disabled')),
  working_status text not null default 'UNKNOWN'
    check (working_status in ('OPEN', 'CLOSED', 'UNKNOWN')),
  verified_store_id text,
  verified_store_name text,
  last_verified_at timestamptz,
  schedule_state text not null default 'unknown'
    check (schedule_state in ('within_hours', 'outside_hours', 'unknown')),
  working_hours jsonb not null default '[]'::jsonb
    check (jsonb_typeof(working_hours) = 'array'),
  pending_request_id uuid,
  pending_target_status text check (pending_target_status is null or pending_target_status in ('OPEN', 'CLOSED')),
  pending_outcome text check (pending_outcome is null or pending_outcome in ('pending', 'unknown')),
  can_toggle_store boolean not null default false,
  can_edit_hours boolean not null default false,
  can_toggle_catalog boolean not null default false,
  note text,
  source_revision bigint,
  updated_at timestamptz not null default now(),
  primary key (restaurant_id, provider)
);

alter table nohut_private.platform_provider_state enable row level security;
alter table nohut_private.platform_provider_state force row level security;
revoke all on table nohut_private.platform_provider_state from public, anon, authenticated, service_role;
drop policy if exists platform_provider_state_owner on nohut_private.platform_provider_state;
create policy platform_provider_state_owner on nohut_private.platform_provider_state
  for all to current_user using (true) with check (true);

-- 3. Private append-only platform status audit table
create table if not exists nohut_private.platform_status_audit (
  audit_id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references nohut_private.restaurants(restaurant_id) on delete cascade,
  provider text not null check (provider in ('trendyol_go', 'yemeksepeti', 'migros_yemek')),
  request_id uuid,
  actor_user_id uuid,
  actor_name text not null default '',
  action text not null,
  old_status text check (old_status is null or old_status in ('OPEN', 'CLOSED', 'UNKNOWN')),
  new_status text check (new_status is null or new_status in ('OPEN', 'CLOSED', 'UNKNOWN')),
  outcome text not null check (outcome in ('confirmed', 'unknown', 'failed', 'rejected', 'pending')),
  detail text,
  created_at timestamptz not null default clock_timestamp()
);

create index if not exists platform_status_audit_lookup_idx
  on nohut_private.platform_status_audit(restaurant_id, provider, created_at desc);

alter table nohut_private.platform_status_audit enable row level security;
alter table nohut_private.platform_status_audit force row level security;
revoke all on table nohut_private.platform_status_audit from public, anon, authenticated, service_role;
drop policy if exists platform_status_audit_owner on nohut_private.platform_status_audit;
create policy platform_status_audit_owner on nohut_private.platform_status_audit
  for all to current_user using (true) with check (true);

create or replace function nohut_private.deny_platform_audit_mutation()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'platform_status_audit is append-only' using errcode = '42501';
end $$;
revoke all on function nohut_private.deny_platform_audit_mutation() from public, anon, authenticated, service_role;

drop trigger if exists platform_status_audit_no_update on nohut_private.platform_status_audit;
create trigger platform_status_audit_no_update
  before update or delete on nohut_private.platform_status_audit
  for each row execute function nohut_private.deny_platform_audit_mutation();

-- 4. Authorized Read RPC: public.nohut_platform_cards_view
-- Returns all three providers in fixed order matching PlatformCard.fromJson.
create or replace function public.nohut_platform_cards_view(
  p_device_id uuid,
  p_client text,
  p_permission_version bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  sid uuid := public.nohut_jwt_claim('session_id')::uuid;
  u nohut_private.app_users;
  prov text;
  st nohut_private.platform_provider_state;
  audit_json jsonb;
  cards jsonb := '[]'::jsonb;
  card jsonb;
  fresh jsonb;
begin
  if nohut_private.authorize(uid, sid, p_device_id, p_client, 'platform.view', p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into u from nohut_private.app_users where user_id = uid;
  if not found then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  foreach prov in array array['trendyol_go', 'yemeksepeti', 'migros_yemek']::text[] loop
    select * into st
      from nohut_private.platform_provider_state s
     where s.restaurant_id = u.restaurant_id
       and s.provider = prov;

    select coalesce(jsonb_agg(jsonb_build_object(
      'at', to_char(a.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'actor', a.actor_name,
      'action', a.action,
      'oldStatus', a.old_status,
      'newStatus', a.new_status,
      'outcome', a.outcome
    ) order by a.created_at desc), '[]'::jsonb)
      into audit_json
      from (
        select created_at, actor_name, action, old_status, new_status, outcome
          from nohut_private.platform_status_audit
         where restaurant_id = u.restaurant_id and provider = prov
         order by created_at desc
         limit 25
      ) a;

    if st.restaurant_id is null then
      card := jsonb_build_object(
        'provider', prov,
        'connectionState', 'not_connected',
        'workingStatus', 'UNKNOWN',
        'verifiedStoreId', null,
        'verifiedStoreName', null,
        'lastVerifiedAt', null,
        'scheduleState', 'unknown',
        'workingHours', '[]'::jsonb,
        'pendingMutation', null,
        'auditHistory', audit_json,
        'capabilities', jsonb_build_object(
          'toggleStore', false,
          'editHours', false,
          'toggleCatalog', false
        ),
        'note', case prov
          when 'yemeksepeti' then 'Yemeksepeti için doğrulanmış resmî entegrasyon yok.'
          when 'migros_yemek' then 'Migros Yemek için yetkili entegrasyon yok.'
          else 'Platform bağlantısı henüz doğrulanmadı.'
        end
      );
    else
      card := jsonb_build_object(
        'provider', prov,
        'connectionState', st.connection_state,
        'workingStatus', st.working_status,
        'verifiedStoreId', st.verified_store_id,
        'verifiedStoreName', st.verified_store_name,
        'lastVerifiedAt', case when st.last_verified_at is not null
          then to_char(st.last_verified_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
          else null end,
        'scheduleState', st.schedule_state,
        'workingHours', st.working_hours,
        'pendingMutation', case when st.pending_request_id is not null then jsonb_build_object(
          'requestId', st.pending_request_id::text,
          'targetStatus', st.pending_target_status,
          'outcome', st.pending_outcome
        ) else null end,
        'auditHistory', audit_json,
        'capabilities', jsonb_build_object(
          'toggleStore', st.can_toggle_store,
          'editHours', st.can_edit_hours,
          'toggleCatalog', st.can_toggle_catalog
        ),
        'note', st.note
      );
    end if;

    cards := cards || jsonb_build_array(card);
  end loop;

  select jsonb_build_object(
    'lastVerifiedAt', (
      select to_char(max(last_verified_at) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
        from nohut_private.platform_provider_state
       where restaurant_id = u.restaurant_id
    ),
    'freshWindowSeconds', 600
  ) into fresh;
  return jsonb_build_object(
    'cards', cards,
    'syncMeta', fresh
  );
end $$;
revoke all on function public.nohut_platform_cards_view(uuid, text, bigint) from public, anon, service_role;
grant execute on function public.nohut_platform_cards_view(uuid, text, bigint) to authenticated;

-- 5. Authorized Durable Idempotent Enqueue: platform_store_status_set
create or replace function public.nohut_platform_enqueue_status_set(
  p_device_id uuid,
  p_client text,
  p_permission_version bigint,
  p_request_id uuid,
  p_provider text,
  p_target_status text,
  p_expected_status text,
  p_confirmed boolean default false,
  p_reason text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  sid uuid := public.nohut_jwt_claim('session_id')::uuid;
  u nohut_private.app_users;
  v_epoch uuid;
  a jsonb;
  st nohut_private.platform_provider_state;
  body jsonb;
  h text;
  prior nohut_private.commands;
  issued timestamptz;
  ttl interval := interval '5 minutes';
begin
  if p_request_id is null
    or p_provider not in ('trendyol_go', 'yemeksepeti', 'migros_yemek')
    or p_target_status not in ('OPEN', 'CLOSED')
    or p_expected_status not in ('OPEN', 'CLOSED')
    or p_target_status = p_expected_status then
    raise exception 'invalid_platform_status_request' using errcode = '22023';
  end if;
  if p_confirmed is distinct from true then
    raise exception 'confirmation_required' using errcode = '22023';
  end if;
  if p_reason is not null and length(p_reason) > 200 then
    raise exception 'reason_too_long' using errcode = '22023';
  end if;

  if nohut_private.authorize(uid, sid, p_device_id, p_client, 'platform.store.toggle', p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into u from nohut_private.app_users where user_id = uid;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;

  select e.authority_epoch into v_epoch
    from nohut_private.authority_epochs e
   where e.restaurant_id = u.restaurant_id and e.retired_at is null
   for update;
  if not found then raise exception 'no active authority' using errcode = '42501'; end if;
  if not exists (
    select 1 from nohut_private.sync_migrations m
     where m.restaurant_id = u.restaurant_id
       and m.authority_epoch = v_epoch
       and m.status = 'active'
  ) then
    raise exception 'sync not activated' using errcode = '42501';
  end if;

  -- Revalidate after authority lock
  if nohut_private.authorize(uid, sid, p_device_id, p_client, 'platform.store.toggle', p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  a := nohut_private.command_actor(uid);
  if a is null or (a->>'permission_version')::bigint is distinct from p_permission_version then
    raise exception 'actor not linked' using errcode = '42501';
  end if;

  -- Lock provider state row
  select * into st
    from nohut_private.platform_provider_state s
   where s.restaurant_id = u.restaurant_id and s.provider = p_provider
   for update;

  body := jsonb_strip_nulls(jsonb_build_object(
    'provider', p_provider,
    'storeId', st.verified_store_id,
    'targetStatus', p_target_status,
    'expectedStatus', p_expected_status,
    'confirmed', true,
    'reason', nullif(btrim(coalesce(p_reason, '')), '')
  ));
  h := encode(sha256(convert_to(nohut_private.canonical_command_json(body), 'UTF8')), 'hex');

  -- Idempotency check BEFORE stateful guards so retries of an already-accepted request return duplicate
  select * into prior
    from nohut_private.commands q
   where q.restaurant_id = u.restaurant_id and q.request_id = p_request_id::text;
  if found then
    if prior.authority_epoch = v_epoch
      and prior.envelope->>'actor_user_id' = uid::text
      and prior.envelope->>'device_session_id' = sid::text
      and prior.envelope->>'device_id' = p_device_id::text
      and prior.envelope->>'client' = p_client
      and prior.envelope->>'action_type' = 'platform_store_status_set'
      and prior.envelope->>'payload_sha256' = h
      and prior.envelope->'payload' = body then
      return jsonb_build_object('status', 'duplicate', 'request_id', p_request_id);
    end if;
    return jsonb_build_object('status', 'conflict', 'request_id', p_request_id);
  end if;

  -- Fail-closed provider readiness & freshness guards
  if st.restaurant_id is null or st.connection_state <> 'connected' or not st.can_toggle_store then
    raise exception 'provider_unavailable' using errcode = '22023';
  end if;
  if st.verified_store_id is null or btrim(st.verified_store_id) = '' then
    raise exception 'unverified_store' using errcode = '22023';
  end if;
  if st.pending_request_id is not null then
    raise exception 'pending_mutation_in_flight' using errcode = '22023';
  end if;
  if st.last_verified_at is null or st.last_verified_at < clock_timestamp() - interval '10 minutes' then
    raise exception 'stale_status' using errcode = '22023';
  end if;
  if st.working_status is distinct from p_expected_status then
    raise exception 'status_mismatch' using errcode = '22023';
  end if;

  issued := clock_timestamp();
  insert into nohut_private.commands(restaurant_id, request_id, authority_epoch, envelope, issued_at, expires_at)
    values (
      u.restaurant_id, p_request_id::text, v_epoch,
      jsonb_build_object(
        'restaurant_id', u.restaurant_id,
        'request_id', p_request_id,
        'authority_epoch', v_epoch,
        'schema_version', 1,
        'actor_user_id', uid,
        'device_session_id', sid,
        'device_id', p_device_id,
        'actor', a,
        'client', p_client,
        'action_type', 'platform_store_status_set',
        'operation', 'platform.store.toggle',
        'payload', body,
        'payload_sha256', h,
        'issued_at', issued,
        'expires_at', issued + ttl
      ),
      issued, issued + ttl
    );

  update nohut_private.platform_provider_state
     set pending_request_id = p_request_id,
         pending_target_status = p_target_status,
         pending_outcome = 'pending',
         updated_at = issued
   where restaurant_id = u.restaurant_id and provider = p_provider;

  insert into nohut_private.platform_status_audit(
    restaurant_id, provider, request_id, actor_user_id, actor_name,
    action, old_status, new_status, outcome, detail, created_at
  ) values (
    u.restaurant_id, p_provider, p_request_id, uid, coalesce(u.username, ''),
    'store_status_set', st.working_status, p_target_status, 'pending',
    nullif(btrim(coalesce(p_reason, '')), ''), issued
  );

  return jsonb_build_object(
    'status', 'accepted',
    'request_id', p_request_id,
    'provider', p_provider,
    'target_status', p_target_status
  );
end $$;
revoke all on function public.nohut_platform_enqueue_status_set(uuid, text, bigint, uuid, text, text, text, boolean, text)
  from public, anon, service_role;
grant execute on function public.nohut_platform_enqueue_status_set(uuid, text, bigint, uuid, text, text, text, boolean, text)
  to authenticated;

-- 6. Authorized Read-Only Refresh & Unknown-Outcome Reconcile Commands
create or replace function public.nohut_platform_enqueue_refresh(
  p_device_id uuid,
  p_client text,
  p_permission_version bigint,
  p_request_id uuid,
  p_provider text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  sid uuid := public.nohut_jwt_claim('session_id')::uuid;
  u nohut_private.app_users;
  v_epoch uuid;
  a jsonb;
  body jsonb;
  h text;
  prior nohut_private.commands;
  issued timestamptz;
begin
  if p_request_id is null or p_provider not in ('trendyol_go', 'yemeksepeti', 'migros_yemek') then
    raise exception 'invalid_platform_refresh_request' using errcode = '22023';
  end if;
  if nohut_private.authorize(uid, sid, p_device_id, p_client, 'platform.view', p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into u from nohut_private.app_users where user_id = uid;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;

  select e.authority_epoch into v_epoch
    from nohut_private.authority_epochs e
   where e.restaurant_id = u.restaurant_id and e.retired_at is null
   for update;
  if not found then raise exception 'no active authority' using errcode = '42501'; end if;
  if not exists (
    select 1 from nohut_private.sync_migrations m
     where m.restaurant_id = u.restaurant_id and m.authority_epoch = v_epoch and m.status = 'active'
  ) then
    raise exception 'sync not activated' using errcode = '42501';
  end if;

  a := nohut_private.command_actor(uid);
  body := jsonb_build_object('provider', p_provider);
  h := encode(sha256(convert_to(nohut_private.canonical_command_json(body), 'UTF8')), 'hex');

  select * into prior from nohut_private.commands q
   where q.restaurant_id = u.restaurant_id and q.request_id = p_request_id::text;
  if found then
    if prior.authority_epoch = v_epoch and prior.envelope->>'actor_user_id' = uid::text
      and prior.envelope->>'action_type' = 'platform_store_status_refresh'
      and prior.envelope->>'payload_sha256' = h then
      return jsonb_build_object('status', 'duplicate', 'request_id', p_request_id);
    end if;
    return jsonb_build_object('status', 'conflict', 'request_id', p_request_id);
  end if;

  issued := clock_timestamp();
  insert into nohut_private.commands(restaurant_id, request_id, authority_epoch, envelope, issued_at, expires_at)
    values (
      u.restaurant_id, p_request_id::text, v_epoch,
      jsonb_build_object(
        'restaurant_id', u.restaurant_id, 'request_id', p_request_id, 'authority_epoch', v_epoch,
        'schema_version', 1, 'actor_user_id', uid, 'device_session_id', sid, 'device_id', p_device_id,
        'actor', a, 'client', p_client, 'action_type', 'platform_store_status_refresh',
        'operation', 'platform.view', 'payload', body, 'payload_sha256', h,
        'issued_at', issued, 'expires_at', issued + interval '5 minutes'
      ),
      issued, issued + interval '5 minutes'
    );
  return jsonb_build_object('status', 'accepted', 'request_id', p_request_id, 'provider', p_provider);
end $$;
revoke all on function public.nohut_platform_enqueue_refresh(uuid, text, bigint, uuid, text)
  from public, anon, service_role;
grant execute on function public.nohut_platform_enqueue_refresh(uuid, text, bigint, uuid, text)
  to authenticated;

create or replace function public.nohut_platform_enqueue_reconcile(
  p_device_id uuid,
  p_client text,
  p_permission_version bigint,
  p_request_id uuid,
  p_provider text,
  p_target_request_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  sid uuid := public.nohut_jwt_claim('session_id')::uuid;
  u nohut_private.app_users;
  v_epoch uuid;
  st nohut_private.platform_provider_state;
  a jsonb;
  body jsonb;
  h text;
  prior nohut_private.commands;
  issued timestamptz;
begin
  if p_request_id is null or p_target_request_id is null
    or p_provider not in ('trendyol_go', 'yemeksepeti', 'migros_yemek') then
    raise exception 'invalid_platform_reconcile_request' using errcode = '22023';
  end if;
  if nohut_private.authorize(uid, sid, p_device_id, p_client, 'platform.view', p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into u from nohut_private.app_users where user_id = uid;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;

  select e.authority_epoch into v_epoch
    from nohut_private.authority_epochs e
   where e.restaurant_id = u.restaurant_id and e.retired_at is null
   for update;
  if not found then raise exception 'no active authority' using errcode = '42501'; end if;
  if not exists (
    select 1 from nohut_private.sync_migrations m
     where m.restaurant_id = u.restaurant_id and m.authority_epoch = v_epoch and m.status = 'active'
  ) then
    raise exception 'sync not activated' using errcode = '42501';
  end if;

  select * into st from nohut_private.platform_provider_state
   where restaurant_id = u.restaurant_id and provider = p_provider
   for update;

  body := jsonb_build_object('provider', p_provider, 'targetRequestId', p_target_request_id::text);
  h := encode(sha256(convert_to(nohut_private.canonical_command_json(body), 'UTF8')), 'hex');

  select * into prior from nohut_private.commands q
   where q.restaurant_id = u.restaurant_id and q.request_id = p_request_id::text;
  if found then
    if prior.authority_epoch = v_epoch and prior.envelope->>'actor_user_id' = uid::text
      and prior.envelope->>'action_type' = 'platform_store_status_reconcile'
      and prior.envelope->>'payload_sha256' = h then
      return jsonb_build_object('status', 'duplicate', 'request_id', p_request_id);
    end if;
    return jsonb_build_object('status', 'conflict', 'request_id', p_request_id);
  end if;

  if st.restaurant_id is null or st.pending_request_id is distinct from p_target_request_id
    or st.pending_outcome is distinct from 'unknown' then
    raise exception 'no_unknown_mutation_to_reconcile' using errcode = '22023';
  end if;

  a := nohut_private.command_actor(uid);
  issued := clock_timestamp();
  insert into nohut_private.commands(restaurant_id, request_id, authority_epoch, envelope, issued_at, expires_at)
    values (
      u.restaurant_id, p_request_id::text, v_epoch,
      jsonb_build_object(
        'restaurant_id', u.restaurant_id, 'request_id', p_request_id, 'authority_epoch', v_epoch,
        'schema_version', 1, 'actor_user_id', uid, 'device_session_id', sid, 'device_id', p_device_id,
        'actor', a, 'client', p_client, 'action_type', 'platform_store_status_reconcile',
        'operation', 'platform.view', 'payload', body, 'payload_sha256', h,
        'issued_at', issued, 'expires_at', issued + interval '5 minutes'
      ),
      issued, issued + interval '5 minutes'
    );
  return jsonb_build_object('status', 'accepted', 'request_id', p_request_id, 'target_request_id', p_target_request_id);
end $$;
revoke all on function public.nohut_platform_enqueue_reconcile(uuid, text, bigint, uuid, text, uuid)
  from public, anon, service_role;
grant execute on function public.nohut_platform_enqueue_reconcile(uuid, text, bigint, uuid, text, uuid)
  to authenticated;

-- 7. Windows-Agent Readback & Mutation Resolution RPCs (Windows agent token ONLY)
create or replace function public.nohut_agent_report_platform_state(
  p_token text,
  p_provider text,
  p_connection_state text,
  p_working_status text,
  p_verified_store_id text default null,
  p_verified_store_name text default null,
  p_last_verified_at timestamptz default null,
  p_schedule_state text default 'unknown',
  p_working_hours jsonb default '[]'::jsonb,
  p_can_toggle_store boolean default false,
  p_can_edit_hours boolean default false,
  p_can_toggle_catalog boolean default false,
  p_note text default null,
  p_source_revision bigint default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  ag nohut_private.windows_agents;
  v_now timestamptz := clock_timestamp();
begin
  ag := nohut_private.authenticate_windows_agent(p_token);
  if p_provider not in ('trendyol_go', 'yemeksepeti', 'migros_yemek')
    or p_connection_state not in ('connected', 'not_connected', 'disabled')
    or p_working_status not in ('OPEN', 'CLOSED', 'UNKNOWN')
    or p_schedule_state not in ('within_hours', 'outside_hours', 'unknown')
    or p_working_hours is null
    or jsonb_typeof(p_working_hours) <> 'array' then
    raise exception 'invalid_platform_state' using errcode = '22023';
  end if;

  insert into nohut_private.platform_provider_state(
    restaurant_id, provider, connection_state, working_status,
    verified_store_id, verified_store_name, last_verified_at,
    schedule_state, working_hours,
    can_toggle_store, can_edit_hours, can_toggle_catalog,
    note, source_revision, updated_at
  ) values (
    ag.restaurant_id, p_provider, p_connection_state, p_working_status,
    nullif(btrim(coalesce(p_verified_store_id, '')), ''),
    nullif(btrim(coalesce(p_verified_store_name, '')), ''),
    p_last_verified_at,
    p_schedule_state, p_working_hours,
    coalesce(p_can_toggle_store, false),
    coalesce(p_can_edit_hours, false),
    coalesce(p_can_toggle_catalog, false),
    p_note, p_source_revision, v_now
  )
  on conflict (restaurant_id, provider) do update set
    connection_state = excluded.connection_state,
    working_status = excluded.working_status,
    verified_store_id = excluded.verified_store_id,
    verified_store_name = excluded.verified_store_name,
    last_verified_at = excluded.last_verified_at,
    schedule_state = excluded.schedule_state,
    working_hours = excluded.working_hours,
    can_toggle_store = excluded.can_toggle_store,
    can_edit_hours = excluded.can_edit_hours,
    can_toggle_catalog = excluded.can_toggle_catalog,
    note = excluded.note,
    source_revision = coalesce(excluded.source_revision, nohut_private.platform_provider_state.source_revision),
    updated_at = v_now;
    -- NOTE: pending_request_id / pending_outcome are intentionally preserved here;
    -- only nohut_agent_resolve_platform_mutation may clear or resolve an in-flight/unknown mutation.

  return jsonb_build_object('status', 'accepted', 'provider', p_provider, 'working_status', p_working_status);
end $$;
revoke all on function public.nohut_agent_report_platform_state(text, text, text, text, text, text, timestamptz, text, jsonb, boolean, boolean, boolean, text, bigint)
  from public, authenticated, service_role;
grant execute on function public.nohut_agent_report_platform_state(text, text, text, text, text, text, timestamptz, text, jsonb, boolean, boolean, boolean, text, bigint)
  to anon;

create or replace function public.nohut_agent_resolve_platform_mutation(
  p_token text,
  p_provider text,
  p_request_id uuid,
  p_outcome text,
  p_verified_working_status text default null,
  p_verified_at timestamptz default null,
  p_actor_name text default null,
  p_detail text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  ag nohut_private.windows_agents;
  st nohut_private.platform_provider_state;
  v_now timestamptz := clock_timestamp();
  v_old text;
  v_new text;
begin
  ag := nohut_private.authenticate_windows_agent(p_token);
  if p_provider not in ('trendyol_go', 'yemeksepeti', 'migros_yemek')
    or p_request_id is null
    or p_outcome not in ('confirmed', 'unknown', 'failed', 'rejected')
    or (p_verified_working_status is not null and p_verified_working_status not in ('OPEN', 'CLOSED', 'UNKNOWN')) then
    raise exception 'invalid_platform_resolution' using errcode = '22023';
  end if;

  select * into st
    from nohut_private.platform_provider_state
   where restaurant_id = ag.restaurant_id and provider = p_provider
   for update;
  if not found then
    raise exception 'platform_state_not_found' using errcode = '22023';
  end if;

  v_old := st.working_status;
  v_new := coalesce(p_verified_working_status, st.pending_target_status, st.working_status);

  if p_outcome = 'unknown' then
    update nohut_private.platform_provider_state
       set pending_request_id = p_request_id,
           pending_outcome = 'unknown',
           updated_at = v_now
     where restaurant_id = ag.restaurant_id and provider = p_provider;
  else
    update nohut_private.platform_provider_state
       set working_status = coalesce(p_verified_working_status, working_status),
           last_verified_at = coalesce(p_verified_at, last_verified_at),
           pending_request_id = case when pending_request_id = p_request_id then null else pending_request_id end,
           pending_target_status = case when pending_request_id = p_request_id then null else pending_target_status end,
           pending_outcome = case when pending_request_id = p_request_id then null else pending_outcome end,
           updated_at = v_now
     where restaurant_id = ag.restaurant_id and provider = p_provider;
  end if;

  insert into nohut_private.platform_status_audit(
    restaurant_id, provider, request_id, actor_name,
    action, old_status, new_status, outcome, detail, created_at
  ) values (
    ag.restaurant_id, p_provider, p_request_id, coalesce(p_actor_name, 'windows-agent'),
    case when p_outcome = 'unknown' then 'store_status_unknown' else 'store_status_resolved' end,
    v_old, v_new, p_outcome, p_detail, v_now
  );

  return jsonb_build_object(
    'status', 'accepted',
    'provider', p_provider,
    'request_id', p_request_id,
    'outcome', p_outcome
  );
end $$;
revoke all on function public.nohut_agent_resolve_platform_mutation(text, text, uuid, text, text, timestamptz, text, text)
  from public, authenticated, service_role;
grant execute on function public.nohut_agent_resolve_platform_mutation(text, text, uuid, text, text, timestamptz, text, text)
  to anon;

commit;
