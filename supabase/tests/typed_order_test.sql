\set ON_ERROR_STOP on
begin;
create function pg_temp.order_tx(epoch uuid,rev bigint,seq bigint,body jsonb,kind text default 'typed_order')
returns jsonb language sql as $$
with h as (select replace(epoch::text,'-','') e,body::text b,encode(sha256(convert_to(body::text,'UTF8')),'hex') bh),
t as (select *,encode(sha256(convert_to('nohut-tx:'||e||':'||rev,'UTF8')),'hex') th from h)
select jsonb_build_object('authority_epoch',e,'schema_version',1,'source_revision',rev,'first_seq',seq,'last_seq',seq,'event_count',1,
 'tx_id',substr(th,1,8)||'-'||substr(th,9,4)||'-5'||substr(th,14,3)||'-a'||substr(th,18,3)||'-'||substr(th,21,12),
 'body_sha256',encode(sha256(convert_to(bh,'UTF8')),'hex'),'events',jsonb_build_array(jsonb_build_object(
 'event_ordinal',0,'seq',seq,'event_id',e||':'||rev||':'||kind||':1','entity_type',kind,'entity_id','1',
 'op','upsert','payload_json',b,'payload',body,'body_sha256',bh))) from t
$$;
do $$
declare r uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); oid uuid:=gen_random_uuid(); bid uuid:=gen_random_uuid();
  iid uuid:=gen_random_uuid(); pid uuid:=gen_random_uuid(); vid uuid:=gen_random_uuid(); pay uuid:=gen_random_uuid();
  definition jsonb; p jsonb; bad jsonb; refund jsonb; tx jsonb; before_history bigint; t text;
