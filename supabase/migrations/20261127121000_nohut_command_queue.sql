-- PR-05B / Phase 5B: private command lease foundation.
-- No client execution grants; Phase 3 must supply authenticated, scoped
-- enqueue/claim/complete wrappers. Do not deploy to production yet.
begin;
create table nohut_private.commands (
  restaurant_id uuid not null,
  request_id text not null check (length(request_id) between 1 and 128),
  authority_epoch uuid not null,
  envelope jsonb not null check (jsonb_typeof(envelope) = 'object'),
  issued_at timestamptz not null,
  expires_at timestamptz not null,
  state text not null default 'pending' check (state in
    ('pending','processing','confirmed','conflict','rejected','expired','reconciliation_required')),
  lease_generation bigint not null default 0 check (lease_generation >= 0),
  lease_until timestamptz,
  result jsonb,
  primary key (restaurant_id, request_id),
  foreign key (restaurant_id,authority_epoch) references nohut_private.authority_epochs,
  check (expires_at > issued_at and expires_at <= issued_at + interval '15 minutes'),
  check ((envelope->>'request_id' = request_id) is true),
  check ((envelope->>'restaurant_id' = restaurant_id::text) is true),
  check ((envelope->>'authority_epoch' = authority_epoch::text) is true),
  check (((envelope->>'issued_at')::timestamptz = issued_at) is true),
  check (((envelope->>'expires_at')::timestamptz = expires_at) is true),
  check ((jsonb_typeof(envelope->'actor') = 'object') is true),
  check ((jsonb_typeof(envelope->'payload') = 'object') is true),
  check ((envelope->>'payload_sha256' ~ '^[0-9a-f]{64}$') is true),
  check ((state = 'processing') = (lease_until is not null)),
  check ((state not in ('pending','processing')) = (result is not null)),
  check (result is null or ((jsonb_typeof(result) = 'object' and result->>'state' = state) is true))
);
create index commands_claim_order on nohut_private.commands
  (restaurant_id,authority_epoch,issued_at,request_id)
  where state in ('pending','processing');
alter table nohut_private.commands enable row level security;
alter table nohut_private.commands force row level security;
revoke all on nohut_private.commands from public, anon, authenticated, service_role;

-- Internal only. Callers must authenticate the Windows authority BEFORE
-- invoking this primitive. An epoch identifier is NOT a credential.
-- Expired pending requests were never claimed; expired processing requests
-- may have committed locally, so require reconciliation, not blind replay.
create function nohut_private.claim_commands(
  p_restaurant uuid, p_epoch uuid, p_max integer
) returns table(envelope jsonb, lease_generation bigint)
language plpgsql security invoker set search_path = pg_catalog, nohut_private
as $$
declare v_now timestamptz := clock_timestamp();
begin
  if p_max is null or p_max not between 1 and 20 then
    raise exception 'invalid claim limit' using errcode = '22023';
  end if;
  perform 1 from nohut_private.authority_epochs a
    where a.restaurant_id=p_restaurant and a.authority_epoch=p_epoch and a.retired_at is null
    for share;
  if not found then raise exception 'inactive authority' using errcode='42501'; end if;
  update nohut_private.commands c set state='expired',
    result=jsonb_build_object('state','expired','code','expired')
    where c.restaurant_id=p_restaurant and c.authority_epoch=p_epoch
      and c.state='pending' and c.expires_at<=v_now;
  update nohut_private.commands c set state='reconciliation_required',lease_until=null,
    result=jsonb_build_object('state','reconciliation_required','code','claim_expired_outcome_unknown')
    where c.restaurant_id=p_restaurant and c.authority_epoch=p_epoch
      and c.state='processing' and c.expires_at<=v_now and c.lease_until<=v_now;
  return query
  with picked as (
    select c.restaurant_id,c.request_id from nohut_private.commands c
    where c.restaurant_id=p_restaurant and c.authority_epoch=p_epoch
      and c.expires_at>v_now and (c.state='pending' or
        (c.state='processing' and c.lease_until<=v_now))
    order by c.issued_at,c.request_id
    for update skip locked limit p_max
  )
  update nohut_private.commands c set state='processing',
    lease_until=v_now+interval '60 seconds',lease_generation=c.lease_generation+1
  from picked p where c.restaurant_id=p.restaurant_id and c.request_id=p.request_id
  returning c.envelope,c.lease_generation;
end $$;

-- A lost acknowledgement can be retried by the same lease generation with
-- exactly the same result. Older generations cannot overwrite newer claims.
create function nohut_private.complete_command(
  p_restaurant uuid, p_epoch uuid, p_request text, p_generation bigint, p_result jsonb
) returns text language plpgsql security invoker set search_path=pg_catalog,nohut_private
as $$
declare c nohut_private.commands%rowtype; v_state text; v_now timestamptz := clock_timestamp();
begin
  if p_generation is null or p_generation<=0 or jsonb_typeof(p_result) is distinct from 'object'
    or (p_result->>'state') is null or (p_result->>'state') not in
    ('confirmed','conflict','rejected','expired','reconciliation_required') then
    raise exception 'invalid completion' using errcode='22023';
  end if;
  v_state:=p_result->>'state';
  perform 1 from nohut_private.authority_epochs a
    where a.restaurant_id=p_restaurant and a.authority_epoch=p_epoch and a.retired_at is null
    for share;
  if not found then raise exception 'inactive authority' using errcode='42501'; end if;
  select * into c from nohut_private.commands q
    where q.restaurant_id=p_restaurant and q.authority_epoch=p_epoch and q.request_id=p_request
    for update;
  if not found or c.lease_generation<>p_generation then return 'stale_claim'; end if;
  if c.state not in ('pending','processing') then
    if c.result=p_result then return 'duplicate'; else return 'conflict'; end if;
  end if;
  if c.state<>'processing' or c.lease_until<=v_now then return 'stale_claim'; end if;
  update nohut_private.commands q set state=v_state,lease_until=null,result=p_result
    where q.restaurant_id=p_restaurant and q.request_id=p_request;
  return 'accepted';
end $$;
revoke all on function nohut_private.claim_commands(uuid,uuid,integer) from public,anon,authenticated,service_role;
revoke all on function nohut_private.complete_command(uuid,uuid,text,bigint,jsonb) from public,anon,authenticated,service_role;
commit;
