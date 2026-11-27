-- Setting or replacing a trusted-device PIN needs a recent password sign-in
-- (same rule as Windows LocalAuth.setPin, QA-17): an unlocked phone left on a
-- table must not let someone else set or change its PIN. Supabase stamps each sign-in
-- method in the JWT `amr` claim ([{"method":"password","timestamp":…}]);
-- the app signs in with the password again before calling this.
-- The PIN step right after sign-in passes naturally. Additive: replaces the
-- public wrapper in place; grants are kept by `create or replace`.
begin;

create or replace function nohut_private.recent_password_auth(p_claims jsonb, p_max_age_seconds integer)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce((
    select max((a->>'timestamp')::bigint)
      from jsonb_array_elements(case when jsonb_typeof(p_claims->'amr') = 'array' then p_claims->'amr' else '[]'::jsonb end) a
     where a->>'method' = 'password' and a->>'timestamp' ~ '^[0-9]{1,12}$'
  ) >= extract(epoch from now())::bigint - p_max_age_seconds, false)
$$;
revoke all on function nohut_private.recent_password_auth(jsonb, integer) from public, anon, authenticated, service_role;

create or replace function public.nohut_set_pin(p_device_id uuid, p_pin text)
returns void language plpgsql security definer set search_path = '' as $$
declare claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
begin
  if not nohut_private.recent_password_auth(claims, 300) then
    raise exception 'password_required' using errcode = '42501';
  end if;
  perform nohut_private.set_pin(auth.uid(), p_device_id, public.nohut_jwt_claim('session_id')::uuid, p_pin);
end $$;

commit;
