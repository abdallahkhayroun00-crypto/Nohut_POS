-- Phase 3A (spec §9, §20.3, §22.3): authentication & authorization CONTROL
-- PLANE. Separate from the business projection (§9.1). Owned by Claude Code;
-- the contract for PR-05B RPCs is documented in docs/cloud-sync/PROGRESS.md.
--
-- * Passwords are NEVER stored here: login identity is the provider's
--   (Supabase Auth) user UUID. This schema maps it to an employee, role
--   template, per-user grants, devices and sessions.
-- * PIN verifiers are bcrypt (pgcrypto) per device; plaintext PINs never
--   stored or logged. Five failures lock the PIN (password re-login).
-- * Every function is SECURITY DEFINER with an EMPTY search_path and fully
--   qualified names. No grants to anon / authenticated / service_role: the
--   API layer (PR-05B, Phase 3B) calls these through its own scoped role.
-- * Owner-only operations can never be granted; Windows-only operations
--   (sync.*, backup.*) are refused for every remote client, even the owner.
-- Synthetic tests: supabase/tests/auth_control_plane_test.sql.
begin;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- Same contract as docs/contracts/v1/permissions.json (CI checks drift).
create table nohut_private.operation_catalogue (
  operation_id text primary key check (operation_id ~ '^[a-z]+(\.[a-z_]+)+$'),
  section text not null,
  sensitivity text not null check (sensitivity in ('normal', 'elevated', 'ownerOnly')),
  clients text[] not null check (clients <@ array['windows','personel','yonetici']::text[] and cardinality(clients) > 0),
  default_roles text[] not null
);
insert into nohut_private.operation_catalogue(operation_id, section, sensitivity, clients, default_roles) values
  ('menu.view', 'menu', 'normal', array['windows','personel','yonetici']::text[], array['Personel','Müdür','Yönetici','Muhasebe']::text[]),
  ('menu.product.edit', 'menu', 'elevated', array['windows','personel','yonetici']::text[], array['Müdür','Yönetici']::text[]),
  ('menu.price.edit', 'menu', 'elevated', array['windows','personel','yonetici']::text[], array['Yönetici']::text[]),
  ('menu.category.edit', 'menu', 'elevated', array['windows','personel','yonetici']::text[], array['Müdür','Yönetici']::text[]),
  ('menu.campaign.edit', 'menu', 'elevated', array['windows','personel','yonetici']::text[], array['Yönetici']::text[]),
  ('menu.stock.toggle', 'menu', 'normal', array['windows','personel','yonetici']::text[], array['Personel','Müdür','Yönetici']::text[]),
  ('menu.qr.publish', 'menu', 'elevated', array['windows','personel','yonetici']::text[], array['Yönetici']::text[]),
  ('sync.view', 'sync', 'normal', array['windows']::text[], array['Müdür','Yönetici']::text[]),
  ('sync.manual', 'sync', 'normal', array['windows']::text[], array['Müdür','Yönetici']::text[]),
  ('sync.retry', 'sync', 'normal', array['windows']::text[], array['Müdür','Yönetici']::text[]),
  ('sync.auto.configure', 'sync', 'elevated', array['windows']::text[], array['Yönetici']::text[]),
  ('sync.initial.start', 'sync', 'ownerOnly', array['windows']::text[], '{}'::text[]),
  ('sync.cloud.configure', 'sync', 'ownerOnly', array['windows']::text[], '{}'::text[]),
  ('sync.full_resync', 'sync', 'ownerOnly', array['windows']::text[], '{}'::text[]),
  ('backup.view', 'backup', 'normal', array['windows']::text[], array['Müdür','Yönetici']::text[]),
  ('backup.manual', 'backup', 'normal', array['windows']::text[], array['Müdür','Yönetici']::text[]),
  ('backup.auto.configure', 'backup', 'elevated', array['windows']::text[], array['Yönetici']::text[]),
  ('backup.verify', 'backup', 'normal', array['windows']::text[], array['Müdür','Yönetici']::text[]),
  ('backup.restore', 'backup', 'ownerOnly', array['windows']::text[], '{}'::text[]),
  ('backup.delete', 'backup', 'ownerOnly', array['windows']::text[], '{}'::text[]),
  ('permissions.update', 'admin', 'ownerOnly', array['windows','yonetici']::text[], '{}'::text[]),
  ('tables.view', 'tables', 'normal', array['windows','personel','yonetici']::text[], array['Personel','Müdür','Yönetici']::text[]),
  ('orders.create', 'orders', 'normal', array['windows','personel','yonetici']::text[], array['Personel','Müdür','Yönetici']::text[]),
  ('orders.edit', 'orders', 'elevated', array['windows','personel','yonetici']::text[], array['Müdür','Yönetici']::text[]),
  ('orders.move', 'orders', 'normal', array['windows','personel','yonetici']::text[], array['Personel','Müdür','Yönetici']::text[]),
  ('orders.release', 'orders', 'normal', array['windows','personel','yonetici']::text[], array['Personel','Müdür','Yönetici']::text[]),
  ('pickup.contact.view', 'orders', 'normal', array['windows','personel','yonetici']::text[], array['Personel','Müdür','Yönetici']::text[]),
  ('payments.take', 'payments', 'normal', array['windows','personel','yonetici']::text[], array['Personel','Müdür','Yönetici']::text[]),
  ('payments.correct', 'payments', 'elevated', array['windows','personel','yonetici']::text[], array['Müdür','Yönetici']::text[]),
  ('payments.refund', 'payments', 'elevated', array['windows','personel','yonetici']::text[], array['Yönetici']::text[]),
  ('receipts.print', 'receipts', 'normal', array['windows','personel','yonetici']::text[], array['Personel','Müdür','Yönetici']::text[]),
  ('online.view', 'online', 'normal', array['windows','personel','yonetici']::text[], array['Personel','Müdür','Yönetici']::text[]),
  ('online.act', 'online', 'normal', array['windows','personel','yonetici']::text[], array['Personel','Müdür','Yönetici']::text[]),
  ('shifts.self', 'shifts', 'normal', array['windows','personel','yonetici']::text[], array['Personel','Müdür','Yönetici']::text[]),
  ('payroll.self.view', 'payroll', 'normal', array['windows','personel','yonetici']::text[], array['Personel','Müdür','Yönetici']::text[]),
  ('dashboard.view', 'dashboard', 'normal', array['windows','yonetici']::text[], array['Müdür','Yönetici','Muhasebe']::text[]),
  ('sales.view', 'sales', 'normal', array['windows','yonetici']::text[], array['Müdür','Yönetici','Muhasebe']::text[]),
  ('finance.view', 'finance', 'normal', array['windows','yonetici']::text[], array['Yönetici','Muhasebe']::text[]),
  ('finance.edit', 'finance', 'elevated', array['windows','yonetici']::text[], array['Yönetici']::text[]),
  ('reports.view', 'reports', 'normal', array['windows','yonetici']::text[], array['Müdür','Yönetici','Muhasebe']::text[]),
  ('reports.export', 'reports', 'normal', array['windows','yonetici']::text[], array['Yönetici','Muhasebe']::text[]),
  ('staff.view', 'staff', 'normal', array['windows','yonetici']::text[], array['Müdür','Yönetici']::text[]),
  ('staff.manage', 'staff', 'elevated', array['windows','yonetici']::text[], array['Yönetici']::text[]),
  ('shifts.manage', 'staff', 'elevated', array['windows','yonetici']::text[], array['Müdür','Yönetici']::text[]),
  ('payroll.view', 'staff', 'normal', array['windows','yonetici']::text[], array['Yönetici','Muhasebe']::text[]),
  ('payroll.manage', 'staff', 'elevated', array['windows','yonetici']::text[], array['Yönetici']::text[]),
  ('accounts.view', 'accounts', 'normal', array['windows','yonetici']::text[], array['Müdür','Yönetici']::text[]),
  ('accounts.settle', 'accounts', 'elevated', array['windows','yonetici']::text[], array['Yönetici']::text[]),
  ('integrations.view', 'integrations', 'normal', array['windows','yonetici']::text[], array['Yönetici']::text[]),
  ('reviews.reply', 'integrations', 'elevated', array['windows','yonetici']::text[], array['Yönetici']::text[]),
  ('audit.view', 'admin', 'normal', array['windows','yonetici']::text[], array['Yönetici']::text[]),
  ('users.manage', 'admin', 'ownerOnly', array['windows','yonetici']::text[], '{}'::text[]);

