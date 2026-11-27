-- Private RLS policies only for the trusted migration/definer owner.
-- FORCE RLS remains enabled; no schema/table access to app roles.
begin;
do $$
declare t text;
begin
  if current_user in ('anon','authenticated','service_role') then
    raise exception 'unsafe migration owner';
  end if;
  foreach t in array array['restaurants','authority_epochs','sync_migrations',
    'sync_checkpoints','sync_transactions','sync_event_ids','employees',
    'employee_source_ids','commands'] loop
    execute format('create policy cloud_rpc_owner on nohut_private.%I for all to %I using (true) with check (true)',t,current_user);
  end loop;
end $$;
commit;
