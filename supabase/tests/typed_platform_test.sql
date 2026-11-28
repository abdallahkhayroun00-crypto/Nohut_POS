\set ON_ERROR_STOP on
-- Synthetic fixture exported by the real Dart serializer. Never restaurant data.
begin;
create function pg_temp.platform_fixture() returns jsonb language sql immutable as $sql$
  select $fixture${"source_updated_at":"2026-11-27T12:00:00Z","source_key":"12345:456:synthetic-package","order_id":"60d169fe-c130-4980-b52d-767f9b47307c","record_id":"176afec6-5147-4165-b210-78f2dc88d94b","platform_version_id":"495e275b-0469-4dc9-98e1-0bf7f78345a8","line_count":3,"rows":[{"table":"orders","data":{"order_id":"60d169fe-c130-4980-b52d-767f9b47307c","local_order_id":"platform:trendyol:12345:456:synthetic-package","channel":"trendyol","table_id":null,"opened_at":"2026-11-26T22:30:00.000Z","business_day":"2026-11-27","status":"Picking","total_kurus":2000,"paid_kurus":0,"due_kurus":0,"cancelled":false,"table_released":false,"platform_collection":"Unknown"}},{"table":"platform_order_records","data":{"record_id":"176afec6-5147-4165-b210-78f2dc88d94b","order_id":"60d169fe-c130-4980-b52d-767f9b47307c","platform":"trendyol","external_supplier_id":"12345","external_store_id":"456","external_order_id":"synthetic-package","order_total_kurus":2000,"status":"Picking","gross_kurus":null,"commission_kurus":null,"discount_kurus":null,"net_kurus":null,"current_version_id":"495e275b-0469-4dc9-98e1-0bf7f78345a8"}},{"table":"platform_order_versions","data":{"record_id":"176afec6-5147-4165-b210-78f2dc88d94b","platform_version_id":"495e275b-0469-4dc9-98e1-0bf7f78345a8","external_order_reference":"synthetic-order","order_number":"SYNTHETIC-1","order_code":"","status":"Picking","created_at":"2026-11-26T22:30:00.000Z","modified_at":"2026-11-26T22:31:00.000Z","total_kurus":2000,"total_known":true,"payment_type":"ONLINE","cancel_reason":"","preparation_minutes":null,"pickup":false,"test_package":false,"sales_eligible":false,"daily_number":null,"number_day":null,"customer_note":"Sos ayrı olsun · [yerel iletişim bilgisi] · [yerel iletişim bilgisi] · [yerel iletişim bilgisi]","delivery_type":null,"app_name":null,"pickup_eta_state":null,"delivery_eta":null,"courier_nearby":null,"courier_eta_from":null,"courier_eta_to":null,"kitchen_print_state":null,"kitchen_queued_at":null,"package_item_ids":["item-a","item-b","item-c"],"source_complete":true,"line_count":3,"privacy":"customer_contact_redacted","content_sha256":"e6322f8676102dfa07ad23e06b951bd3cd4d2fd88f0dfa3d35fbe74db78bf420"}},{"table":"platform_line_versions","data":{"platform_version_id":"495e275b-0469-4dc9-98e1-0bf7f78345a8","line_version_id":"94871972-f5d8-48f8-801d-a7b1a92ae120","ordinal":0,"label":"Synthetic original falafel","qty":1,"original_qty":1,"quantity_known":true,"unit_price_kurus":1234,"unit_price_known":true,"item_ids":["item-a"],"cancelled_item_ids":[],"options":["Synthetic sauce"],"removed":["Soğan"],"extras":["Humus"]}},{"table":"platform_line_versions","data":{"platform_version_id":"495e275b-0469-4dc9-98e1-0bf7f78345a8","line_version_id":"cc9e836d-878c-409e-9f2d-b4cc688b0573","ordinal":1,"label":"Synthetic original falafel","qty":1,"original_qty":1,"quantity_known":true,"unit_price_kurus":1234,"unit_price_known":true,"item_ids":["item-b"],"cancelled_item_ids":[],"options":["Synthetic sauce"],"removed":["Soğan"],"extras":["Humus"]}},{"table":"platform_line_versions","data":{"platform_version_id":"495e275b-0469-4dc9-98e1-0bf7f78345a8","line_version_id":"8974a6e5-4cdd-420f-92e3-7a1fcbcc3bec","ordinal":2,"label":"Synthetic cancelled item","qty":0,"original_qty":1,"quantity_known":true,"unit_price_kurus":999,"unit_price_known":true,"item_ids":["item-c"],"cancelled_item_ids":["item-c"],"options":[],"removed":[],"extras":[]}}]}$fixture$::jsonb
