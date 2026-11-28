-- Phase 3B synthetic tests: the public auth API takes identity ONLY from the
-- JWT claims and refuses anon. Needs the auth.uid() stand-in (CI) or Supabase.
\set ON_ERROR_STOP on
begin;
insert into nohut_private.restaurants(restaurant_id) values ('e0000000-0000-0000-0000-000000000001');
insert into nohut_private.app_users(user_id, restaurant_id, username, role_template, is_owner)
values ('f0000000-0000-0000-0000-00000000000a', 'e0000000-0000-0000-0000-000000000001', 'sahip', 'Yönetici', true);

-- Owner logs in with MFA on a tablet.
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-00000000000a","session_id":"f1000000-0000-0000-0000-00000000000a","aal":"aal2","role":"authenticated"}', true);
set local role authenticated;
select public.nohut_register_device('f2000000-0000-0000-0000-00000000000a', 'yonetici', 'Tablet');
select public.nohut_admin_create_user('f0000000-0000-0000-0000-00000000000b', 'deniz', 2, 'Personel');
do $$
declare w jsonb; users jsonb;
begin
  w := public.nohut_whoami('f2000000-0000-0000-0000-00000000000a', 'yonetici');
  if w->>'status' <> 'ok' or not (w->>'is_owner')::boolean or not (w->>'mfa')::boolean then raise exception 'owner whoami: %', w; end if;
  if (w->'grants') ? 'backup.manual' or (w->'grants') ? 'sync.manual' then raise exception 'windows-only grant shown to app: %', w; end if;
  users := public.nohut_admin_users();
  if jsonb_array_length(users) <> 2 then raise exception 'admin users: %', users; end if;
  -- Direct table access stays closed even for authenticated.
  begin
    perform count(*) from nohut_private.app_users;
    raise exception 'direct read';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- Staff logs in (aal1) on a phone; identity from JWT only.
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-00000000000b","session_id":"f1000000-0000-0000-0000-00000000000b","aal":"aal1","role":"authenticated"}', true);
set local role authenticated;
select public.nohut_register_device('f2000000-0000-0000-0000-00000000000b', 'personel', 'Telefon');
do $$
declare w jsonb; v bigint;
begin
  w := public.nohut_whoami('f2000000-0000-0000-0000-00000000000b', 'personel');
  if w->>'status' <> 'ok' or (w->>'is_owner')::boolean or (w->>'mfa')::boolean then raise exception 'staff whoami: %', w; end if;
  if not (w->'grants') ? 'orders.create' or (w->'grants') ? 'finance.view' then raise exception 'staff grants: %', w; end if;
  v := (w->>'permission_version')::bigint;
  if public.nohut_authorize('f2000000-0000-0000-0000-00000000000b', 'personel', 'orders.create', v) <> 'ok' then raise exception 'authorize'; end if;
  -- Staff cannot administer.
  begin
    perform public.nohut_admin_set_grant('f0000000-0000-0000-0000-00000000000b', 'payments.refund', true);
    raise exception 'staff administered';
  exception when insufficient_privilege then null;
  end;
  -- Another user's device id does not work with this JWT.
  if public.nohut_whoami('f2000000-0000-0000-0000-00000000000a', 'yonetici')->>'status' <> 'device_revoked' then
    raise exception 'foreign device accepted';
  end if;
  -- Setting a PIN needs a recent password sign-in (JWT amr), like Windows (QA-17).
  begin
    perform public.nohut_set_pin('f2000000-0000-0000-0000-00000000000b', '58291');
    raise exception 'first PIN set without a recent password sign-in';
  exception when insufficient_privilege then null;
  end;
  perform set_config('request.jwt.claims', jsonb_build_object('sub','f0000000-0000-0000-0000-00000000000b',
    'session_id','f1000000-0000-0000-0000-00000000000b','aal','aal1','role','authenticated',
    'amr', jsonb_build_array(jsonb_build_object('method','password','timestamp', extract(epoch from now())::bigint - 10)))::text, true);
  perform public.nohut_set_pin('f2000000-0000-0000-0000-00000000000b', '58291');
  if public.nohut_verify_pin('f2000000-0000-0000-0000-00000000000b', '58291') <> 'ok' then raise exception 'pin'; end if;
  perform set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-00000000000b","session_id":"f1000000-0000-0000-0000-00000000000b","aal":"aal1","role":"authenticated"}', true);
  -- Replacing it later needs a recent password sign-in too.
  begin
    perform public.nohut_set_pin('f2000000-0000-0000-0000-00000000000b', '47302');
    raise exception 'PIN replaced without a recent password sign-in';
  exception when insufficient_privilege then null;
  end;
  perform set_config('request.jwt.claims', jsonb_build_object('sub','f0000000-0000-0000-0000-00000000000b',
    'session_id','f1000000-0000-0000-0000-00000000000b','aal','aal1','role','authenticated',
    'amr', jsonb_build_array(jsonb_build_object('method','password','timestamp', extract(epoch from now())::bigint - 3600)))::text, true);
  begin
    perform public.nohut_set_pin('f2000000-0000-0000-0000-00000000000b', '47302');
    raise exception 'PIN replaced with an hour-old sign-in';
  exception when insufficient_privilege then null;
  end;
  perform set_config('request.jwt.claims', jsonb_build_object('sub','f0000000-0000-0000-0000-00000000000b',
    'session_id','f1000000-0000-0000-0000-00000000000b','aal','aal1','role','authenticated',
    'amr', jsonb_build_array(jsonb_build_object('method','password','timestamp', extract(epoch from now())::bigint - 30)))::text, true);
  perform public.nohut_set_pin('f2000000-0000-0000-0000-00000000000b', '47302');
  if public.nohut_verify_pin('f2000000-0000-0000-0000-00000000000b', '47302') <> 'ok' then raise exception 'pin change'; end if;
  perform public.nohut_logout('f2000000-0000-0000-0000-00000000000b');
  if public.nohut_whoami('f2000000-0000-0000-0000-00000000000b', 'personel')->>'status' <> 'session_revoked' then raise exception 'logout'; end if;
end $$;
reset role;

-- Owner WITHOUT MFA cannot administer.
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-00000000000a","session_id":"f1000000-0000-0000-0000-00000000000a","aal":"aal1","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin
    perform public.nohut_admin_users();
    raise exception 'owner without MFA administered';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- anon cannot call anything.
set local role anon;
do $$
begin
  begin
    perform public.nohut_whoami('f2000000-0000-0000-0000-00000000000a', 'yonetici');
    raise exception 'anon called the API';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
rollback;
select 'PASS: auth API (JWT identity only, MFA for admin, anon refused, logout, PIN)' as result;