create table nohut_private.app_users (
  user_id uuid primary key,                       -- provider (auth.users) id
  restaurant_id uuid not null references nohut_private.restaurants,
  username text not null check (username ~ '^[a-z0-9][a-z0-9._-]{2,31}$'),
  pos_employee_id integer,                        -- Windows employees[].id
  role_template text not null check (role_template in ('Personel', 'Müdür', 'Yönetici', 'Muhasebe')),
  is_owner boolean not null default false,
  active boolean not null default true,
  permission_version bigint not null default 1 check (permission_version > 0),
  created_at timestamptz not null default now(),
  deactivated_at timestamptz,
  last_login_at timestamptz,
  unique (restaurant_id, username),
  unique (restaurant_id, pos_employee_id)
);
create unique index app_users_one_owner on nohut_private.app_users(restaurant_id) where is_owner;

create table nohut_private.user_grants (
  user_id uuid not null references nohut_private.app_users on delete restrict,
  operation_id text not null references nohut_private.operation_catalogue,
  granted_by uuid references nohut_private.app_users,
  granted_at timestamptz not null default now(),
  primary key (user_id, operation_id)
);

create table nohut_private.devices (
  device_id uuid primary key,
  user_id uuid not null references nohut_private.app_users,
  client text not null check (client in ('personel', 'yonetici')),
  label text not null default '' check (length(label) <= 60),
  enrolled_at timestamptz not null default now(),
  last_seen_at timestamptz,
  revoked_at timestamptz,
  pin_verifier text,                              -- bcrypt; null = no PIN
  pin_failed_count integer not null default 0 check (pin_failed_count >= 0)
);

