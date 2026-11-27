-- Phase 3 / task A1 (Claude): Windows owner session for the Windows POS agent.
-- Requested by PR #39 (ChatGPT Codex). Adds a 'windows' device client that
-- only the active owner with MFA (JWT aal2) can enroll, lets Windows-only
-- operations (sync.*, backup.*) authorize ONLY from such a device, and keeps
-- refusing them ('windows_only') from every phone/web client, owner included.
begin;

alter table nohut_private.devices drop constraint devices_client_check;
alter table nohut_private.devices
  add constraint devices_client_check check (client in ('windows', 'personel', 'yonetici'));

-- Same checks and refusal codes as 20261127005000; only the Windows-only
-- branch changes: it is refused for remote clients and evaluated normally
-- (owner / explicit grant / ownerOnly) for an enrolled Windows device.
create or replace function nohut_private.authorize(
  p_user_id uuid, p_session_id uuid, p_device_id uuid, p_client text,
  p_operation text, p_permission_version bigint)
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  u nohut_private.app_users;
  op nohut_private.operation_catalogue;
begin
  select * into u from nohut_private.app_users where user_id = p_user_id;
  if not found then return 'unknown_user'; end if;
  if not u.active then return 'inactive'; end if;
  if not exists (select 1 from nohut_private.devices d
                 where d.device_id = p_device_id and d.user_id = p_user_id
                   and d.revoked_at is null and d.client = p_client) then
    return 'device_revoked';
  end if;
  if not exists (select 1 from nohut_private.sessions s
                 where s.session_id = p_session_id and s.user_id = p_user_id
                   and s.device_id = p_device_id and s.revoked_at is null) then
    return 'session_revoked';
  end if;
  if p_permission_version is distinct from u.permission_version then return 'stale_permissions'; end if;
  select * into op from nohut_private.operation_catalogue where operation_id = p_operation;
  if not found then return 'unknown_operation'; end if;
  if op.clients = array['windows']::text[] and p_client <> 'windows' then return 'windows_only'; end if;
  if not (p_client = any(op.clients)) then return 'client_not_allowed'; end if;
  if op.sensitivity = 'ownerOnly' then
    return case when u.is_owner then 'ok' else 'forbidden' end;
  end if;
  if u.is_owner or exists (select 1 from nohut_private.user_grants g
                           where g.user_id = p_user_id and g.operation_id = p_operation) then
    return 'ok';
  end if;
  return 'forbidden';
end $$;

-- After a password login: register this device + provider session.
-- 'windows' requires the active owner with MFA; phones keep their two apps.
create or replace function public.nohut_register_device(p_device_id uuid, p_client text, p_label text)
returns void language plpgsql security definer set search_path = '' as $$
declare o nohut_private.app_users;
begin
  if p_client is null or p_client not in ('windows', 'personel', 'yonetici') then
    raise exception 'client_not_allowed' using errcode = '42501';
  end if;
  if p_client = 'windows' then
    begin
      o := nohut_private.require_owner(auth.uid(), public.nohut_jwt_claim('aal'));
    exception when insufficient_privilege then
      raise exception 'windows_enrollment_requires_owner_mfa' using errcode = '42501';
    end;
  end if;
  perform nohut_private.enroll_device(auth.uid(), p_device_id, public.nohut_jwt_claim('session_id')::uuid, p_client, p_label);
  -- A device id first enrolled for another app never becomes a Windows device.
  if not exists (select 1 from nohut_private.devices
                 where device_id = p_device_id and user_id = auth.uid() and client = p_client) then
    raise exception 'device_client_mismatch' using errcode = '42501';
  end if;
end $$;

-- The verified Windows owner session the Windows agent enrollment binds to
-- (PR #39). Refuses unless: active owner, JWT aal2, live session on an
-- unrevoked 'windows' device of that owner.
create function public.nohut_windows_owner_session(p_device_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  sid uuid := public.nohut_jwt_claim('session_id')::uuid;
  st text := nohut_private.session_status(uid, sid, p_device_id, 'windows');
  u nohut_private.app_users;
begin
  if st <> 'ok' then return jsonb_build_object('status', st); end if;
  select * into u from nohut_private.app_users where user_id = uid;
  if not u.is_owner then return jsonb_build_object('status', 'forbidden'); end if;
  if public.nohut_jwt_claim('aal') is distinct from 'aal2' then return jsonb_build_object('status', 'mfa_required'); end if;
  return jsonb_build_object(
    'status', 'ok',
    'user_id', uid,
    'session_id', sid,
    'device_id', p_device_id,
    'restaurant_id', u.restaurant_id,
    'aal', 'aal2',
    'permission_version', u.permission_version);
end $$;

revoke all on function public.nohut_windows_owner_session(uuid) from public, anon;
grant execute on function public.nohut_windows_owner_session(uuid) to authenticated;
revoke all on function public.nohut_register_device(uuid, text, text) from public, anon;
grant execute on function public.nohut_register_device(uuid, text, text) to authenticated;
revoke all on function nohut_private.authorize(uuid, uuid, uuid, text, text, bigint) from public, anon, authenticated, service_role;

commit;
