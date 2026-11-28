-- Trusted-device PIN: 5 digits (spec §24.1, independent review QA-03).
-- Same rules as Windows LocalAuth._checkPin: no repeated digit, no
-- ascending/descending run, no common pattern. A verifier set under the old
-- 6-digit rule keeps working until the user sets a new PIN.
-- Additive: replaces two functions in place; grants and RLS are unchanged.

create or replace function nohut_private.set_pin(p_user_id uuid, p_device_id uuid, p_session_id uuid, p_pin text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_pin is null or p_pin !~ '^[0-9]{5}$'
     or p_pin ~ '^(.)\1{4}$'
     or position(p_pin in '0123456789') > 0
     or position(p_pin in '9876543210') > 0
     or p_pin in ('12121','10101','11211','12321','69696','13579','24680') then
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

-- 'ok' | 'wrong' | 'locked' | 'no_pin'. Accepts 5 digits, and 6 digits for
-- verifiers set before this migration. The 5th wrong PIN clears the verifier.
create or replace function nohut_private.verify_pin(p_user_id uuid, p_device_id uuid, p_pin text)
returns text language plpgsql security definer set search_path = '' as $$
declare d nohut_private.devices; u_active boolean;
begin
  select * into d from nohut_private.devices where device_id = p_device_id and user_id = p_user_id for update;
  select active into u_active from nohut_private.app_users where user_id = p_user_id;
  if not found or d.revoked_at is not null or not coalesce(u_active, false) then return 'locked'; end if;
  if d.pin_verifier is null then return 'no_pin'; end if;
  if p_pin ~ '^[0-9]{5,6}$' and extensions.crypt(p_pin, d.pin_verifier) = d.pin_verifier then
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

revoke all on function nohut_private.set_pin(uuid, uuid, uuid, text) from public, anon, authenticated, service_role;
revoke all on function nohut_private.verify_pin(uuid, uuid, text) from public, anon, authenticated, service_role;