create table nohut_private.sessions (
  session_id uuid primary key,
  user_id uuid not null references nohut_private.app_users,
  device_id uuid not null references nohut_private.devices,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  revoked_at timestamptz
);

-- Security audit: identities and outcomes only, never credentials.
create table nohut_private.security_audit (
  audit_id bigint generated always as identity primary key,
  restaurant_id uuid not null references nohut_private.restaurants,
  actor_user_id uuid,
  action text not null,
  target_user_id uuid,
  detail jsonb not null default '{}'::jsonb,
  at timestamptz not null default now(),
  check (not (detail ?| array['password', 'pin', 'pin_verifier', 'token']))
);

-- Effective grants = explicit per-user grants; owner holds every remote
-- operation implicitly. Role templates only seed grants at creation.
create function nohut_private.effective_grants(p_user_id uuid)
returns text[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(c.operation_id order by c.operation_id), '{}'::text[])
  from nohut_private.app_users u
  join nohut_private.operation_catalogue c on true
  where u.user_id = p_user_id and u.active
    and (u.is_owner or (c.sensitivity <> 'ownerOnly' and exists (
      select 1 from nohut_private.user_grants g where g.user_id = u.user_id and g.operation_id = c.operation_id)))
$$;

-- THE server-side check. Returns 'ok' or a stable refusal code.
create function nohut_private.authorize(
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
  if op.clients = array['windows']::text[] then return 'windows_only'; end if;
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

-- Actor block for Windows command envelopes (remote_commands.dart).
create function nohut_private.command_actor(p_user_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'employee_id', u.pos_employee_id,
    'is_owner', u.is_owner,
    'grants', to_jsonb(nohut_private.effective_grants(u.user_id)),
    'permission_version', u.permission_version)
  from nohut_private.app_users u where u.user_id = p_user_id and u.active
$$;

-- Owner checks shared by the admin functions. p_aal is the JWT 'aal' claim
-- read by the API layer: owner administration requires MFA (aal2).
create function nohut_private.require_owner(p_actor uuid, p_aal text)
returns nohut_private.app_users language plpgsql stable security definer set search_path = '' as $$
declare u nohut_private.app_users;
begin
  select * into u from nohut_private.app_users where user_id = p_actor and active and is_owner;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_aal is distinct from 'aal2' then raise exception 'mfa_required' using errcode = '42501'; end if;
  return u;
end $$;

create function nohut_private.bump_permissions(p_user_id uuid)
returns void language sql security definer set search_path = '' as $$
  update nohut_private.app_users set permission_version = permission_version + 1 where user_id = p_user_id
$$;

-- Create an app user for an existing provider identity. Grants are seeded
-- from the role template (defaults), excluding owner-only and Windows-only.
create function nohut_private.admin_create_user(
  p_actor uuid, p_aal text, p_user_id uuid, p_username text,
  p_pos_employee_id integer, p_role text)
returns void language plpgsql security definer set search_path = '' as $$
declare o nohut_private.app_users;
begin
  o := nohut_private.require_owner(p_actor, p_aal);
  insert into nohut_private.app_users(user_id, restaurant_id, username, pos_employee_id, role_template)
  values (p_user_id, o.restaurant_id, lower(p_username), p_pos_employee_id, p_role);
  insert into nohut_private.user_grants(user_id, operation_id, granted_by)
  select p_user_id, c.operation_id, p_actor from nohut_private.operation_catalogue c
  where p_role = any(c.default_roles) and c.sensitivity <> 'ownerOnly' and c.clients <> array['windows']::text[];
  insert into nohut_private.security_audit(restaurant_id, actor_user_id, action, target_user_id, detail)
  values (o.restaurant_id, p_actor, 'user_created', p_user_id, jsonb_build_object('username', lower(p_username), 'role', p_role));
end $$;

create function nohut_private.admin_set_grant(
  p_actor uuid, p_aal text, p_target uuid, p_operation text, p_granted boolean)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  o nohut_private.app_users;
  op nohut_private.operation_catalogue;
  t nohut_private.app_users;
  v bigint;
begin
  o := nohut_private.require_owner(p_actor, p_aal);
  select * into t from nohut_private.app_users where user_id = p_target and restaurant_id = o.restaurant_id;
  if not found then raise exception 'unknown_user' using errcode = 'P0002'; end if;
  select * into op from nohut_private.operation_catalogue where operation_id = p_operation;
  if not found then raise exception 'unknown_operation' using errcode = 'P0002'; end if;
  if op.sensitivity = 'ownerOnly' then raise exception 'not_delegable' using errcode = '42501'; end if;
  if op.clients = array['windows']::text[] then raise exception 'windows_only' using errcode = '42501'; end if;
  if p_granted then
    insert into nohut_private.user_grants(user_id, operation_id, granted_by)
    values (p_target, p_operation, p_actor) on conflict do nothing;
  else
    delete from nohut_private.user_grants where user_id = p_target and operation_id = p_operation;
  end if;
  update nohut_private.app_users set permission_version = permission_version + 1
  where user_id = p_target returning permission_version into v;
  insert into nohut_private.security_audit(restaurant_id, actor_user_id, action, target_user_id, detail)
  values (o.restaurant_id, p_actor, case when p_granted then 'grant_added' else 'grant_removed' end, p_target,
          jsonb_build_object('operation', p_operation, 'permission_version', v));
  return v;
end $$;

-- Deactivation revokes every session and device immediately.
create function nohut_private.admin_set_active(p_actor uuid, p_aal text, p_target uuid, p_active boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare o nohut_private.app_users;
begin
  o := nohut_private.require_owner(p_actor, p_aal);
  if p_target = p_actor and not p_active then raise exception 'cannot_deactivate_owner' using errcode = '42501'; end if;
  update nohut_private.app_users
     set active = p_active, deactivated_at = case when p_active then null else now() end,
         permission_version = permission_version + 1
   where user_id = p_target and restaurant_id = o.restaurant_id;
  if not found then raise exception 'unknown_user' using errcode = 'P0002'; end if;
  if not p_active then
    update nohut_private.sessions set revoked_at = now() where user_id = p_target and revoked_at is null;
  end if;
  insert into nohut_private.security_audit(restaurant_id, actor_user_id, action, target_user_id)
  values (o.restaurant_id, p_actor, case when p_active then 'user_activated' else 'user_deactivated' end, p_target);
end $$;

-- "Tüm Oturumları Kapat" (and optionally all devices).
create function nohut_private.admin_revoke_sessions(p_actor uuid, p_aal text, p_target uuid, p_devices_too boolean)
returns integer language plpgsql security definer set search_path = '' as $$
declare o nohut_private.app_users; n integer;
begin
  o := nohut_private.require_owner(p_actor, p_aal);
  if not exists (select 1 from nohut_private.app_users where user_id = p_target and restaurant_id = o.restaurant_id) then
    raise exception 'unknown_user' using errcode = 'P0002';
  end if;
  update nohut_private.sessions set revoked_at = now() where user_id = p_target and revoked_at is null;
  get diagnostics n = row_count;
  if p_devices_too then
    update nohut_private.devices set revoked_at = now(), pin_verifier = null where user_id = p_target and revoked_at is null;
  end if;
  insert into nohut_private.security_audit(restaurant_id, actor_user_id, action, target_user_id, detail)
  values (o.restaurant_id, p_actor, 'sessions_revoked', p_target, jsonb_build_object('sessions', n, 'devices', p_devices_too));
  return n;
end $$;

create function nohut_private.admin_reset_pin(p_actor uuid, p_aal text, p_target uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare o nohut_private.app_users;
begin
  o := nohut_private.require_owner(p_actor, p_aal);
  update nohut_private.devices d set pin_verifier = null, pin_failed_count = 0
    from nohut_private.app_users u
   where d.user_id = u.user_id and u.user_id = p_target and u.restaurant_id = o.restaurant_id;
  insert into nohut_private.security_audit(restaurant_id, actor_user_id, action, target_user_id)
  values (o.restaurant_id, p_actor, 'pin_reset', p_target);
end $$;

-- Device enrollment happens only after a password login (API layer).
create function nohut_private.enroll_device(p_user_id uuid, p_device_id uuid, p_session_id uuid, p_client text, p_label text)
returns void language plpgsql security definer set search_path = '' as $$
declare u nohut_private.app_users;
begin
  select * into u from nohut_private.app_users where user_id = p_user_id and active;
  if not found then raise exception 'inactive' using errcode = '42501'; end if;
  insert into nohut_private.devices(device_id, user_id, client, label) values (p_device_id, p_user_id, p_client, left(coalesce(p_label, ''), 60))
  on conflict (device_id) do nothing;
  if not exists (select 1 from nohut_private.devices where device_id = p_device_id and user_id = p_user_id and revoked_at is null) then
    raise exception 'device_revoked' using errcode = '42501';
  end if;
  insert into nohut_private.sessions(session_id, user_id, device_id) values (p_session_id, p_user_id, p_device_id);
  update nohut_private.app_users set last_login_at = now() where user_id = p_user_id;
  insert into nohut_private.security_audit(restaurant_id, actor_user_id, action, detail)
  values (u.restaurant_id, p_user_id, 'login', jsonb_build_object('device', p_device_id, 'client', p_client));
end $$;

-- Six-digit PIN for a device that already holds a password session.
create function nohut_private.set_pin(p_user_id uuid, p_device_id uuid, p_session_id uuid, p_pin text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_pin !~ '^[0-9]{6}$' or p_pin in ('000000','111111','123456','654321','222222','999999') then
    raise exception 'weak_pin' using errcode = '22023';
  end if;
  if not exists (select 1 from nohut_private.sessions s join nohut_private.devices d using (device_id)
                 where s.session_id = p_session_id and s.user_id = p_user_id and s.device_id = p_device_id
                   and s.revoked_at is null and d.revoked_at is null) then
    raise exception 'session_revoked' using errcode = '42501';
  end if;
  update nohut_private.devices
     set pin_verifier = extensions.crypt(p_pin, extensions.gen_salt('bf', 10)), pin_failed_count = 0
   where device_id = p_device_id and user_id = p_user_id;
end $$;

-- 'ok' | 'wrong' | 'locked' | 'no_pin'. The 5th wrong PIN clears the
-- verifier: the user must log in with the password again.
create function nohut_private.verify_pin(p_user_id uuid, p_device_id uuid, p_pin text)
returns text language plpgsql security definer set search_path = '' as $$
declare d nohut_private.devices; u_active boolean;
begin
  select * into d from nohut_private.devices where device_id = p_device_id and user_id = p_user_id for update;
  select active into u_active from nohut_private.app_users where user_id = p_user_id;
  if not found or d.revoked_at is not null or not coalesce(u_active, false) then return 'locked'; end if;
  if d.pin_verifier is null then return 'no_pin'; end if;
  if p_pin ~ '^[0-9]{6}$' and extensions.crypt(p_pin, d.pin_verifier) = d.pin_verifier then
    update nohut_private.devices set pin_failed_count = 0, last_seen_at = now() where device_id = p_device_id;
    return 'ok';
  end if;
  if d.pin_failed_count + 1 >= 5 then
    update nohut_private.devices set pin_failed_count = 0, pin_verifier = null where device_id = p_device_id;
    return 'locked';
  end if;
  update nohut_private.devices set pin_failed_count = pin_failed_count + 1 where device_id = p_device_id;
  return 'wrong';
end $$;

revoke all on all tables in schema nohut_private from public, anon, authenticated, service_role;
revoke all on all functions in schema nohut_private from public, anon, authenticated, service_role;
-- Same posture as the PR-05A foundation: RLS enabled and FORCED, no client
-- policies. The only policy lets the migration owner (who also owns the
-- SECURITY DEFINER functions above) operate, so the functions work whether or
-- not that role has BYPASSRLS on the hosting platform.
do $$
declare t text;
begin
  foreach t in array array['operation_catalogue','app_users','user_grants','devices','sessions','security_audit'] loop
    execute format('alter table nohut_private.%I enable row level security', t);
    execute format('alter table nohut_private.%I force row level security', t);
    execute format('create policy control_plane_owner on nohut_private.%I for all to %I using (true) with check (true)', t, current_user);
  end loop;
end $$;

commit;