$sql$;
create function pg_temp.rehash_platform(p jsonb) returns jsonb language plpgsql as $$
declare ver jsonb; facts jsonb;
begin
  ver:=p->'rows'->2->'data';
  select coalesce(jsonb_agg((x->'data')-array['platform_version_id','line_version_id'] order by (x->'data'->>'ordinal')::bigint),'[]'::jsonb)
    into facts from jsonb_array_elements(p->'rows') x where x->>'table'='platform_line_versions';
  return jsonb_set(p,'{rows,2,data,content_sha256}',to_jsonb(nohut_private.command_envelope_sha256(jsonb_build_object(
    'header',ver-array['record_id','platform_version_id','content_sha256'],'lines',facts))));
end $$;
do $$
declare r uuid:=gen_random_uuid(); p jsonb:=pg_temp.platform_fixture(); bad jsonb; t text;
begin
  insert into nohut_private.restaurants(restaurant_id) values(r);
  perform nohut_private.apply_typed_platform(r,1,p->>'source_key',p);
  set constraints all immediate;set constraints all deferred;
  if (select count(*) from nohut_private.platform_line_versions where restaurant_id=r)<>3
    or (select sum(original_qty-qty) from nohut_private.platform_line_versions where restaurant_id=r)<>1
    or (select order_total_kurus from nohut_private.platform_order_records where restaurant_id=r)<>2000
    or (select net_kurus from nohut_private.platform_order_records where restaurant_id=r) is not null then
    raise exception 'platform financial facts missing or inferred'; end if;
  perform nohut_private.apply_typed_platform(r,1,p->>'source_key',p);
  foreach bad in array array[
    jsonb_set(p,'{line_count}','2'),
    jsonb_set(p,'{rows}',(p->'rows')-5),
    jsonb_set(p,'{rows,0,data,order_id}',to_jsonb(gen_random_uuid())),
    jsonb_set(p,'{rows,0,data,paid_kurus}','2000'),
    jsonb_set(p,'{rows,0,data,business_day}','"2026-11-26"'),
    jsonb_set(p,'{rows,1,data,net_kurus}','1800'),
    jsonb_set(p,'{rows,1,data,external_supplier_id}','"foreign"'),
    jsonb_set(p,'{rows,2,data,content_sha256}',to_jsonb(repeat('0',64))),
    jsonb_set(p,'{rows,3,data,platform_version_id}',to_jsonb(gen_random_uuid())),
    jsonb_set(p,'{rows,5,data,cancelled_item_ids}','["unknown-item"]'),
    jsonb_set(p,'{rows,2,data,package_item_ids}','["item-a","item-a"]'),
    pg_temp.rehash_platform(jsonb_set(p,'{rows,3,data,original_qty}','0')),
    pg_temp.rehash_platform(jsonb_set(p,'{rows,3,data,unit_price_kurus}','"1234"')),
    jsonb_set(p,'{rows,3,data,unit_price_kurus}','1234.5'),
    pg_temp.rehash_platform(jsonb_set(p,'{rows,3,data,options}','["Synthetic",42]')),
    pg_temp.rehash_platform(jsonb_set(p,'{rows,2,data,customer_phone}','"synthetic"')),
    pg_temp.rehash_platform(jsonb_set(p,'{rows,2,data,restaurant_id}',to_jsonb(gen_random_uuid())))
  ] loop
    begin perform nohut_private.apply_typed_platform(r,2,p->>'source_key',bad);raise exception 'invalid platform accepted';
      exception when invalid_parameter_value then null;end;
  end loop;
  -- Recomputed checksums cannot rewrite an existing commercial version;
  -- earlier header mutations in the same function roll back as well.
  bad:=jsonb_set(jsonb_set(jsonb_set(p,'{rows,0,data,total_kurus}','2200'),'{rows,1,data,order_total_kurus}','2200'),'{rows,2,data,total_kurus}','2200');
  bad:=pg_temp.rehash_platform(bad);
  begin perform nohut_private.apply_typed_platform(r,2,p->>'source_key',bad);raise exception 'platform version rewritten';
    exception when invalid_parameter_value then null;end;
  if (select count(*) from nohut_private.platform_order_versions where restaurant_id=r)<>1
    or (select order_total_kurus from nohut_private.platform_order_records where restaurant_id=r)<>2000
    or exists(select 1 from nohut_private.typed_record_history where restaurant_id=r) then raise exception 'partial platform persisted'; end if;
  foreach t in array array['platform_order_versions','platform_line_versions'] loop
    if has_table_privilege('authenticated','nohut_private.'||t,'select,insert,update,delete')
      or has_table_privilege('anon','nohut_private.'||t,'select,insert,update,delete') then raise exception 'platform grants leaked';end if;
  end loop;
end $$;
set local role authenticated;
do $$ begin
  begin perform 1 from nohut_private.platform_order_versions;raise exception 'client read platform versions';exception when insufficient_privilege then null;end;
  begin perform 1 from nohut_private.platform_line_versions;raise exception 'client read platform lines';exception when insufficient_privilege then null;end;
end $$;
reset role;
rollback;
