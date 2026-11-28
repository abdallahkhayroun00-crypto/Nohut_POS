-- Full local-order snapshots, validated and committed with their entire outbox group.
begin;
create function nohut_private.apply_typed_order(p_restaurant uuid,p_revision bigint,p_local text,p jsonb)
returns void language plpgsql security invoker set search_path='' set timezone='UTC' as $$
declare oid uuid; head jsonb; r jsonb; t text; all_rows jsonb; omitted record; d jsonb;
  expected text[]:=array['orders','order_batches','order_items','payments','payment_refunds','guest_checks','guest_allocations',
    'payment_guest_allocations','order_events','order_line_edits','order_voids','deleted_order_audit'];
  total numeric; paid numeric; net numeric; refunded numeric; allocated numeric;
begin
  perform nohut_private.command_shape(p,'{"source_updated_at":"string","order_id":"string","local_order_id":"string","counts":"object","rows":"array"}');
  oid:=(p->>'order_id')::uuid;
  if oid is null or p_local is distinct from p->>'local_order_id' or p_local !~ '^[0-9]+$' then
    raise exception 'order source identity mismatch' using errcode='22023'; end if;
  if (select array_agg(k order by k) from jsonb_object_keys(p->'counts') k) is distinct from
     (select array_agg(k order by k) from unnest(expected) k) then raise exception 'order manifest missing' using errcode='22023'; end if;
  foreach t in array expected loop
    if jsonb_typeof(p->'counts'->t) is distinct from 'number' or p->'counts'->>t !~ '^[0-9]+$'
      or (p->'counts'->>t)::numeric<>(select count(*) from jsonb_array_elements(p->'rows') x where x->>'table'=t) then
      raise exception 'order manifest count mismatch' using errcode='22023'; end if;
  end loop;
  if (p->'counts'->>'orders')::integer<>1 then raise exception 'one order required' using errcode='22023'; end if;
  for r in select value from jsonb_array_elements(p->'rows') loop
    t:=r->>'table'; d:=r->'data';
    if t=any(expected) and d->>'order_id' is distinct from oid::text then raise exception 'cross-order row' using errcode='22023'; end if;
    if t='products' and not exists(select 1 from jsonb_array_elements(p->'rows') i where i->>'table'='order_items'
      and i->'data'->>'item_id'=d->>'source_item_id' and i->'data'->>'product_id'=d->>'product_id'
      and i->'data'->>'product_version_id'=d->>'current_version_id') then raise exception 'unbound sale product' using errcode='22023'; end if;
    if t='order_items' and (not exists(select 1 from jsonb_array_elements(p->'rows') i where i->>'table'='products'
      and i->'data'->>'source_item_id'=d->>'item_id' and i->'data'->>'product_id'=d->>'product_id')
      or not exists(select 1 from jsonb_array_elements(p->'rows') i where i->>'table'='product_versions'
        and i->'data'->>'product_id'=d->>'product_id' and i->'data'->>'product_version_id'=d->>'product_version_id')) then
      raise exception 'sale definition missing' using errcode='22023'; end if;
    if t='product_versions' and not exists(select 1 from jsonb_array_elements(p->'rows') i where i->>'table'='order_items'
      and i->'data'->>'product_id'=d->>'product_id' and i->'data'->>'product_version_id'=d->>'product_version_id'
      and i->'data'->>'sale_label'=d->>'label_tr' and i->'data'->'unit_price_kurus'=d->'price_kurus') then
      raise exception 'unbound sale version' using errcode='22023'; end if;
    if t='pos_tables' and not exists(select 1 from jsonb_array_elements(p->'rows') i where i->>'table'='orders' and i->'data'->>'table_id'=d->>'table_id') then
      raise exception 'unbound order table' using errcode='22023'; end if;
  end loop;
  select x->'data' into head from jsonb_array_elements(p->'rows') x where x->>'table'='orders';
  if head->>'local_order_id' is distinct from p_local or head->>'channel' not in ('masa','gel_al')
    or head->>'status' not in ('open','closed','cancelled') then raise exception 'unsupported order header' using errcode='22023'; end if;
  if (head->>'business_day')::date<>((head->>'opened_at')::timestamptz at time zone 'Europe/Istanbul')::date then
    raise exception 'order business day mismatch' using errcode='22023'; end if;
  if (head->>'cancelled')::boolean is distinct from (head->>'status'='cancelled') then raise exception 'order status mismatch' using errcode='22023'; end if;
  select coalesce(sum((x->'data'->>'qty')::numeric*(x->'data'->>'unit_price_kurus')::numeric),0) into total
    from jsonb_array_elements(p->'rows') x where x->>'table'='order_items'
    and x->'data'->'voided'='false'::jsonb and x->'data'->'correction'='false'::jsonb;
  if (head->>'cancelled')::boolean then total:=0; end if;
  select coalesce(sum((x->'data'->>'net_kurus')::numeric),0) into paid from jsonb_array_elements(p->'rows') x where x->>'table'='payments';
  if (head->>'total_kurus')::numeric is distinct from total or (head->>'paid_kurus')::numeric is distinct from paid
    or (head->>'due_kurus')::numeric is distinct from (case when (head->>'cancelled')::boolean then 0 else greatest(total-paid,0) end) then
    raise exception 'Windows order totals mismatch' using errcode='22023'; end if;
  for r in select x->'data' from jsonb_array_elements(p->'rows') x where x->>'table'='payments' loop
    select coalesce(sum((x->'data'->>'amount_kurus')::numeric),0) into refunded from jsonb_array_elements(p->'rows') x
      where x->>'table'='payment_refunds' and x->'data'->>'payment_id'=r->>'payment_id';
    net:=case when r->'reversed'='true'::jsonb then 0 else (r->>'amount_kurus')::numeric-refunded end;
    if refunded>(r->>'amount_kurus')::numeric or net is distinct from (r->>'net_kurus')::numeric then raise exception 'payment net mismatch' using errcode='22023'; end if;
    select coalesce(sum((x->'data'->>'amount_kurus')::numeric),0) into allocated from jsonb_array_elements(p->'rows') x
      where x->>'table'='payment_guest_allocations' and x->'data'->>'payment_id'=r->>'payment_id';
    if allocated>(r->>'amount_kurus')::numeric then raise exception 'payment allocation exceeds payment' using errcode='22023'; end if;
  end loop;
  for r in select x->'data' from jsonb_array_elements(p->'rows') x where x->>'table'='guest_checks' loop
    select coalesce(sum((x->'data'->>'amount_kurus')::numeric),0) into allocated from jsonb_array_elements(p->'rows') x
      where x->>'table'='guest_allocations' and x->'data'->>'guest_id'=r->>'guest_id';
    select coalesce(sum(case when x->'data'->'reversed'='true'::jsonb then 0
      when x->'data'->'local_guest_id'=r->'local_id' then (x->'data'->>'net_kurus')::numeric
      else (select coalesce(sum((a->'data'->>'amount_kurus')::numeric),0) from jsonb_array_elements(p->'rows') a
        where a->>'table'='payment_guest_allocations' and a->'data'->>'payment_id'=x->'data'->>'payment_id'
        and a->'data'->'local_guest_id'=r->'local_id') end),0) into net
      from jsonb_array_elements(p->'rows') x where x->>'table'='payments';
    if allocated is distinct from (r->>'allocated_kurus')::numeric or net is distinct from (r->>'paid_kurus')::numeric
      or allocated-net is distinct from (r->>'balance_kurus')::numeric then raise exception 'guest totals mismatch' using errcode='22023'; end if;
  end loop;
  if (p->'counts'->>'deleted_order_audit')::integer not in (0,1) or exists(select 1 from jsonb_array_elements(p->'rows') x where x->>'table'='orders'
    and coalesce(x->'deleted','false') is distinct from to_jsonb((p->'counts'->>'deleted_order_audit')::integer=1)) then
    raise exception 'order archive must include audit' using errcode='22023'; end if;
  -- Only nonfinancial allocations/checks may disappear from a complete snapshot.
  -- Retain their last facts with a tombstone and the old version in the audit ledger.
  all_rows:=p->'rows';
  for omitted in select * from nohut_private.typed_record_versions v where v.restaurant_id=p_restaurant and v.category='order:'||oid::text
    and v.table_name in ('guest_checks','guest_allocations','payment_guest_allocations')
    and not exists(select 1 from jsonb_array_elements(p->'rows') x where x->>'table'=v.table_name and x->'data' @> (v.record_key-'restaurant_id')) loop
    all_rows:=all_rows||jsonb_build_array(jsonb_build_object('table',omitted.table_name,
      'data',omitted.body-array['restaurant_id','deleted_at'],'deleted',true,
      'removed_at',coalesce(omitted.body->>'deleted_at',p->>'source_updated_at')));
  end loop;
  -- A deterministic dependency order; deferred historical-product backreferences
  -- are verified when the enclosing transaction commits.
  select jsonb_agg(x order by array_position(array['pos_tables','orders','products','product_versions','order_batches','order_items','payments',
    'payment_refunds','guest_checks','guest_allocations','payment_guest_allocations','order_events','order_line_edits','order_voids','deleted_order_audit'],x->>'table'))
    into all_rows from jsonb_array_elements(all_rows) x;
  perform nohut_private.apply_typed_projection(p_restaurant,p_revision,'order:'||oid::text,
    jsonb_build_object('source_updated_at',p->'source_updated_at','rows',all_rows));
end $$;
revoke all on function nohut_private.apply_typed_order(uuid,bigint,text,jsonb) from public,anon,authenticated,service_role;
commit;
