-- PR-05B: private scoped Windows agent identities.
-- All entrypoints remain internal until the reviewed TLS API and DPAPI
-- storage are available. No service_role key is issued to the register.
begin;
create table nohut_private.windows_agents (
  agent_id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null,
  authority_epoch uuid not null,
  windows_device_id uuid not null,
  token_sha256 bytea not null unique check (octet_length(token_sha256)=32),
  created_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  foreign key(restaurant_id,authority_epoch) references nohut_private.authority_epochs,
  check(expires_at>created_at)
);
create unique index one_live_agent_per_authority on nohut_private.windows_agents(restaurant_id,authority_epoch) where revoked_at is null;
alter table nohut_private.windows_agents enable row level security;
alter table nohut_private.windows_agents force row level security;
do $$ begin
  execute format('create policy cloud_agent_owner on nohut_private.windows_agents for all to %I using (true) with check (true)',current_user);
end $$;
revoke all on nohut_private.windows_agents from public,anon,authenticated,service_role;

-- Trusted API supplies owner identity and AAL from its verified JWT,
-- not from client arguments. Enrollment/rotation requires an active
-- manager app session and MFA. Different PC requires an authority change.
create function nohut_private.enroll_windows_agent(
  p_owner uuid,p_session uuid,p_owner_device uuid,p_aal text,p_version bigint,
  p_windows_device uuid,p_epoch uuid
) returns jsonb language plpgsql security invoker set search_path=pg_catalog,nohut_private
as $$
declare owner_row nohut_private.app_users%rowtype; old_device uuid; token text; aid uuid; expiry timestamptz;
begin
  owner_row:=nohut_private.require_owner(p_owner,p_aal);
  if nohut_private.authorize(p_owner,p_session,p_owner_device,'yonetici','users.manage',p_version) is distinct from 'ok'
     or p_windows_device is null or p_epoch is null then
    raise exception 'owner enrollment denied' using errcode='42501';
  end if;
  perform 1 from nohut_private.authority_epochs a where a.restaurant_id=owner_row.restaurant_id
    and a.authority_epoch=p_epoch and a.retired_at is null for update;
  if not found then raise exception 'authority not active' using errcode='42501'; end if;
  if nohut_private.authorize(p_owner,p_session,p_owner_device,'yonetici','users.manage',p_version) is distinct from 'ok' then
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

create function nohut_private.revoke_windows_agent(
  p_owner uuid,p_session uuid,p_owner_device uuid,p_aal text,p_version bigint,p_agent uuid
) returns boolean language plpgsql security invoker set search_path=pg_catalog,nohut_private
as $$
declare owner_row nohut_private.app_users%rowtype;
begin
  owner_row:=nohut_private.require_owner(p_owner,p_aal);
  if nohut_private.authorize(p_owner,p_session,p_owner_device,'yonetici','users.manage',p_version) is distinct from 'ok' then
    raise exception 'owner revocation denied' using errcode='42501';
  end if;
  update nohut_private.windows_agents x set revoked_at=clock_timestamp()
    where x.agent_id=p_agent and x.restaurant_id=owner_row.restaurant_id and x.revoked_at is null;
  return found;
end $$;

-- Resolve tenant/epoch/device only from the opaque credential, never from
-- a supplied restaurant identifier. Hold the authority and token rows for
-- the caller's transaction so revocation/rotation cannot race its write.
create function nohut_private.authenticate_windows_agent(p_token text)
returns nohut_private.windows_agents language plpgsql security invoker set search_path=pg_catalog,nohut_private
as $$
declare a nohut_private.windows_agents%rowtype; h bytea;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    raise exception 'agent authentication failed' using errcode='42501';
  end if;
  h:=sha256(convert_to(p_token,'UTF8'));
  select * into a from nohut_private.windows_agents x where x.token_sha256=h;
  if not found then raise exception 'agent authentication failed' using errcode='42501'; end if;
  perform 1 from nohut_private.authority_epochs e where e.restaurant_id=a.restaurant_id
    and e.authority_epoch=a.authority_epoch and e.retired_at is null for update;
  if not found then raise exception 'agent authentication failed' using errcode='42501'; end if;
  select * into a from nohut_private.windows_agents x where x.token_sha256=h
    and x.revoked_at is null and x.expires_at>clock_timestamp() for share;
  if not found then raise exception 'agent authentication failed' using errcode='42501'; end if;
  return a;
end $$;

create function nohut_private.agent_claim(p_token text,p_max integer)
returns table(envelope jsonb,lease_generation bigint)
language plpgsql security invoker set search_path=pg_catalog,nohut_private
as $$
declare a nohut_private.windows_agents%rowtype;
begin
  a:=nohut_private.authenticate_windows_agent(p_token);
  return query select c.envelope,c.lease_generation from nohut_private.claim_authorized_commands(a.restaurant_id,a.authority_epoch,p_max) c;
end $$;
create function nohut_private.agent_complete(p_token text,p_request text,p_generation bigint,p_result jsonb)
returns text language plpgsql security invoker set search_path=pg_catalog,nohut_private
as $$
declare a nohut_private.windows_agents%rowtype;
begin
  a:=nohut_private.authenticate_windows_agent(p_token);
  return nohut_private.complete_command(a.restaurant_id,a.authority_epoch,p_request,p_generation,p_result);
end $$;
create function nohut_private.agent_ingest(p_token text,p_tx jsonb)
returns jsonb language plpgsql security invoker set search_path=pg_catalog,nohut_private
as $$
declare a nohut_private.windows_agents%rowtype;
begin
  a:=nohut_private.authenticate_windows_agent(p_token);
  return nohut_private.ingest_sync_transaction(a.restaurant_id,a.authority_epoch,p_tx);
end $$;
create function nohut_private.agent_checkpoint(p_token text)
returns jsonb language plpgsql security invoker set search_path=pg_catalog,nohut_private
as $$
declare a nohut_private.windows_agents%rowtype; result jsonb;
begin
  a:=nohut_private.authenticate_windows_agent(p_token);
  select jsonb_build_object('last_acked_seq',c.last_acked_seq,'last_acked_revision',c.last_acked_revision)
    into result from nohut_private.sync_checkpoints c where c.restaurant_id=a.restaurant_id and c.authority_epoch=a.authority_epoch;
  if not found then raise exception 'checkpoint not provisioned' using errcode='42501'; end if;
  return result;
end $$;
revoke all on function nohut_private.enroll_windows_agent(uuid,uuid,uuid,text,bigint,uuid,uuid),
 nohut_private.revoke_windows_agent(uuid,uuid,uuid,text,bigint,uuid),
 nohut_private.authenticate_windows_agent(text),nohut_private.agent_claim(text,integer),
 nohut_private.agent_complete(text,text,bigint,jsonb),nohut_private.agent_ingest(text,jsonb),
 nohut_private.agent_checkpoint(text) from public,anon,authenticated,service_role;
commit;
