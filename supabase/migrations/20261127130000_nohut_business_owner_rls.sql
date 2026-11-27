-- Trusted migration/RPC owner must work without superuser or BYPASSRLS.
-- This does not grant schema, table or function access to any client role.
begin;
do $$ declare t record; begin
  if current_user in ('anon','authenticated','service_role') then raise exception 'unsafe migration owner'; end if;
  for t in select c.oid,c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='nohut_private' and c.relkind='r'
      and not exists(select 1 from pg_policy p where p.polrelid=c.oid
        and (select oid from pg_roles where rolname=current_user)=any(p.polroles)) loop
    execute format('create policy business_rpc_owner on nohut_private.%I for all to %I using (true) with check (true)',t.relname,current_user);
  end loop;
end $$;
commit;
