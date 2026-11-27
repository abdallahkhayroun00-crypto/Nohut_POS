-- CI-ONLY stand-in for the auth schema that Supabase provides in production.
-- Never applied to a Supabase project (it already has auth.uid()).
create schema if not exists auth;
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid
$$;
grant usage on schema auth to authenticated, anon;
grant execute on function auth.uid() to authenticated, anon;