begin
  insert into nohut_private.restaurants(restaurant_id) values(r);
  insert into nohut_private.authority_epochs(restaurant_id,authority_epoch) values(r,e);
  insert into nohut_private.sync_migrations(restaurant_id,migration_id,authority_epoch,snapshot_revision,snapshot_seq,schema_version,manifest_sha256,status)
    values(r,gen_random_uuid(),e,0,0,1,repeat('a',64),'active');
  insert into nohut_private.sync_checkpoints(restaurant_id,authority_epoch) values(r,e);
  definition:='{"label_tr":"Synthetic item","price_kurus":1234,"active":true,"available":true,"internal_only":true}';
  p:=jsonb_build_object('source_updated_at','2026-11-27T12:00:00Z','order_id',oid,'local_order_id','1',
    'counts','{"orders":1,"order_batches":1,"order_items":1,"payments":1,"payment_refunds":0,"guest_checks":0,"guest_allocations":0,"payment_guest_allocations":0,"order_events":0,"order_line_edits":0,"order_voids":0,"deleted_order_audit":0}'::jsonb,
    'rows',jsonb_build_array(
      jsonb_build_object('table','orders','data',jsonb_build_object('order_id',oid,'local_order_id','1','channel','gel_al',
        'opened_at','2026-11-26T22:30:00Z','business_day','2026-11-27','status','open','total_kurus',2468,'paid_kurus',1000,'due_kurus',1468,
        'cancelled',false,'table_released',false)),
      jsonb_build_object('table','products','data',jsonb_build_object('product_id',pid,'source_kind','historical_sale','source_item_id',iid,'current_version_id',vid)),
      jsonb_build_object('table','product_versions','data',definition||jsonb_build_object('product_id',pid,'product_version_id',vid,
        'content_sha256',nohut_private.command_envelope_sha256(definition))),
      jsonb_build_object('table','order_batches','data',jsonb_build_object('order_id',oid,'batch_id',bid,'local_batch_id',1,'employee_local_id',null,'created_at','2026-11-26T22:30:00Z')),
      jsonb_build_object('table','order_items','data',jsonb_build_object('order_id',oid,'batch_id',bid,'item_id',iid,'product_id',pid,'product_version_id',vid,
        'sale_label','Synthetic item','original_qty',2,'qty',2,'unit_price_kurus',1234,'voided',false,'correction',false,
        'customizations','{"removed":["Soğan"],"note":"Synthetic","base_price_kurus":1234,"adjustment_kurus":0,"custom_item":true,"campaign_source_id":null,"components":[]}'::jsonb)),
      jsonb_build_object('table','payments','data',jsonb_build_object('order_id',oid,'payment_id',pay,'method','nakit','amount_kurus',1000,
        'employee_local_id',null,'recorded_at','2026-11-27T12:00:00Z','reversed',false,'net_kurus',1000))));
  tx:=pg_temp.order_tx(e,1,1,p);
  if nohut_private.ingest_sync_transaction(r,e,tx)->>'status'<>'accepted' then raise exception 'order not accepted'; end if;
  set constraints all immediate; set constraints all deferred;
  if nohut_private.ingest_sync_transaction(r,e,tx)->>'status'<>'duplicate' then raise exception 'order ACK recovery failed'; end if;
  foreach bad in array array[
    jsonb_set(p,'{rows,0,data,paid_kurus}','999'),
    jsonb_set(p,'{rows,0,data,business_day}','"2026-11-26"'),
    jsonb_set(p,'{rows,5,data,employee_local_id}','999'),
    jsonb_set(p,'{rows,5,data,amount_kurus}','1000.5'),
    jsonb_set(p,'{rows,5,data,amount_kurus}','"1000"'),
    jsonb_set(p,'{rows,5,data,restaurant_id}',to_jsonb(gen_random_uuid())),
    jsonb_set(p,'{rows,4,data,customizations,customer_phone}','"synthetic"'),
    jsonb_set(p,'{rows,4,data,order_id}',to_jsonb(gen_random_uuid())),
    jsonb_set(p,'{rows,4,data,qty}','1'),
    jsonb_set(p,'{counts,order_items}','0'),
    jsonb_set(p,'{rows}',(p->'rows')-4)
  ] loop
    begin perform nohut_private.ingest_sync_transaction(r,e,pg_temp.order_tx(e,2,2,bad)); raise exception 'invalid order accepted';
      exception when invalid_parameter_value then null; end;
  end loop;
  begin perform nohut_private.ingest_sync_transaction(r,e,pg_temp.order_tx(e,2,2,'{"local_order_id":"1","archive_required":true}','order_archive_marker'));
    raise exception 'bare deletion acknowledged'; exception when invalid_parameter_value then null; end;
  if (select last_acked_seq from nohut_private.sync_checkpoints where restaurant_id=r)<>1
    or (select count(*) from nohut_private.sync_transactions where restaurant_id=r)<>1 then raise exception 'partial invalid order acknowledged'; end if;
  refund:=jsonb_build_object('table','payment_refunds','data',jsonb_build_object('order_id',oid,'payment_id',pay,'refund_id',gen_random_uuid(),
    'amount_kurus',100,'recorded_at','2026-11-27T12:01:00Z'));
  p:=jsonb_set(jsonb_set(jsonb_set(jsonb_set(p,'{rows,0,data,paid_kurus}','900'),'{rows,0,data,due_kurus}','1568'),'{rows,5,data,net_kurus}','900'),'{counts,payment_refunds}','1');
  p:=jsonb_set(p,'{rows}',p->'rows'||jsonb_build_array(refund));
  perform nohut_private.ingest_sync_transaction(r,e,pg_temp.order_tx(e,2,2,p));
  before_history:=(select count(*) from nohut_private.typed_record_history where restaurant_id=r);
  bad:=jsonb_set(p,'{rows,6,data,reason}','"Rewritten refund"');
  begin perform nohut_private.ingest_sync_transaction(r,e,pg_temp.order_tx(e,3,3,bad)); raise exception 'refund history overwritten';
    exception when invalid_parameter_value then null; end;
  if (select sum(amount_kurus) from nohut_private.payment_refunds where restaurant_id=r)<>100
    or (select count(*) from nohut_private.typed_record_history where restaurant_id=r)<>before_history then raise exception 'financial history changed'; end if;
  foreach t in array array['guest_checks','guest_allocations','payment_guest_allocations','order_events','order_line_edits','order_voids','deleted_order_audit'] loop
    if has_table_privilege('authenticated','nohut_private.'||t,'select,insert,update,delete')
      or has_table_privilege('anon','nohut_private.'||t,'select,insert,update,delete')
      or has_table_privilege('service_role','nohut_private.'||t,'select,insert,update,delete') then raise exception 'order table grant leaked'; end if;
  end loop;
end $$;
rollback;
