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
declare r uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); tx jsonb; row1 jsonb; corrected jsonb; bad jsonb;
begin
  insert into nohut_private.restaurants(restaurant_id) values(r);
  insert into nohut_private.authority_epochs(restaurant_id,authority_epoch) values(r,e);
  insert into nohut_private.sync_migrations(restaurant_id,migration_id,authority_epoch,snapshot_revision,snapshot_seq,schema_version,manifest_sha256,status)
    values(r,gen_random_uuid(),e,0,0,1,repeat('a',64),'active');
  insert into nohut_private.sync_checkpoints(restaurant_id,authority_epoch) values(r,e);
  perform nohut_private.ingest_sync_transaction(r,e,pg_temp.employee_tx(e,1,1,'[{"id":1,"name":"Synthetic","active":true}]'));
  row1:='{"id":"sh_1","employeeId":1,"employeeName":"Synthetic","start":"2026-11-27T08:00:00Z","source":"remote","corrections":[]}';
  tx:=pg_temp.employee_tx(e,2,2,jsonb_build_array(row1),'shifts');
  if nohut_private.ingest_sync_transaction(r,e,tx)->>'status'<>'accepted' or nohut_private.ingest_sync_transaction(r,e,tx)->>'status'<>'duplicate' then raise exception 'shift ingest/retry failed'; end if;
  row1:=row1||'{"end":"2026-11-27T10:00:00Z"}'::jsonb;
  perform nohut_private.ingest_sync_transaction(r,e,pg_temp.employee_tx(e,3,3,jsonb_build_array(row1),'shifts'));
  corrected:=row1||'{"end":"2026-11-27T11:00:00Z","corrections":[{"at":"2026-11-27T12:00:00Z","byId":1,"by":"Synthetic","before":{"start":"2026-11-27T08:00:00Z","end":"2026-11-27T10:00:00Z"},"after":{"start":"2026-11-27T08:00:00Z","end":"2026-11-27T11:00:00Z"},"reason":"Synthetic correction"}]}'::jsonb;
  perform nohut_private.ingest_sync_transaction(r,e,pg_temp.employee_tx(e,4,4,jsonb_build_array(corrected),'shifts'));
  if (select count(*) from nohut_private.shift_corrections where restaurant_id=r)<>1 then raise exception 'audit lost'; end if;
  foreach bad in array array['[]'::jsonb,jsonb_build_array(row1),jsonb_build_array(jsonb_set(corrected,'{corrections,0,reason}','"changed"')),jsonb_build_array(corrected||'{"secret":"no"}')] loop
    begin perform nohut_private.ingest_sync_transaction(r,e,pg_temp.employee_tx(e,5,5,bad,'shifts')); raise exception 'invalid shift accepted'; exception when invalid_parameter_value then null; end;
  end loop;
  if (select last_acked_seq from nohut_private.sync_checkpoints where restaurant_id=r)<>4 then raise exception 'bad shift acked'; end if;
  if (select ended_at from nohut_private.shifts where restaurant_id=r) is distinct from '2026-11-27T11:00:00Z'::timestamptz then raise exception 'shift interval wrong'; end if;
end $$;
rollback;
