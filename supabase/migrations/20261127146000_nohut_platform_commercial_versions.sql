begin;
alter table nohut_private.platform_order_records
  add column record_id uuid not null default gen_random_uuid(),add column external_supplier_id text not null default '',
  add column current_version_id uuid,add column order_total_kurus bigint check(order_total_kurus>=0);
alter table nohut_private.platform_order_records drop constraint platform_order_records_pkey;
alter table nohut_private.platform_order_records add primary key(restaurant_id,platform,external_supplier_id,external_store_id,external_order_id),
  add unique(restaurant_id,record_id);
create table nohut_private.platform_order_versions(
  restaurant_id uuid not null,record_id uuid not null,platform_version_id uuid not null,
  external_order_reference text,order_number text not null,order_code text,status text not null,
  created_at timestamptz not null,modified_at timestamptz not null,total_kurus bigint not null check(total_kurus>=0),total_known boolean,
  payment_type text,cancel_reason text,preparation_minutes bigint,pickup boolean not null,test_package boolean not null,sales_eligible boolean not null,
  daily_number bigint,number_day date,customer_note text not null,delivery_type text,app_name text,
  pickup_eta_state text,delivery_eta text,courier_nearby boolean,courier_eta_from timestamptz,courier_eta_to timestamptz,
  kitchen_print_state text,kitchen_queued_at timestamptz,package_item_ids text[] not null,
  source_complete boolean not null,line_count bigint not null check(line_count>=0),
  privacy text not null check(privacy='customer_contact_redacted'),content_sha256 text not null check(content_sha256 ~ '^[0-9a-f]{64}$'),
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,platform_version_id),foreign key(restaurant_id,record_id) references nohut_private.platform_order_records(restaurant_id,record_id)
);
alter table nohut_private.platform_order_records add foreign key(restaurant_id,current_version_id)
  references nohut_private.platform_order_versions(restaurant_id,platform_version_id) deferrable initially deferred;
create table nohut_private.platform_line_versions(
  restaurant_id uuid not null,platform_version_id uuid not null,line_version_id uuid not null,ordinal bigint not null check(ordinal>=0),
  label text not null,qty bigint not null check(qty>=0),original_qty bigint check(original_qty>=0),quantity_known boolean not null,
  unit_price_kurus bigint not null check(unit_price_kurus>=0),unit_price_known boolean,
  item_ids text[] not null,cancelled_item_ids text[] not null,options text[] not null,removed text[] not null,extras text[] not null,
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,line_version_id),unique(restaurant_id,platform_version_id,ordinal),
  foreign key(restaurant_id,platform_version_id) references nohut_private.platform_order_versions
);
do $$ declare t text; begin
  foreach t in array array['platform_order_versions','platform_line_versions'] loop
    execute format('alter table nohut_private.%I enable row level security',t);
    execute format('alter table nohut_private.%I force row level security',t);
    execute format('create policy platform_version_owner on nohut_private.%I for all to %I using (true) with check (true)',t,current_user);
    execute format('revoke all on nohut_private.%I from public,anon,authenticated,service_role',t);
  end loop;
end $$;
commit;
