\set ON_ERROR_STOP on
begin;
create function pg_temp.employee_tx(epoch uuid,rev bigint,seq bigint,body jsonb,kind text default 'employees')
returns jsonb language sql as $$
with h as (select replace(epoch::text,'-','') e,body::text b,
 encode(sha256(convert_to(body::text,'UTF8')),'hex') bh),
 t as (select *,encode(sha256(convert_to('nohut-tx:'||e||':'||rev,'UTF8')),'hex') th from h)
select jsonb_build_object('authority_epoch',e,'schema_version',1,'source_revision',rev,
 'first_seq',seq,'last_seq',seq,'event_count',1,
 'tx_id',substr(th,1,8)||'-'||substr(th,9,4)||'-5'||substr(th,14,3)||'-a'||substr(th,18,3)||'-'||substr(th,21,12),
 'body_sha256',encode(sha256(convert_to(bh,'UTF8')),'hex'),
 'events',jsonb_build_array(jsonb_build_object('event_ordinal',0,'seq',seq,'event_id',e||':'||rev||':'||kind||':core',
 'entity_type',kind,'entity_id','core','op','upsert','payload_json',b,'payload',body,'body_sha256',bh))) from t
$$;
do $$
declare r uuid:='10000000-0000-4000-8000-000000000001'; e uuid:='20000000-0000-4000-8000-000000000001';
  m uuid:='30000000-0000-4000-8000-000000000001'; eid uuid; tx jsonb; res jsonb; bad jsonb;
begin
  insert into nohut_private.restaurants(restaurant_id) values(r);
  insert into nohut_private.authority_epochs(restaurant_id,authority_epoch) values(r,e);
  insert into nohut_private.sync_migrations(restaurant_id,migration_id,authority_epoch,snapshot_revision,snapshot_seq,schema_version,manifest_sha256,status)
    values(r,m,e,0,0,1,repeat('a',64),'active');
  insert into nohut_private.sync_checkpoints(restaurant_id,authority_epoch) values(r,e);
  tx:=pg_temp.employee_tx(e,1,1,'[{"id":1,"name":"Synthetic","active":true,"role":"staff"}]');
  res:=nohut_private.ingest_sync_transaction(r,e,tx);
  if res->>'status'<>'accepted' or res->>'acked_through_seq'<>'1' then raise exception 'no ACK'; end if;
  select employee_id into strict eid from nohut_private.employees where restaurant_id=r;
  if nohut_private.ingest_sync_transaction(r,e,tx)->>'status'<>'duplicate' then raise exception 'lost ACK not idempotent'; end if;
  if nohut_private.ingest_sync_transaction(r,e,pg_temp.employee_tx(e,1,1,'[]'))->>'status'<>'conflict' then raise exception 'changed body accepted'; end if;
  if nohut_private.ingest_sync_transaction(r,e,pg_temp.employee_tx(e,3,3,'[]'))->>'status'<>'gap' then raise exception 'gap accepted'; end if;
  foreach bad in array array[
    pg_temp.employee_tx(e,2,2,'[{"id":2,"name":"New","active":true},{"id":2,"name":"Duplicate","active":true}]'),
    pg_temp.employee_tx(e,2,2,'[{"id":1,"name":"Synthetic","active":true,"secret":"forbidden"}]'),
    pg_temp.employee_tx(e,2,2,'[]','orders')
  ] loop
    begin
      perform nohut_private.ingest_sync_transaction(r,e,bad);
      raise exception 'invalid group accepted';
    exception when invalid_parameter_value then null;
    end;
  end loop;
  if (select count(*) from nohut_private.employees where restaurant_id=r)<>1
    or (select count(*) from nohut_private.sync_transactions where restaurant_id=r)<>1
    or (select last_acked_seq from nohut_private.sync_checkpoints where restaurant_id=r)<>1 then
    raise exception 'partial transaction persisted';
  end if;
  if nohut_private.ingest_sync_transaction(r,e,pg_temp.employee_tx(e,2,2,'[]'))->>'status'<>'accepted' then raise exception 'delete projection failed'; end if;
  if not exists(select 1 from nohut_private.employees where restaurant_id=r and employee_id=eid and deleted_at is not null and not active) then raise exception 'tombstone missing'; end if;
  if nohut_private.ingest_sync_transaction(r,e,pg_temp.employee_tx(e,3,3,'[{"id":1,"name":"Renamed","active":true}]'))->>'status'<>'accepted' then raise exception 'restore failed'; end if;
  if not exists(select 1 from nohut_private.employees where restaurant_id=r and employee_id=eid and deleted_at is null and display_name='Renamed') then raise exception 'stable identity lost'; end if;
  if has_function_privilege('authenticated','nohut_private.ingest_sync_transaction(uuid,uuid,jsonb)','EXECUTE') then raise exception 'client grant leaked'; end if;
end $$;
rollback;
