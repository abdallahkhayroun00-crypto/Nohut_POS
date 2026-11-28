-- QA-19: recent_password_auth reads now(), so it is STABLE, not IMMUTABLE
-- (an immutable function may be constant-folded and cache a stale answer).
-- Same body as 20261127211000; only the volatility changes.
begin;

create or replace function nohut_private.recent_password_auth(p_claims jsonb, p_max_age_seconds integer)
returns boolean language sql stable set search_path = '' as $$
  select coalesce((
    select max((a->>'timestamp')::bigint)
      from jsonb_array_elements(case when jsonb_typeof(p_claims->'amr') = 'array' then p_claims->'amr' else '[]'::jsonb end) a
     where a->>'method' = 'password' and a->>'timestamp' ~ '^[0-9]{1,12}$'
  ) >= extract(epoch from now())::bigint - p_max_age_seconds, false)
$$;
revoke all on function nohut_private.recent_password_auth(jsonb, integer) from public, anon, authenticated, service_role;

commit;
