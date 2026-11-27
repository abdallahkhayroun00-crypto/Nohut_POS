-- Consume Claude A1 Windows owner-session contract; no competing authentication.
begin;
create or replace function nohut_private.enroll_windows_agent(
  p_owner uuid,p_session uuid,p_owner_device uuid,p_aal text,p_version bigint,
  p_windows_device uuid,p_epoch uuid
) returns jsonb language plpgsql security invoker set search_path=pg_catalog,nohut_private
as $$
declare owner_row nohut_private.app_users%rowtype; old_device uuid; token text; aid uuid; expiry timestamptz;
begin
  owner_row:=nohut_private.require_owner(p_owner,p_aal);
  if nohut_private.authorize(p_owner,p_session,p_owner_device,'windows','sync.cloud.configure',p_version) is distinct from 'ok'
     or p_windows_device is distinct from p_owner_device or p_windows_device is null or p_epoch is null then
    raise exception 'owner enrollment denied' using errcode='42501';
  end if;
  perform 1 from nohut_private.authority_epochs a where a.restaurant_id=owner_row.restaurant_id
    and a.authority_epoch=p_epoch and a.retired_at is null for update;
  if not found then raise exception 'authority not active' using errcode='42501'; end if;
  if nohut_private.authorize(p_owner,p_session,p_owner_device,'windows','sync.cloud.configure',p_version) is distinct from 'ok' then
    raise exception 'owner session revoked' using errcode='42501';
  end if;
  -- Preserve the original device association even after explicit revoke.
  select x.windows_device_id into old_device from nohut_private.windows_agents x
    where x.restaurant_id=owner_row.restaurant_id and x.authority_epoch=p_epoch
    order by x.created_at desc limit 1;
  if found and old_device is distinct from p_windows_device then
    raise exception 'device change requires new authority epoch' using errcode='42501';
  end if;
  update nohut_private.windows_agents x set revoked_at=clock_timestamp()
    where x.restaurant_id=owner_row.restaurant_id and x.authority_epoch=p_epoch and x.revoked_at is null;
  token:=encode(extensions.gen_random_bytes(32),'hex');
  expiry:=clock_timestamp()+interval '30 days';
  insert into nohut_private.windows_agents(restaurant_id,authority_epoch,windows_device_id,token_sha256,expires_at)
    values(owner_row.restaurant_id,p_epoch,p_windows_device,sha256(convert_to(token,'UTF8')),expiry)
    returning agent_id into aid;
  -- Token shown once over the trusted API; never logged or persisted raw.
  return jsonb_build_object('agent_id',aid,'token',token,'expires_at',expiry);
end $$;

create table nohut_private.agent_enrollment_requests(
  restaurant_id uuid not null references nohut_private.restaurants,request_id uuid not null,
  user_id uuid not null references nohut_private.app_users,device_id uuid not null references nohut_private.devices,
  authority_epoch uuid not null,token_sha256 bytea not null check(octet_length(token_sha256)=32),
  agent_id uuid not null references nohut_private.windows_agents,created_at timestamptz not null default clock_timestamp(),
  primary key(restaurant_id,request_id),foreign key(restaurant_id,authority_epoch) references nohut_private.authority_epochs
);
alter table nohut_private.agent_enrollment_requests enable row level security;
alter table nohut_private.agent_enrollment_requests force row level security;
do $$ begin execute format('create policy agent_setup_owner on nohut_private.agent_enrollment_requests for all to %I using (true) with check (true)',current_user); end $$;
revoke all on nohut_private.agent_enrollment_requests from public,anon,authenticated,service_role;

create function nohut_private.require_agent_owner(p_device uuid,p_version bigint)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare sid uuid:=public.nohut_jwt_claim('session_id')::uuid; ctx jsonb;
begin
  -- Hold identity/revocation rows through credential rotation or revocation.
  perform 1 from nohut_private.app_users u where u.user_id=auth.uid() for share;
  -- session_status updates session then device last_seen_at. Use the same
  -- order and exclusive row locks to avoid shared-lock upgrade deadlocks.
  perform 1 from nohut_private.sessions s where s.session_id=sid and s.user_id=auth.uid() for update;
  perform 1 from nohut_private.devices d where d.device_id=p_device and d.user_id=auth.uid() for update;
  ctx:=public.nohut_windows_owner_session(p_device);
  if ctx->>'status' is distinct from 'ok' or nohut_private.authorize(auth.uid(),sid,p_device,'windows','sync.cloud.configure',p_version) is distinct from 'ok' then
    raise exception 'Windows owner setup denied' using errcode='42501'; end if;
  return ctx;
end $$;
revoke all on function nohut_private.require_agent_owner(uuid,bigint) from public,anon,authenticated,service_role;

