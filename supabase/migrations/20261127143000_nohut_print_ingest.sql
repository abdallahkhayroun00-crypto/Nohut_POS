begin;
create function nohut_private.apply_typed_print(p_restaurant uuid,p_revision bigint,p_source text,p jsonb)
returns void language plpgsql security invoker set search_path='' as $$
declare oid uuid; jid uuid; job jsonb; receipt jsonb; ev jsonb; prev jsonb; ordinal integer:=0; ordered jsonb;
begin
  perform nohut_private.command_shape(p,'{"source_updated_at":"string","local_order_id":"string","order_id":"string","job_id":"string","source_key":"string","event_count":"integer","rows":"array"}');
  oid:=(p->>'order_id')::uuid; jid:=(p->>'job_id')::uuid;
  if p_source is distinct from p->>'source_key' or oid is null or jid is null
    or not exists(select 1 from nohut_private.orders o where o.restaurant_id=p_restaurant and o.order_id=oid and o.local_order_id=p->>'local_order_id') then
    raise exception 'print source order mismatch' using errcode='22023'; end if;
  if (select count(*) from jsonb_array_elements(p->'rows') x where x->>'table'='receipt_snapshots')<>1
    or (select count(*) from jsonb_array_elements(p->'rows') x where x->>'table'='print_jobs')<>1
    or (p->>'event_count')::bigint<1
    or (select count(*) from jsonb_array_elements(p->'rows') x where x->>'table'='print_job_events')<>(p->>'event_count')::bigint then
    raise exception 'incomplete print manifest' using errcode='22023'; end if;
  for ev in select value from jsonb_array_elements(p->'rows') loop
    if ev->'data'->>'order_id' is distinct from oid::text or (ev->>'table'<>'receipt_snapshots' and ev->'data'->>'job_id' is distinct from jid::text) then
      raise exception 'cross-order print row' using errcode='22023'; end if;
  end loop;
  select x->'data' into job from jsonb_array_elements(p->'rows') x where x->>'table'='print_jobs';
  select x->'data' into receipt from jsonb_array_elements(p->'rows') x where x->>'table'='receipt_snapshots';
  if job->>'source_key' is distinct from p_source or job->'snapshot_id' is distinct from receipt->'snapshot_id'
    or p_source is distinct from (p->>'local_order_id')||':'||(job->>'batch_local_id')||':'||coalesce(job->>'local_kind','')
    or job->>'receipt_kind' is distinct from (case when job->>'local_kind'='paymentReceipt' then 'payment' else 'kitchen' end)
    or job->'receipt_kind' is distinct from receipt->'receipt_kind'
    or (job->>'receipt_kind'='payment') is distinct from (receipt->>'source_format'='payment_text') then
    raise exception 'print receipt mismatch' using errcode='22023'; end if;
  for ev in select x->'data' from jsonb_array_elements(p->'rows') x where x->>'table'='print_job_events' order by (x->'data'->>'ordinal')::bigint loop
    if ev->'ordinal' is distinct from to_jsonb(ordinal) or (ordinal=0 and ev->>'origin' not in ('created','legacy_current'))
      or (ordinal>0 and (ev->>'origin'<>'transition' or (ev->>'attempts')::bigint<(prev->>'attempts')::bigint
        or (ev->>'observed_at')::timestamptz<(prev->>'observed_at')::timestamptz)) then
      raise exception 'invalid print event chain' using errcode='22023'; end if;
    prev:=ev; ordinal:=ordinal+1;
  end loop;
  if prev->'status' is distinct from job->'status' or prev->'attempts' is distinct from job->'attempts'
    or prev->'spooled_at' is distinct from job->'spooled_at' then raise exception 'print current state not audited' using errcode='22023'; end if;
  select jsonb_agg(x order by array_position(array['receipt_snapshots','print_jobs','print_job_events'],x->>'table'),(x->'data'->>'ordinal')::bigint)
    into ordered from jsonb_array_elements(p->'rows') x;
  perform nohut_private.apply_typed_projection(p_restaurant,p_revision,'print:'||jid::text,
    jsonb_build_object('source_updated_at',p->'source_updated_at','rows',ordered));
end $$;
revoke all on function nohut_private.apply_typed_print(uuid,bigint,text,jsonb) from public,anon,authenticated,service_role;
commit;
