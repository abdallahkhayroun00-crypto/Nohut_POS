\set ON_ERROR_STOP on
begin;
insert into nohut_private.restaurants(restaurant_id) values
 ('10000000-0000-0000-0000-000000000001'),
 ('10000000-0000-0000-0000-000000000002');
insert into nohut_private.authority_epochs(restaurant_id,authority_epoch) values
 ('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001');
insert into nohut_private.pos_tables(restaurant_id,table_id,label,entity_version,source_revision,updated_at)
 values ('10000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000001','Synthetic table',1,1,now());
insert into nohut_private.orders(restaurant_id,order_id,local_order_id,channel,opened_at,business_day,status,total_kurus,entity_version,source_revision,updated_at)
 values ('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','synthetic-1','gel_al',now(),date '2026-11-27','closed',14000,1,1,now());
insert into nohut_private.payments(restaurant_id,order_id,payment_id,method,amount_kurus,recorded_at,entity_version,source_revision,updated_at)
 values ('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001','kart',14000,now(),1,1,now());
insert into nohut_private.payment_refunds(restaurant_id,order_id,payment_id,refund_id,amount_kurus,recorded_at,entity_version,source_revision,updated_at)
 values ('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-000000000001',3000,now(),1,1,now());
insert into nohut_private.sync_transactions(restaurant_id,authority_epoch,tx_id,source_revision,first_seq,last_seq,event_count,schema_version,body_sha256)
 values ('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000001',1,1,1,1,1,repeat('a',64));
insert into nohut_private.sync_event_ids(restaurant_id,authority_epoch,tx_id,event_id,event_ordinal,seq,entity_type,entity_id,op,body_sha256)
 values ('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000001','synthetic-event',0,1,'orders','synthetic-1','upsert',repeat('b',64));

do $$
declare r record; role_name text; net bigint;
begin
  for r in select c.oid,c.relname,c.relrowsecurity,c.relforcerowsecurity
    from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='nohut_private' and c.relkind='r'
  loop
    if not r.relrowsecurity or not r.relforcerowsecurity then
      raise exception 'RLS missing on %',r.relname;
    end if;
    foreach role_name in array array['anon','authenticated','service_role'] loop
      if has_schema_privilege(role_name,'nohut_private','USAGE')
        or has_table_privilege(role_name,r.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') then
        raise exception 'Unexpected client privilege: % on %',role_name,r.relname;
      end if;
    end loop;
  end loop;
  select (select sum(amount_kurus) from nohut_private.payments) -
    (select sum(amount_kurus) from nohut_private.payment_refunds) into net;
  if net is distinct from 11000 then raise exception 'Incorrect integer money total'; end if;
  begin
    update nohut_private.orders set table_id='30000000-0000-0000-0000-000000000001'
      where local_order_id='synthetic-1';
    raise exception 'Cross-restaurant reference accepted';
  exception when foreign_key_violation then null;
  end;
  begin
    insert into nohut_private.authority_epochs(restaurant_id,authority_epoch)
      values ('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002');
    raise exception 'Second active epoch accepted';
  exception when unique_violation then null;
  end;
  begin
    insert into nohut_private.sync_event_ids
      select restaurant_id,authority_epoch,tx_id,event_id,event_ordinal,seq,entity_type,entity_id,op,body_sha256
      from nohut_private.sync_event_ids;
    raise exception 'Duplicate event accepted';
  exception when unique_violation then null;
  end;
  begin
    insert into nohut_private.sync_transactions(restaurant_id,authority_epoch,tx_id,source_revision,first_seq,last_seq,event_count,schema_version,body_sha256)
      values ('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000002',2,2,4,2,1,repeat('c',64));
    raise exception 'Invalid transaction range accepted';
  exception when check_violation then null;
  end;
end $$;
set local role authenticated;
do $$
begin
  begin
    perform count(*) from nohut_private.orders;
    raise exception 'Authenticated direct read permitted';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
rollback;
select 'PASS: private schema, tenant isolation, integer money, epoch and identity constraints' as result;
