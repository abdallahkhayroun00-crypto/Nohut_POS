-- PR-05B / Phase 5B: recheck authorization before dispatch to Windows.
-- Keep raw queue primitives private. The future authenticated agent
-- transport MUST use claim_authorized_commands, not claim_commands.
begin;
create function nohut_private.command_still_authorized(p_restaurant uuid,p_env jsonb)
returns boolean language plpgsql stable security invoker set search_path=pg_catalog,nohut_private
as $$
declare u uuid; s uuid; d uuid; v bigint; a jsonb;
begin
  u:=(p_env->>'actor_user_id')::uuid;
  s:=(p_env->>'device_session_id')::uuid;
  d:=(p_env->>'device_id')::uuid;
  v:=(p_env->'actor'->>'permission_version')::bigint;
  if u is null or s is null or d is null or v is null
    or p_env->>'restaurant_id' is distinct from p_restaurant::text
    or not exists(select 1 from nohut_private.app_users x
      where x.user_id=u and x.restaurant_id=p_restaurant) then return false; end if;
  if nohut_private.authorize(u,s,d,p_env->>'client',p_env->>'operation',v) is distinct from 'ok' then
    return false;
  end if;
  a:=nohut_private.command_actor(u);
  return a is not null
    and (a->>'employee_id') is not null
    and a->>'employee_id'=p_env->'actor'->>'employee_id'
    and a->>'is_owner'=p_env->'actor'->>'is_owner'
    and a->>'permission_version'=p_env->'actor'->>'permission_version';
exception when invalid_text_representation or numeric_value_out_of_range then
  return false;
end $$;

create function nohut_private.claim_authorized_commands(p_restaurant uuid,p_epoch uuid,p_max integer)
returns table(envelope jsonb,lease_generation bigint)
language plpgsql security invoker set search_path=pg_catalog,nohut_private
as $$
declare v_now timestamptz:=clock_timestamp();
begin
  if p_max is null or p_max not between 1 and 20 then
    raise exception 'invalid claim limit' using errcode='22023';
  end if;
  perform 1 from nohut_private.authority_epochs a where a.restaurant_id=p_restaurant
    and a.authority_epoch=p_epoch and a.retired_at is null for update;
  if not found then raise exception 'inactive authority' using errcode='42501'; end if;
  if not exists(select 1 from nohut_private.sync_migrations m where m.restaurant_id=p_restaurant
      and m.authority_epoch=p_epoch and m.status='active') then
    raise exception 'sync not activated' using errcode='42501';
  end if;
  -- Never claimed: safe to reject. Previously claimed: execution may
  -- already have committed, so the outcome is unknown, never rejected.
  update nohut_private.commands q set state='rejected',
    result=jsonb_build_object('state','rejected','code','authorization_revoked')
    where q.restaurant_id=p_restaurant and q.authority_epoch=p_epoch
      and q.state='pending' and q.expires_at>v_now
      and nohut_private.command_still_authorized(p_restaurant,q.envelope) is not true;
  update nohut_private.commands q set state='reconciliation_required',lease_until=null,
    result=jsonb_build_object('state','reconciliation_required','code','authorization_revoked_outcome_unknown')
    where q.restaurant_id=p_restaurant and q.authority_epoch=p_epoch
      and q.state='processing' and q.lease_until<=v_now
      and nohut_private.command_still_authorized(p_restaurant,q.envelope) is not true;
  -- Claim and recheck together in one SQL statement. A command that was
  -- revoked between cleanup and selection stays queued for the next sweep.
  v_now:=clock_timestamp();
  update nohut_private.commands q set state='expired',
    result=jsonb_build_object('state','expired','code','expired')
    where q.restaurant_id=p_restaurant and q.authority_epoch=p_epoch
      and q.state='pending' and q.expires_at<=v_now;
  update nohut_private.commands q set state='reconciliation_required',lease_until=null,
    result=jsonb_build_object('state','reconciliation_required','code','claim_expired_outcome_unknown')
    where q.restaurant_id=p_restaurant and q.authority_epoch=p_epoch
      and q.state='processing' and q.expires_at<=v_now and q.lease_until<=v_now;
  return query
  with picked as (
    select q.restaurant_id,q.request_id from nohut_private.commands q
    where q.restaurant_id=p_restaurant and q.authority_epoch=p_epoch
      and q.expires_at>v_now and (q.state='pending' or
        (q.state='processing' and q.lease_until<=v_now))
      and nohut_private.command_still_authorized(p_restaurant,q.envelope) is true
    order by q.issued_at,q.request_id for update skip locked limit p_max
  )
  update nohut_private.commands q set state='processing',lease_until=v_now+interval '60 seconds',
    lease_generation=q.lease_generation+1
    from picked k where q.restaurant_id=k.restaurant_id and q.request_id=k.request_id
    returning q.envelope,q.lease_generation;
end $$;
revoke all on function nohut_private.command_still_authorized(uuid,jsonb) from public,anon,authenticated,service_role;
revoke all on function nohut_private.claim_authorized_commands(uuid,uuid,integer) from public,anon,authenticated,service_role;
commit;
