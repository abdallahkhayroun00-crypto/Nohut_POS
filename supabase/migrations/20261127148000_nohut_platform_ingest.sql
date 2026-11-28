begin;
create function nohut_private.apply_typed_platform(p_restaurant uuid,p_revision bigint,p_source text,p jsonb)
returns void language plpgsql security invoker set search_path='' as $$
declare oid uuid; rid uuid; vid uuid; r jsonb; head jsonb; rec jsonb; ver jsonb; facts jsonb; ordered jsonb; ordinal integer:=0;
begin
  perform nohut_private.command_shape(p,'{"source_updated_at":"string","source_key":"string","order_id":"string","record_id":"string","platform_version_id":"string","line_count":"integer","rows":"array"}');
  oid:=(p->>'order_id')::uuid;rid:=(p->>'record_id')::uuid;vid:=(p->>'platform_version_id')::uuid;
  if p_source is distinct from p->>'source_key' or oid is null or rid is null or vid is null or (p->>'line_count')::bigint<0 then
    raise exception 'platform source identity missing' using errcode='22023'; end if;
  if (select count(*) from jsonb_array_elements(p->'rows') x where x->>'table'='orders')<>1
    or (select count(*) from jsonb_array_elements(p->'rows') x where x->>'table'='platform_order_records')<>1
    or (select count(*) from jsonb_array_elements(p->'rows') x where x->>'table'='platform_order_versions')<>1
    or (select count(*) from jsonb_array_elements(p->'rows') x where x->>'table'='platform_line_versions')<>(p->>'line_count')::bigint then
    raise exception 'incomplete platform manifest' using errcode='22023'; end if;
  select x->'data' into head from jsonb_array_elements(p->'rows') x where x->>'table'='orders';
  select x->'data' into rec from jsonb_array_elements(p->'rows') x where x->>'table'='platform_order_records';
  select x->'data' into ver from jsonb_array_elements(p->'rows') x where x->>'table'='platform_order_versions';
  if head->>'order_id' is distinct from oid::text or rec->>'order_id' is distinct from oid::text
    or rec->>'record_id' is distinct from rid::text or ver->>'record_id' is distinct from rid::text
    or ver->>'platform_version_id' is distinct from vid::text or rec->>'current_version_id' is distinct from vid::text
    or head->>'channel' is distinct from 'trendyol' or rec->>'platform' is distinct from 'trendyol'
    or head->>'local_order_id' is distinct from 'platform:trendyol:'||p_source
    or p_source is distinct from (rec->>'external_supplier_id')||':'||(rec->>'external_store_id')||':'||(rec->>'external_order_id')
    or coalesce(rec->>'external_supplier_id','')='' or coalesce(rec->>'external_store_id','')='' or coalesce(rec->>'external_order_id','')='' then
    raise exception 'platform references mismatch' using errcode='22023'; end if;
  if rec->>'external_supplier_id' !~ '^[A-Za-z0-9_-]{1,100}$' or rec->>'external_store_id' !~ '^[A-Za-z0-9_-]{1,100}$'
    or rec->>'external_order_id' !~ '^[A-Za-z0-9_-]{1,100}$'
    or (select count(distinct x) from jsonb_array_elements(ver->'package_item_ids') x)<>jsonb_array_length(ver->'package_item_ids') then
    raise exception 'invalid platform package identity' using errcode='22023'; end if;
  if head->'total_kurus' is distinct from ver->'total_kurus' or rec->'order_total_kurus' is distinct from ver->'total_kurus'
    or head->'status' is distinct from ver->'status' or rec->'status' is distinct from ver->'status'
    or head->'opened_at' is distinct from ver->'created_at' or head->'paid_kurus' is distinct from '0'::jsonb
    or head->'due_kurus' is distinct from '0'::jsonb or head->>'platform_collection' is distinct from 'Unknown'
    or (head->>'business_day')::date<>((ver->>'created_at')::timestamptz at time zone 'Europe/Istanbul')::date
    or head->'cancelled' is distinct from to_jsonb(ver->>'status' in ('Cancelled','UnSupplied'))
    or ver->'sales_eligible' is distinct from to_jsonb(ver->>'status'='Delivered' and ver->'test_package'='false'::jsonb)
    or ver->'line_count' is distinct from p->'line_count'
    or rec->'gross_kurus' is distinct from 'null'::jsonb or rec->'commission_kurus' is distinct from 'null'::jsonb
    or rec->'discount_kurus' is distinct from 'null'::jsonb or rec->'net_kurus' is distinct from 'null'::jsonb then
    raise exception 'platform financial facts mismatch or inferred settlement' using errcode='22023'; end if;
  for r in select x->'data' from jsonb_array_elements(p->'rows') x where x->>'table'='platform_line_versions' order by (x->'data'->>'ordinal')::bigint loop
    if r->'ordinal' is distinct from to_jsonb(ordinal) or r->>'platform_version_id' is distinct from vid::text
      or (r->'quantity_known'='true'::jsonb and (jsonb_typeof(r->'original_qty') is distinct from 'number'
        or (r->>'original_qty')::numeric<(r->>'qty')::numeric or (r->>'original_qty')::numeric<jsonb_array_length(r->'item_ids')))
      or (r->'quantity_known'='false'::jsonb and r->'original_qty' is distinct from 'null'::jsonb)
      or (r->'quantity_known'='true'::jsonb and jsonb_array_length(r->'cancelled_item_ids')>(r->>'original_qty')::numeric-(r->>'qty')::numeric)
      or exists(select 1 from jsonb_array_elements(r->'cancelled_item_ids') item where not(r->'item_ids' @> jsonb_build_array(item)))
      or (select count(distinct x) from jsonb_array_elements(r->'item_ids') x)<>jsonb_array_length(r->'item_ids') then
      raise exception 'invalid platform line facts' using errcode='22023'; end if;
    ordinal:=ordinal+1;
  end loop;
  if ver->'source_complete'='true'::jsonb and (select coalesce(jsonb_agg(item order by item::text),'[]'::jsonb)
      from jsonb_array_elements(p->'rows') x cross join lateral jsonb_array_elements(x->'data'->'item_ids') item
      where x->>'table'='platform_line_versions') is distinct from
      (select coalesce(jsonb_agg(item order by item::text),'[]'::jsonb) from jsonb_array_elements(ver->'package_item_ids') item) then
    raise exception 'platform package item manifest mismatch' using errcode='22023'; end if;
  select coalesce(jsonb_agg((x->'data')-array['platform_version_id','line_version_id'] order by (x->'data'->>'ordinal')::bigint),'[]'::jsonb)
    into facts from jsonb_array_elements(p->'rows') x where x->>'table'='platform_line_versions';
  if ver->>'content_sha256' is distinct from nohut_private.command_envelope_sha256(jsonb_build_object(
    'header',ver-array['record_id','platform_version_id','content_sha256'],'lines',facts)) then raise exception 'platform version hash mismatch' using errcode='22023'; end if;
  select jsonb_agg(x order by array_position(array['orders','platform_order_records','platform_order_versions','platform_line_versions'],x->>'table'))
    into ordered from jsonb_array_elements(p->'rows') x;
  perform nohut_private.apply_typed_projection(p_restaurant,p_revision,'platform:'||rid::text,
    jsonb_build_object('source_updated_at',p->'source_updated_at','rows',ordered));
end $$;
revoke all on function nohut_private.apply_typed_platform(uuid,bigint,text,jsonb) from public,anon,authenticated,service_role;
commit;
