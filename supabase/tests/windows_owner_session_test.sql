-- Task A1 synthetic tests: Windows owner session + MFA, Windows-only
-- operations allowed only from an owner-enrolled 'windows' device.
\set ON_ERROR_STOP on
begin;
insert into nohut_private.restaurants(restaurant_id) values ('e0000000-0000-0000-0000-0000000000a1');
insert into nohut_private.app_users(user_id, restaurant_id, username, role_template, is_owner)
values ('a1000000-0000-0000-0000-00000000000a', 'e0000000-0000-0000-0000-0000000000a1', 'sahip_w', 'Yönetici', true),
       ('a1000000-0000-0000-0000-00000000000b', 'e0000000-0000-0000-0000-0000000000a1', 'mudur_w', 'Müdür', false);
insert into nohut_private.user_grants(user_id, operation_id) values ('a1000000-0000-0000-0000-00000000000b', 'sync.manual');

-- 1. Owner WITHOUT MFA cannot enroll a Windows device.
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-00000000000a","session_id":"a2000000-0000-0000-0000-000000000001","aal":"aal1","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  begin
    perform public.nohut_register_device('a3000000-0000-0000-0000-000000000001', 'windows', 'Kasa');
    raise exception 'owner without MFA enrolled windows';
  exception when insufficient_privilege then
    if sqlerrm <> 'windows_enrollment_requires_owner_mfa' then raise; end if;
  end;
end $$;
reset role;

-- 2. Manager (even with MFA and a sync grant) cannot enroll Windows.
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-00000000000b","session_id":"a2000000-0000-0000-0000-000000000002","aal":"aal2","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  begin
    perform public.nohut_register_device('a3000000-0000-0000-0000-000000000002', 'windows', 'Kasa');
    raise exception 'manager enrolled windows';
  exception when insufficient_privilege then null;
  end;
end $$;
-- The manager's phone cannot run sync.* even with the grant.
select public.nohut_register_device('a3000000-0000-0000-0000-000000000003', 'yonetici', 'Telefon');
do $$
declare v bigint;
begin
  v := (public.nohut_whoami('a3000000-0000-0000-0000-000000000003', 'yonetici')->>'permission_version')::bigint;
  if public.nohut_authorize('a3000000-0000-0000-0000-000000000003', 'yonetici', 'sync.manual', v) <> 'windows_only' then
    raise exception 'manager phone sync not windows_only';
  end if;
  -- Claiming client=windows with a phone device is refused.
  if public.nohut_authorize('a3000000-0000-0000-0000-000000000003', 'windows', 'sync.manual', v) <> 'device_revoked' then
    raise exception 'phone device accepted as windows';
  end if;
end $$;
reset role;

-- 3. Owner with MFA enrolls the Windows POS; Windows-only ops are ok there.
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-00000000000a","session_id":"a2000000-0000-0000-0000-000000000003","aal":"aal2","role":"authenticated"}', true);
set local role authenticated;
select public.nohut_register_device('a3000000-0000-0000-0000-00000000000a', 'windows', 'Kasa PC');
do $$
declare s jsonb; v bigint;
begin
  s := public.nohut_windows_owner_session('a3000000-0000-0000-0000-00000000000a');
  if s->>'status' <> 'ok' or s->>'aal' <> 'aal2' or (s->>'device_id')::uuid <> 'a3000000-0000-0000-0000-00000000000a'
     or (s->>'session_id')::uuid <> 'a2000000-0000-0000-0000-000000000003' then
    raise exception 'windows owner session: %', s;
  end if;
  v := (s->>'permission_version')::bigint;
  if public.nohut_authorize('a3000000-0000-0000-0000-00000000000a', 'windows', 'sync.manual', v) <> 'ok' then raise exception 'sync.manual on windows'; end if;
  if public.nohut_authorize('a3000000-0000-0000-0000-00000000000a', 'windows', 'sync.initial.start', v) <> 'ok' then raise exception 'ownerOnly on windows'; end if;
  if public.nohut_authorize('a3000000-0000-0000-0000-00000000000a', 'windows', 'backup.manual', v) <> 'ok' then raise exception 'backup on windows'; end if;
  -- Whoami for the Windows client includes the Windows-only grants.
  if not (public.nohut_whoami('a3000000-0000-0000-0000-00000000000a', 'windows')->'grants') ? 'sync.manual' then
    raise exception 'windows whoami lacks sync grants';
  end if;
