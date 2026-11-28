-- Follow-up to Increment E (addresses Claude #7236979059 & #52 B1/B3):
-- 1. Auto-clear stale unclaimed/expired 'pending' platform locks (never clears 'unknown'!).
-- 2. Single atomic security-definer RPC public.nohut_agent_validate_and_read_claim
--    that validates an agent's active lease AND returns the tenant/epoch-scoped
--    command envelope in one call so check and read can never diverge.
begin;

create or replace function nohut_private.reap_expired_pending_platform_lock(
  p_restaurant_id uuid,
  p_provider text
) returns void language plpgsql set search_path = '' as $$
declare
  st nohut_private.platform_provider_state;
  cmd nohut_private.commands;
  v_now timestamptz := clock_timestamp();
begin
  select * into st
    from nohut_private.platform_provider_state
   where restaurant_id = p_restaurant_id
     and provider = p_provider
   for update;
  if not found or st.pending_request_id is null or st.pending_outcome <> 'pending' then
    return;
  end if;

  select * into cmd
    from nohut_private.commands
   where restaurant_id = p_restaurant_id
     and request_id = st.pending_request_id::text;

  -- Only clear when the command was NEVER claimed (state='queued' / lease_generation=0)
  -- and its TTL has expired (or command row no longer exists).
  -- Never clear an in-flight leased command or an 'unknown' outcome!
  if not found or (cmd.expires_at <= v_now and coalesce(cmd.lease_generation, 0) = 0 and cmd.state in ('pending', 'queued', 'expired')) then
    update nohut_private.platform_provider_state
       set pending_request_id = null,
           pending_target_status = null,
           pending_outcome = null,
           updated_at = v_now
     where restaurant_id = p_restaurant_id
       and provider = p_provider;

    insert into nohut_private.platform_status_audit(
      restaurant_id, provider, request_id, actor_name,
      action, old_status, new_status, outcome, detail, created_at
    ) values (
      p_restaurant_id, p_provider, st.pending_request_id, 'system',
      'store_status_expired', st.working_status, st.pending_target_status, 'failed',
      'command_expired_unclaimed', v_now
    );
  end if;
end $$;
revoke all on function nohut_private.reap_expired_pending_platform_lock(uuid, text)
  from public, anon, authenticated, service_role;

-- Update nohut_platform_cards_view to reap expired unclaimed pending locks before rendering
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
    perform nohut_private.reap_expired_pending_platform_lock(u.restaurant_id, prov);

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

-- Update nohut_platform_enqueue_status_set to reap expired unclaimed pending lock before guard
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

  if nohut_private.authorize(uid, sid, p_device_id, p_client, 'platform.store.toggle', p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  a := nohut_private.command_actor(uid);
  if a is null or (a->>'permission_version')::bigint is distinct from p_permission_version then
    raise exception 'actor not linked' using errcode = '42501';
  end if;

  -- Clear any expired unclaimed pending lock before checking state
  perform nohut_private.reap_expired_pending_platform_lock(u.restaurant_id, p_provider);

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

-- Atomic lease validation + tenant/epoch-scoped envelope read (closes #52 B1 & B3)
create or replace function public.nohut_agent_validate_and_read_claim(
  p_token text,
  p_request uuid,
  p_generation integer,
  p_envelope_sha256 text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  ag nohut_private.windows_agents;
  c nohut_private.commands;
begin
  ag := nohut_private.authenticate_windows_agent(p_token);
  if p_request is null or p_generation is null or p_generation <= 0 then
    return jsonb_build_object('valid', false);
  end if;
  select * into c
    from nohut_private.commands q
   where q.restaurant_id = ag.restaurant_id
     and q.authority_epoch = ag.authority_epoch
     and q.request_id = p_request::text;
  if not found
    or c.state <> 'processing'
    or c.lease_generation <> p_generation
    or c.lease_until <= clock_timestamp()
    or c.expires_at <= clock_timestamp()
    or nohut_private.command_envelope_sha256(c.envelope) is distinct from p_envelope_sha256
    or nohut_private.command_still_authorized(ag.restaurant_id, c.envelope) is not true then
    return jsonb_build_object('valid', false);
  end if;
  return jsonb_build_object(
    'valid', true,
    'restaurant_id', ag.restaurant_id::text,
    'authority_epoch', ag.authority_epoch::text,
    'action_type', c.envelope->>'action_type',
    'payload', c.envelope->'payload'
  );
end $$;
revoke all on function public.nohut_agent_validate_and_read_claim(text, uuid, integer, text)
  from public, authenticated, service_role;
grant execute on function public.nohut_agent_validate_and_read_claim(text, uuid, integer, text)
  to anon;

commit;
