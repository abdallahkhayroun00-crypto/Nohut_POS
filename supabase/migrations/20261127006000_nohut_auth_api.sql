-- Phase 3B (Claude): the client-callable auth API over the Phase 3A control
-- plane. Only `authenticated` may execute these; anon/public get nothing.
-- Identity ALWAYS comes from the verified JWT (auth.uid(), session_id, aal),
-- never from arguments. Every function is SECURITY DEFINER with an empty
-- search_path and delegates to nohut_private.
begin;

-- JWT claims as provided by Supabase/PostgREST (request.jwt.claims).
create function public.nohut_jwt_claim(p_name text)
returns text language plpgsql stable set search_path = '' as $$
begin
  return nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> p_name;
end $$;

-- Session state without a specific operation: used to decide whether the
-- app may show anything at all.
create function nohut_private.session_status(p_user_id uuid, p_session_id uuid, p_device_id uuid, p_client text)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare u nohut_private.app_users;
begin
  select * into u from nohut_private.app_users where user_id = p_user_id;
  if not found then return 'unknown_user'; end if;
  if not u.active then return 'inactive'; end if;
  if not exists (select 1 from nohut_private.devices d where d.device_id = p_device_id and d.user_id = p_user_id
                 and d.revoked_at is null and d.client = p_client) then return 'device_revoked'; end if;
  if not exists (select 1 from nohut_private.sessions s where s.session_id = p_session_id and s.user_id = p_user_id
                 and s.device_id = p_device_id and s.revoked_at is null) then return 'session_revoked'; end if;
  update nohut_private.sessions set last_seen_at = now() where session_id = p_session_id;
  update nohut_private.devices set last_seen_at = now() where device_id = p_device_id;
  return 'ok';
end $$;