end $$;
-- Owner's phone (same user) still gets windows_only.
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-00000000000a","session_id":"a2000000-0000-0000-0000-000000000004","aal":"aal2","role":"authenticated"}', true);
select public.nohut_register_device('a3000000-0000-0000-0000-00000000000b', 'yonetici', 'Sahip telefon');
do $$
declare v bigint;
begin
  v := (public.nohut_whoami('a3000000-0000-0000-0000-00000000000b', 'yonetici')->>'permission_version')::bigint;
  if public.nohut_authorize('a3000000-0000-0000-0000-00000000000b', 'yonetici', 'sync.manual', v) <> 'windows_only' then
    raise exception 'owner phone sync not windows_only';
  end if;
  if public.nohut_authorize('a3000000-0000-0000-0000-00000000000b', 'yonetici', 'backup.restore', v) not in ('windows_only', 'unknown_operation') then
    raise exception 'owner phone backup not refused';
  end if;
  -- The phone session is not a Windows owner session.
  if public.nohut_windows_owner_session('a3000000-0000-0000-0000-00000000000b')->>'status' = 'ok' then
    raise exception 'phone accepted as windows owner session';
  end if;
  -- A phone device id cannot be re-registered as windows (fresh session).
  perform set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-00000000000a","session_id":"a2000000-0000-0000-0000-000000000005","aal":"aal2","role":"authenticated"}', true);
  begin
    perform public.nohut_register_device('a3000000-0000-0000-0000-00000000000b', 'windows', 'x');
    raise exception 'phone device became windows';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- 4. Windows session without aal2 in the JWT is not an owner session.
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-00000000000a","session_id":"a2000000-0000-0000-0000-000000000003","aal":"aal1","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  if public.nohut_windows_owner_session('a3000000-0000-0000-0000-00000000000a')->>'status' <> 'mfa_required' then
    raise exception 'aal1 windows session accepted';
  end if;
end $$;
reset role;

-- 5. Revocation: revoked session, then revoked device, are denied.
update nohut_private.sessions set revoked_at = now() where session_id = 'a2000000-0000-0000-0000-000000000003';
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-00000000000a","session_id":"a2000000-0000-0000-0000-000000000003","aal":"aal2","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  if public.nohut_windows_owner_session('a3000000-0000-0000-0000-00000000000a')->>'status' <> 'session_revoked' then
    raise exception 'revoked session accepted';
  end if;
end $$;
reset role;
update nohut_private.devices set revoked_at = now() where device_id = 'a3000000-0000-0000-0000-00000000000a';
set local role authenticated;
do $$ begin
  if public.nohut_windows_owner_session('a3000000-0000-0000-0000-00000000000a')->>'status' <> 'device_revoked' then
    raise exception 'revoked device accepted';
  end if;
end $$;
reset role;

-- 6. Deactivated owner is denied.
update nohut_private.devices set revoked_at = null where device_id = 'a3000000-0000-0000-0000-00000000000a';
update nohut_private.sessions set revoked_at = null where session_id = 'a2000000-0000-0000-0000-000000000003';
update nohut_private.app_users set active = false where user_id = 'a1000000-0000-0000-0000-00000000000a';
set local role authenticated;
do $$ begin
  if public.nohut_windows_owner_session('a3000000-0000-0000-0000-00000000000a')->>'status' <> 'inactive' then
    raise exception 'inactive owner accepted';
  end if;
end $$;
reset role;

-- 7. anon cannot call it.
set local role anon;
do $$ begin
  begin
    perform public.nohut_windows_owner_session('a3000000-0000-0000-0000-00000000000a');
    raise exception 'anon called windows owner session';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
rollback;
select 'PASS: Windows owner session (MFA enrollment, windows-only ops only from Windows, revocation)' as result;