create function public.nohut_enroll_agent(p_device_id uuid,p_permission_version bigint,p_epoch uuid,p_request_id uuid,p_token_sha256 text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx jsonb; r uuid; prior nohut_private.agent_enrollment_requests; a nohut_private.windows_agents; info jsonb; h bytea;
begin
  ctx:=nohut_private.require_agent_owner(p_device_id,p_permission_version);r:=(ctx->>'restaurant_id')::uuid;
  if p_epoch is null or p_request_id is null or p_token_sha256 is null or p_token_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid enrollment request' using errcode='22023'; end if;
  h:=decode(p_token_sha256,'hex');
  perform 1 from nohut_private.authority_epochs e where e.restaurant_id=r and e.authority_epoch=p_epoch and e.retired_at is null for update;
  if not found then raise exception 'authority not active' using errcode='42501'; end if;
  select * into prior from nohut_private.agent_enrollment_requests q where q.restaurant_id=r and q.request_id=p_request_id for update;
  if found then
    if prior.user_id<>auth.uid() or prior.device_id<>p_device_id or prior.authority_epoch<>p_epoch or prior.token_sha256<>h then
      raise exception 'enrollment request conflict' using errcode='22023'; end if;
    select * into strict a from nohut_private.windows_agents x where x.agent_id=prior.agent_id and x.restaurant_id=r;
    if a.revoked_at is not null or a.expires_at<=clock_timestamp() then return jsonb_build_object('status','revoked'); end if;
  else
    if exists(select 1 from nohut_private.windows_agents x where x.token_sha256=h) then raise exception 'credential already used' using errcode='22023'; end if;
    info:=nohut_private.enroll_windows_agent(auth.uid(),(ctx->>'session_id')::uuid,p_device_id,ctx->>'aal',p_permission_version,p_device_id,p_epoch);
    update nohut_private.windows_agents x set token_sha256=h where x.agent_id=(info->>'agent_id')::uuid returning * into a;
    insert into nohut_private.agent_enrollment_requests(restaurant_id,request_id,user_id,device_id,authority_epoch,token_sha256,agent_id)
      values(r,p_request_id,auth.uid(),p_device_id,p_epoch,h,a.agent_id);
  end if;
  return jsonb_build_object('status','enrolled','agent_id',a.agent_id,'restaurant_id',r,'authority_epoch',a.authority_epoch,
    'windows_device_id',a.windows_device_id,'expires_at',a.expires_at,'schema_version',1);
end $$;

create function public.nohut_revoke_agent(p_device_id uuid,p_permission_version bigint,p_agent_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx jsonb; a nohut_private.windows_agents;
begin
  ctx:=nohut_private.require_agent_owner(p_device_id,p_permission_version);
  -- Same epoch-first lock order as token authentication and enrollment.
  perform 1 from nohut_private.authority_epochs e join nohut_private.windows_agents x using(restaurant_id,authority_epoch)
    where x.agent_id=p_agent_id and x.restaurant_id=(ctx->>'restaurant_id')::uuid for update of e;
  if not found then raise exception 'agent revocation denied' using errcode='42501'; end if;
  update nohut_private.windows_agents x set revoked_at=coalesce(x.revoked_at,clock_timestamp())
    where x.agent_id=p_agent_id and x.restaurant_id=(ctx->>'restaurant_id')::uuid returning * into a;
  return jsonb_build_object('status','revoked','agent_id',a.agent_id);
end $$;
revoke all on function public.nohut_enroll_agent(uuid,bigint,uuid,uuid,text),public.nohut_revoke_agent(uuid,bigint,uuid) from public,anon,authenticated,service_role;
grant execute on function public.nohut_enroll_agent(uuid,bigint,uuid,uuid,text),public.nohut_revoke_agent(uuid,bigint,uuid) to authenticated;

create or replace function nohut_private.revoke_windows_agent(
  p_owner uuid,p_session uuid,p_owner_device uuid,p_aal text,p_version bigint,p_agent uuid
) returns boolean language plpgsql security invoker set search_path=pg_catalog,nohut_private
as $$
declare owner_row nohut_private.app_users%rowtype;
begin
  owner_row:=nohut_private.require_owner(p_owner,p_aal);
  if nohut_private.authorize(p_owner,p_session,p_owner_device,'windows','sync.cloud.configure',p_version) is distinct from 'ok' then
    raise exception 'owner revocation denied' using errcode='42501';
  end if;
  update nohut_private.windows_agents x set revoked_at=clock_timestamp()
    where x.agent_id=p_agent and x.restaurant_id=owner_row.restaurant_id and x.revoked_at is null;
  return found;
end $$;


commit;