-- After a password login: register this device + provider session.
create function public.nohut_register_device(p_device_id uuid, p_client text, p_label text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_client not in ('personel', 'yonetici') then raise exception 'client_not_allowed' using errcode = '42501'; end if;
  perform nohut_private.enroll_device(auth.uid(), p_device_id, public.nohut_jwt_claim('session_id')::uuid, p_client, p_label);
end $$;

-- What the app may show: profile + grants valid for THIS app only.
create function public.nohut_whoami(p_device_id uuid, p_client text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  st text := nohut_private.session_status(uid, public.nohut_jwt_claim('session_id')::uuid, p_device_id, p_client);
  u nohut_private.app_users;
begin
  if st <> 'ok' then return jsonb_build_object('status', st); end if;
  select * into u from nohut_private.app_users where user_id = uid;
  return jsonb_build_object(
    'status', 'ok',
    'username', u.username,
    'role', u.role_template,
    'is_owner', u.is_owner,
    'employee_id', u.pos_employee_id,
    'permission_version', u.permission_version,
    'mfa', public.nohut_jwt_claim('aal') = 'aal2',
    'has_pin', exists (select 1 from nohut_private.devices d where d.device_id = p_device_id and d.pin_verifier is not null),
    'grants', (select coalesce(jsonb_agg(g order by g), '[]'::jsonb)
               from unnest(nohut_private.effective_grants(uid)) g
               join nohut_private.operation_catalogue c on c.operation_id = g
               where p_client = any(c.clients)));
end $$;

-- Server-side check for any app request (PR-05B RPCs use the private one).
create function public.nohut_authorize(p_device_id uuid, p_client text, p_operation text, p_permission_version bigint)
returns text language sql security definer set search_path = '' as $$
  select nohut_private.authorize(auth.uid(), public.nohut_jwt_claim('session_id')::uuid, p_device_id, p_client, p_operation, p_permission_version)
$$;

create function public.nohut_set_pin(p_device_id uuid, p_pin text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform nohut_private.set_pin(auth.uid(), p_device_id, public.nohut_jwt_claim('session_id')::uuid, p_pin);
end $$;

create function public.nohut_verify_pin(p_device_id uuid, p_pin text)
returns text language sql security definer set search_path = '' as $$
  select nohut_private.verify_pin(auth.uid(), p_device_id, p_pin)
$$;

-- Logout of this device's session.
create function public.nohut_logout(p_device_id uuid)
returns void language sql security definer set search_path = '' as $$
  update nohut_private.sessions set revoked_at = now()
   where user_id = auth.uid() and device_id = p_device_id
     and session_id = public.nohut_jwt_claim('session_id')::uuid and revoked_at is null
$$;

-- Owner administration (requires aal2 inside nohut_private.require_owner).
create function public.nohut_admin_set_grant(p_target uuid, p_operation text, p_granted boolean)
returns bigint language sql security definer set search_path = '' as $$
  select nohut_private.admin_set_grant(auth.uid(), public.nohut_jwt_claim('aal'), p_target, p_operation, p_granted)
$$;
create function public.nohut_admin_set_active(p_target uuid, p_active boolean)
returns void language sql security definer set search_path = '' as $$
  select nohut_private.admin_set_active(auth.uid(), public.nohut_jwt_claim('aal'), p_target, p_active)
$$;
create function public.nohut_admin_revoke_sessions(p_target uuid, p_devices_too boolean)
returns integer language sql security definer set search_path = '' as $$
  select nohut_private.admin_revoke_sessions(auth.uid(), public.nohut_jwt_claim('aal'), p_target, p_devices_too)
$$;
create function public.nohut_admin_reset_pin(p_target uuid)
returns void language sql security definer set search_path = '' as $$
  select nohut_private.admin_reset_pin(auth.uid(), public.nohut_jwt_claim('aal'), p_target)
$$;
-- The provider identity itself is created by the login backend with the
-- owner-approved server key; this links it as an app user.
create function public.nohut_admin_create_user(p_user_id uuid, p_username text, p_pos_employee_id integer, p_role text)
returns void language sql security definer set search_path = '' as $$
  select nohut_private.admin_create_user(auth.uid(), public.nohut_jwt_claim('aal'), p_user_id, p_username, p_pos_employee_id, p_role)
$$;
-- Owner's list of users (Kullanıcılar & Yetkiler, Bağlı Cihazlar, Son Giriş).
create function public.nohut_admin_users()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o nohut_private.app_users;
begin
  o := nohut_private.require_owner(auth.uid(), public.nohut_jwt_claim('aal'));
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'user_id', u.user_id, 'username', u.username, 'role', u.role_template, 'active', u.active,
      'is_owner', u.is_owner, 'employee_id', u.pos_employee_id, 'last_login_at', u.last_login_at,
      'grants', to_jsonb(nohut_private.effective_grants(u.user_id)),
      'devices', (select count(*) from nohut_private.devices d where d.user_id = u.user_id and d.revoked_at is null))
      order by u.username), '[]'::jsonb)
    from nohut_private.app_users u where u.restaurant_id = o.restaurant_id);
end $$;

revoke all on function public.nohut_jwt_claim(text) from public, anon;
revoke all on function nohut_private.session_status(uuid, uuid, uuid, text) from public, anon, authenticated, service_role;
do $$
declare f text;
begin
  foreach f in array array[
    'public.nohut_register_device(uuid,text,text)', 'public.nohut_whoami(uuid,text)',
    'public.nohut_authorize(uuid,text,text,bigint)', 'public.nohut_set_pin(uuid,text)',
    'public.nohut_verify_pin(uuid,text)', 'public.nohut_logout(uuid)',
    'public.nohut_admin_set_grant(uuid,text,boolean)', 'public.nohut_admin_set_active(uuid,boolean)',
    'public.nohut_admin_revoke_sessions(uuid,boolean)', 'public.nohut_admin_reset_pin(uuid)',
    'public.nohut_admin_create_user(uuid,text,integer,text)', 'public.nohut_admin_users()'] loop
    execute format('revoke all on function %s from public, anon, service_role', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
grant execute on function public.nohut_jwt_claim(text) to authenticated;

commit;
