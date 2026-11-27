\set ON_ERROR_STOP on
begin;
do $$
declare r uuid:=gen_random_uuid(); oid uuid:=gen_random_uuid(); jid uuid:=gen_random_uuid(); sid uuid:=gen_random_uuid();
  definition jsonb; p jsonb; bad jsonb; next_event jsonb; t text;
begin
  insert into nohut_private.restaurants(restaurant_id) values(r);
  insert into nohut_private.orders(restaurant_id,order_id,local_order_id,channel,opened_at,business_day,status,entity_version,source_revision,updated_at)
    values(r,oid,'1','gel_al','2026-11-27T12:00:00Z','2026-11-27','open',1,0,'2026-11-27T12:00:00Z');
  definition:=jsonb_build_object('schema_version',1,'receipt_kind','payment','source_format','payment_text',
    'body',repeat('Synthetic long frozen receipt line ',60),'privacy','customer_contact_redacted');
  p:=jsonb_build_object('source_updated_at','2026-11-27T12:00:00Z','order_id',oid,'local_order_id','1','job_id',jid,
    'source_key','1:-1:paymentReceipt','event_count',1,'rows',jsonb_build_array(
      jsonb_build_object('table','receipt_snapshots','data',definition||jsonb_build_object('order_id',oid,'snapshot_id',sid,
        'content_sha256',nohut_private.command_envelope_sha256(definition))),
      jsonb_build_object('table','print_jobs','data',jsonb_build_object('order_id',oid,'job_id',jid,'snapshot_id',sid,
        'source_key','1:-1:paymentReceipt','batch_local_id',-1,'local_kind','paymentReceipt','receipt_kind','payment','status','queued','attempts',0,
        'created_at','2026-11-27T12:00:00Z','spooled_at',null)),
      jsonb_build_object('table','print_job_events','data',jsonb_build_object('order_id',oid,'job_id',jid,'event_id',gen_random_uuid(),
        'ordinal',0,'observed_at','2026-11-27T12:00:00Z','origin','created','status','queued','attempts',0,'spooled_at',null))));
  perform nohut_private.apply_typed_print(r,1,'1:-1:paymentReceipt',p);
  next_event:=jsonb_build_object('table','print_job_events','data',jsonb_build_object('order_id',oid,'job_id',jid,'event_id',gen_random_uuid(),
    'ordinal',1,'observed_at','2026-11-27T12:01:00Z','origin','transition','status','dispatching','attempts',1,'spooled_at',null));
  p:=jsonb_set(jsonb_set(jsonb_set(p,'{rows,1,data,status}','"dispatching"'),'{rows,1,data,attempts}','1'),'{event_count}','2');
  p:=jsonb_set(p,'{rows}',p->'rows'||jsonb_build_array(next_event));
  perform nohut_private.apply_typed_print(r,2,'1:-1:paymentReceipt',p);
  foreach bad in array array[
    jsonb_set(p,'{rows,0,data,body}','"Forged receipt"'),
    jsonb_set(p,'{rows,0,data,phone}','"synthetic"'),
    jsonb_set(p,'{rows,1,data,status}','"spooled"'),
    jsonb_set(p,'{rows,2,data,status}','"ambiguous"'),
    jsonb_set(p,'{rows,3,data,ordinal}','3'),
    jsonb_set(p,'{rows,1,data,order_id}',to_jsonb(gen_random_uuid())),
    jsonb_set(p,'{rows,1,data,restaurant_id}',to_jsonb(gen_random_uuid())),
    jsonb_set(p,'{event_count}','1'),
    jsonb_set(p,'{rows}',(p->'rows')-2)
  ] loop
    begin perform nohut_private.apply_typed_print(r,3,'1:-1:paymentReceipt',bad); raise exception 'invalid print audit accepted';
      exception when invalid_parameter_value then null; end;
  end loop;
  definition:=jsonb_set(definition,'{body}','"Rehashed rewritten receipt"');
  bad:=jsonb_set(p,'{rows,0,data}',definition||jsonb_build_object('order_id',oid,'snapshot_id',sid,
    'content_sha256',nohut_private.command_envelope_sha256(definition)));
  begin perform nohut_private.apply_typed_print(r,3,'1:-1:paymentReceipt',bad); raise exception 'immutable receipt overwritten';
    exception when invalid_parameter_value then null; end;
  if (select count(*) from nohut_private.receipt_snapshots where restaurant_id=r)<>1
    or (select count(*) from nohut_private.print_job_events where restaurant_id=r)<>2
    or (select status from nohut_private.print_jobs where restaurant_id=r)<>'dispatching' then raise exception 'partial print state persisted'; end if;
  foreach t in array array['receipt_snapshots','print_jobs','print_job_events'] loop
    if has_table_privilege('authenticated','nohut_private.'||t,'select,insert,update,delete')
      or has_table_privilege('anon','nohut_private.'||t,'select,insert,update,delete')
      or has_table_privilege('service_role','nohut_private.'||t,'select,insert,update,delete') then raise exception 'print grants leaked'; end if;
  end loop;
end $$;
set local role authenticated;
do $$ begin
  begin perform 1 from nohut_private.receipt_snapshots; raise exception 'client read receipt directly'; exception when insufficient_privilege then null; end;
  begin perform 1 from nohut_private.print_jobs; raise exception 'client read prints directly'; exception when insufficient_privilege then null; end;
  begin perform 1 from nohut_private.print_job_events; raise exception 'client read print events directly'; exception when insufficient_privilege then null; end;
end $$;
reset role;
rollback;
