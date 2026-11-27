-- Synthetic fixture only; rollback all data.
begin;
do $$
declare
  r uuid := '00000000-0000-4000-8000-000000000001';
  e uuid := '00000000-0000-4000-8000-000000000002';
  r2 uuid := '00000000-0000-4000-8000-000000000003';
  e2 uuid := '00000000-0000-4000-8000-000000000004';
  t timestamptz := clock_timestamp();
  item record;
  outcome jsonb := '{"state":"confirmed","code":"ok"}';
  other jsonb := '{"state":"rejected","code":"no"}';
begin
  insert into nohut_private.restaurants(restaurant_id) values(r),(r2);
  insert into nohut_private.authority_epochs(restaurant_id,authority_epoch) values(r,e),(r2,e2);
  insert into nohut_private.commands(restaurant_id,request_id,authority_epoch,envelope,issued_at,expires_at)
  select x.r,x.id,x.e,jsonb_build_object(
    'request_id',x.id,'restaurant_id',x.r,'authority_epoch',x.e,
    'issued_at',x.i,'expires_at',x.exp,'actor',jsonb_build_object('employee_id',1),
    'payload','{}'::jsonb,'payload_sha256',repeat('a',64),'action_type','create_order'),
    x.i,x.exp
  from (values (r,'one',e,t,t+interval '5 min'),
    (r,'expired',e,t-interval '6 min',t-interval '1 min'),
    (r,'uncertain',e,t-interval '6 min',t-interval '1 min'),
    (r2,'other',e2,t,t+interval '5 min')) x(r,id,e,i,exp);
  update nohut_private.commands set state='processing',lease_generation=1,lease_until=t-interval '1 second'
    where restaurant_id=r and request_id='uncertain';
  select * into strict item from nohut_private.claim_commands(r,e,20);
  if item.envelope->>'request_id'<>'one' or item.lease_generation<>1 then raise exception 'wrong first claim'; end if;
  if exists(select 1 from nohut_private.claim_commands(r,e,20)) then raise exception 'live lease was reclaimed'; end if;
  if (select state from nohut_private.commands where restaurant_id=r and request_id='expired')<>'expired' then raise exception 'pending expiry'; end if;
  if (select state from nohut_private.commands where restaurant_id=r and request_id='uncertain')<>'reconciliation_required' then raise exception 'uncertain processing expiry'; end if;
  update nohut_private.commands set lease_until=t-interval '1 second' where restaurant_id=r and request_id='one';
  select * into strict item from nohut_private.claim_commands(r,e,20);
  if item.lease_generation<>2 then raise exception 'lease not fenced'; end if;
  if nohut_private.complete_command(r,e,'one',1,outcome)<>'stale_claim' then raise exception 'old generation accepted'; end if;
  if nohut_private.complete_command(r,e,'one',2,outcome)<>'accepted' then raise exception 'completion failed'; end if;
  if nohut_private.complete_command(r,e,'one',2,outcome)<>'duplicate' then raise exception 'lost ack not idempotent'; end if;
  if nohut_private.complete_command(r,e,'one',2,other)<>'conflict' then raise exception 'terminal result overwritten'; end if;
  if nohut_private.complete_command(r,e,'other',1,outcome)<>'stale_claim' then raise exception 'cross restaurant completion'; end if;
  if (select state from nohut_private.commands where restaurant_id=r2 and request_id='other')<>'pending' then raise exception 'cross restaurant claim'; end if;
  update nohut_private.authority_epochs set retired_at=clock_timestamp() where restaurant_id=r and authority_epoch=e;
  begin
    perform nohut_private.claim_commands(r,e,1);
    raise exception 'retired epoch accepted';
  exception when insufficient_privilege then null;
  end;
  if exists (select 1 from unnest(array['anon','authenticated','service_role']) as roles(role_name)
    where has_table_privilege(role_name,'nohut_private.commands','SELECT')
       or has_table_privilege(role_name,'nohut_private.commands','INSERT')
       or has_function_privilege(role_name,'nohut_private.claim_commands(uuid,uuid,integer)','EXECUTE')
       or has_function_privilege(role_name,'nohut_private.complete_command(uuid,uuid,text,bigint,jsonb)','EXECUTE'))
    then raise exception 'private grants leaked'; end if;
end $$;
rollback;
