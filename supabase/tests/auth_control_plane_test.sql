-- Phase 3A synthetic tests (no live Supabase, no real people).
\set ON_ERROR_STOP on
begin;
insert into nohut_private.restaurants(restaurant_id) values
 ('a0000000-0000-0000-0000-000000000001'),
 ('a0000000-0000-0000-0000-000000000002');

-- Bootstrap: the owner row is created by the migration runner / setup
-- wizard (not by any client function).
insert into nohut_private.app_users(user_id, restaurant_id, username, role_template, is_owner)
values ('b0000000-0000-0000-0000-00000000000a', 'a0000000-0000-0000-0000-000000000001', 'sahip', 'Yönetici', true);
-- A user of ANOTHER restaurant.
insert into nohut_private.app_users(user_id, restaurant_id, username, role_template, is_owner)
values ('b0000000-0000-0000-0000-00000000000f', 'a0000000-0000-0000-0000-000000000002', 'baska', 'Yönetici', true);

do $$
declare
  owner uuid := 'b0000000-0000-0000-0000-00000000000a';
  staff uuid := 'b0000000-0000-0000-0000-00000000000b';
  mgr   uuid := 'b0000000-0000-0000-0000-00000000000c';
  other uuid := 'b0000000-0000-0000-0000-00000000000f';
  dev   uuid := 'c0000000-0000-0000-0000-00000000000b';
  sess  uuid := 'd0000000-0000-0000-0000-00000000000b';
  odev  uuid := 'c0000000-0000-0000-0000-00000000000a';
  osess uuid := 'd0000000-0000-0000-0000-00000000000a';
  v bigint;
  r text;
  actor jsonb;
  ok boolean;
begin
  -- Owner administration requires MFA (aal2).
  begin
    perform nohut_private.admin_create_user(owner, 'aal1', staff, 'deniz', 2, 'Personel');
    raise exception 'admin without MFA accepted';
  exception when insufficient_privilege then null;
  end;
  perform nohut_private.admin_create_user(owner, 'aal2', staff, 'Deniz', 2, 'Personel');
  perform nohut_private.admin_create_user(owner, 'aal2', mgr, 'ece', 1, 'Müdür');

  -- Non-owners cannot administer, even a manager with MFA.
  begin
    perform nohut_private.admin_create_user(mgr, 'aal2', gen_random_uuid(), 'yeni', 7, 'Personel');
    raise exception 'non-owner administered';
  exception when insufficient_privilege then null;
  end;
  -- Another restaurant's owner creates users only in their own restaurant.
  perform nohut_private.admin_create_user(other, 'aal2', 'b0000000-0000-0000-0000-0000000000f1', 'deniz', 2, 'Personel');
  if (select restaurant_id from nohut_private.app_users where user_id = 'b0000000-0000-0000-0000-0000000000f1')
     <> 'a0000000-0000-0000-0000-000000000002' then raise exception 'user created in a foreign restaurant'; end if;

  -- Username normalised; role template seeded grants, never owner-only or Windows-only.
  if (select username from nohut_private.app_users where user_id = staff) <> 'deniz' then raise exception 'username not normalised'; end if;
  if not exists (select 1 from nohut_private.user_grants where user_id = staff and operation_id = 'orders.create') then
    raise exception 'role template not applied';
  end if;
  if exists (select 1 from nohut_private.user_grants g join nohut_private.operation_catalogue c using (operation_id)
             where c.sensitivity = 'ownerOnly' or c.clients = array['windows']::text[]) then
    raise exception 'owner-only or windows-only operation granted by template';
  end if;
  if exists (select 1 from nohut_private.user_grants where user_id = staff and operation_id = 'finance.view') then
    raise exception 'Personel template got finance';
  end if;

  -- Login on a device (after a password login in the API layer).
  perform nohut_private.enroll_device(staff, dev, sess, 'personel', 'Synthetic phone');
  perform nohut_private.enroll_device(owner, odev, osess, 'yonetici', 'Synthetic tablet');
  select permission_version into v from nohut_private.app_users where user_id = staff;

  r := nohut_private.authorize(staff, sess, dev, 'personel', 'orders.create', v);
  if r <> 'ok' then raise exception 'staff order refused: %', r; end if;
  r := nohut_private.authorize(staff, sess, dev, 'personel', 'payments.refund', v);
  if r <> 'forbidden' then raise exception 'refund without grant: %', r; end if;
  r := nohut_private.authorize(staff, sess, dev, 'personel', 'finance.view', v);
  if r <> 'client_not_allowed' then raise exception 'manager op from Personel app: %', r; end if;
  r := nohut_private.authorize(staff, sess, dev, 'personel', 'orders.delete_everything', v);
  if r <> 'unknown_operation' then raise exception 'unknown op: %', r; end if;
  r := nohut_private.authorize(staff, sess, dev, 'yonetici', 'orders.create', v);
  if r <> 'device_revoked' then raise exception 'device used from another app: %', r; end if;
  r := nohut_private.authorize(staff, gen_random_uuid(), dev, 'personel', 'orders.create', v);
  if r <> 'session_revoked' then raise exception 'unknown session: %', r; end if;

  -- Windows-only: refused for the owner too (§22.3).
  select permission_version into v from nohut_private.app_users where user_id = owner;
  foreach r in array array['sync.manual','sync.initial.start','backup.manual','backup.restore'] loop
    if nohut_private.authorize(owner, osess, odev, 'yonetici', r, v) <> 'windows_only' then
      raise exception 'windows-only % allowed remotely', r;
    end if;
  end loop;
  -- Owner-only: owner yes; manager no even with a forged grant row.
  if nohut_private.authorize(owner, osess, odev, 'yonetici', 'users.manage', v) <> 'ok' then raise exception 'owner refused'; end if;
  insert into nohut_private.user_grants(user_id, operation_id) values (mgr, 'users.manage');
  perform nohut_private.enroll_device(mgr, 'c0000000-0000-0000-0000-00000000000c', 'd0000000-0000-0000-0000-00000000000c', 'yonetici', '');
  if nohut_private.authorize(mgr, 'd0000000-0000-0000-0000-00000000000c', 'c0000000-0000-0000-0000-00000000000c', 'yonetici', 'users.manage',
       (select permission_version from nohut_private.app_users where user_id = mgr)) <> 'forbidden' then
    raise exception 'owner-only operation honoured a stored grant';
  end if;

  -- Grants cannot be given for owner-only or Windows-only operations.
  begin
    perform nohut_private.admin_set_grant(owner, 'aal2', mgr, 'users.manage', true);
    raise exception 'owner-only delegated';
  exception when insufficient_privilege then null;
  end;
  begin
    perform nohut_private.admin_set_grant(owner, 'aal2', mgr, 'backup.manual', true);
    raise exception 'windows-only delegated';
  exception when insufficient_privilege then null;
  end;

  -- Grant change: takes effect, bumps the version, old version is stale.
  select permission_version into v from nohut_private.app_users where user_id = staff;
  if nohut_private.admin_set_grant(owner, 'aal2', staff, 'payments.refund', true) <> v + 1 then raise exception 'version not bumped'; end if;
  if nohut_private.authorize(staff, sess, dev, 'personel', 'payments.refund', v) <> 'stale_permissions' then raise exception 'stale version accepted'; end if;
  if nohut_private.authorize(staff, sess, dev, 'personel', 'payments.refund', v + 1) <> 'ok' then raise exception 'new grant ignored'; end if;
  perform nohut_private.admin_set_grant(owner, 'aal2', staff, 'payments.refund', false);
  if nohut_private.authorize(staff, sess, dev, 'personel', 'payments.refund', v + 2) <> 'forbidden' then raise exception 'revoked grant still works'; end if;

  -- Envelope actor for the Windows worker.
  actor := nohut_private.command_actor(staff);
  if (actor->>'employee_id')::int <> 2 or (actor->>'is_owner')::boolean or not (actor->'grants') ? 'orders.create'
     or (actor->'grants') ? 'payments.refund' or (actor->>'permission_version')::bigint <> v + 2 then
    raise exception 'bad actor: %', actor;
  end if;

  -- PIN: weak refused, verify, 5 wrong → locked and cleared.
  begin
    perform nohut_private.set_pin(staff, dev, sess, '123456');
    raise exception 'weak pin accepted';
  exception when invalid_parameter_value then null;
  end;
  perform nohut_private.set_pin(staff, dev, sess, '480317');
  if (select pin_verifier from nohut_private.devices where device_id = dev) like '%480317%' then raise exception 'plain pin stored'; end if;
  if nohut_private.verify_pin(staff, dev, '480317') <> 'ok' then raise exception 'pin rejected'; end if;
  for i in 1..4 loop
    if nohut_private.verify_pin(staff, dev, '000001') <> 'wrong' then raise exception 'wrong pin not counted'; end if;
  end loop;
  if nohut_private.verify_pin(staff, dev, '000001') <> 'locked' then raise exception 'no lock after 5'; end if;
  if nohut_private.verify_pin(staff, dev, '480317') <> 'no_pin' then raise exception 'pin still usable after lock'; end if;

  -- Revoke all sessions: immediate refusal.
  perform nohut_private.admin_revoke_sessions(owner, 'aal2', staff, false);
  select permission_version into v from nohut_private.app_users where user_id = staff;
  if nohut_private.authorize(staff, sess, dev, 'personel', 'orders.create', v) <> 'session_revoked' then raise exception 'revoked session works'; end if;

  -- Deactivation: refused everywhere, actor gone, owner cannot deactivate self.
  perform nohut_private.admin_set_active(owner, 'aal2', mgr, false);
  if nohut_private.authorize(mgr, 'd0000000-0000-0000-0000-00000000000c', 'c0000000-0000-0000-0000-00000000000c', 'yonetici', 'orders.create',
       (select permission_version from nohut_private.app_users where user_id = mgr)) <> 'inactive' then raise exception 'inactive user allowed'; end if;
  if nohut_private.command_actor(mgr) is not null then raise exception 'inactive actor built'; end if;
  begin
    perform nohut_private.admin_set_active(owner, 'aal2', owner, false);
    raise exception 'owner deactivated self';
  exception when insufficient_privilege then null;
  end;

  -- Cross-restaurant administration refused.
  begin
    perform nohut_private.admin_set_grant(owner, 'aal2', other, 'orders.create', true);
    raise exception 'cross-restaurant grant accepted';
  exception when no_data_found then null;
  end;

  -- Audit: entries exist, never credentials.
  if (select count(*) from nohut_private.security_audit) < 8 then raise exception 'audit missing'; end if;
  begin
    insert into nohut_private.security_audit(restaurant_id, action, detail) values ('a0000000-0000-0000-0000-000000000001', 'x', '{"pin":"1"}');
    raise exception 'credential in audit accepted';
  exception when check_violation then null;
  end;

  -- No client role can touch tables or call functions.
  foreach r in array array['anon','authenticated','service_role'] loop
    if has_table_privilege(r, 'nohut_private.app_users', 'SELECT') or has_function_privilege(r, 'nohut_private.authorize(uuid,uuid,uuid,text,text,bigint)', 'EXECUTE')
       or has_function_privilege(r, 'nohut_private.admin_set_grant(uuid,text,uuid,text,boolean)', 'EXECUTE') then
      raise exception 'client privilege for %', r;
    end if;
  end loop;
end $$;

set local role authenticated;
do $$
begin
  begin
    perform nohut_private.authorize(null, null, null, 'personel', 'orders.create', 1);
    raise exception 'authenticated called authorize directly';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
rollback;
select 'PASS: auth control plane (grants, owner-only, windows-only, versions, sessions, PIN, audit, isolation)' as result;
