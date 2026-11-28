begin;
alter table nohut_private.orders
  add column paid_kurus bigint not null default 0 check(paid_kurus>=0),
  add column due_kurus bigint not null default 0 check(due_kurus>=0),
  add column cancelled boolean not null default false,add column table_released boolean not null default false,
  add column service_status text,add column pickup_channel text,add column pickup_time text,
  add column customer_local_id bigint,add column cancel_reason text,add column number_day date,add column platform_collection text,
  add column service_started_at timestamptz,add column ready_at timestamptz,add column delivered_at timestamptz,add column cancelled_at timestamptz;
alter table nohut_private.order_batches add column local_batch_id bigint,add column source_time_label text;
alter table nohut_private.order_items add column local_line_key text,
  add column correction boolean not null default false,add column source_product_local_id bigint,
  add column source_product_key text,add column customizations jsonb not null default '{}';
create unique index order_item_global_identity on nohut_private.order_items(restaurant_id,item_id);
alter table nohut_private.products add column source_item_id uuid,
  add foreign key(restaurant_id,source_item_id) references nohut_private.order_items(restaurant_id,item_id) deferrable initially deferred;
alter table nohut_private.payments add column actor_label text,add column reversed boolean not null default false,
  add column net_kurus bigint not null default 0 check(net_kurus>=0),add column local_guest_id bigint,
  add column combined_payment_id text,add column terminal_reference text,add column transaction_id text,
  add column product_payment_id text;
alter table nohut_private.payment_refunds add column actor_label text,add column reason text;

create table nohut_private.guest_checks(
  restaurant_id uuid not null,order_id uuid not null,guest_id uuid not null,local_id bigint not null,
  label text not null,allocated_kurus bigint not null,paid_kurus bigint not null,balance_kurus bigint not null,
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,order_id,guest_id),foreign key(restaurant_id,order_id) references nohut_private.orders
);
create table nohut_private.guest_allocations(
  restaurant_id uuid not null,order_id uuid not null,guest_id uuid not null,allocation_id uuid not null,
  item_id uuid not null,local_line_key text not null,amount_kurus bigint not null check(amount_kurus>=0),
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,order_id,guest_id,allocation_id),
  foreign key(restaurant_id,order_id,guest_id) references nohut_private.guest_checks,
  foreign key(restaurant_id,item_id) references nohut_private.order_items(restaurant_id,item_id)
);
create table nohut_private.payment_guest_allocations(
  restaurant_id uuid not null,order_id uuid not null,payment_id uuid not null,allocation_id uuid not null,
  local_guest_id bigint not null,amount_kurus bigint not null check(amount_kurus>=0),
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,order_id,payment_id,allocation_id),
  foreign key(restaurant_id,order_id,payment_id) references nohut_private.payments
);
create table nohut_private.order_events(
  restaurant_id uuid not null,order_id uuid not null,event_id uuid not null,message text not null,
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,order_id,event_id),foreign key(restaurant_id,order_id) references nohut_private.orders
);
create table nohut_private.order_line_edits(
  restaurant_id uuid not null,order_id uuid not null,edit_id uuid not null,item_id uuid not null,
  changed_at timestamptz not null,actor_label text not null,local_line_key text not null,
  before_label text not null,before_qty bigint not null,before_unit_price_kurus bigint not null,
  before_customizations jsonb not null,
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,order_id,edit_id),foreign key(restaurant_id,order_id) references nohut_private.orders,
  foreign key(restaurant_id,item_id) references nohut_private.order_items(restaurant_id,item_id)
);
create table nohut_private.order_voids(
  restaurant_id uuid not null,order_id uuid not null,void_id uuid not null,label text not null,
  quantity bigint not null check(quantity>0),unit_price_kurus bigint not null check(unit_price_kurus>=0),
  recorded_at timestamptz not null,reason text not null,
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,order_id,void_id),foreign key(restaurant_id,order_id) references nohut_private.orders
);
create table nohut_private.deleted_order_audit(
  restaurant_id uuid not null,order_id uuid not null,deleted_at_source timestamptz not null,
  actor_label text,actor_local_id bigint,reason text not null,request_id text not null,
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,order_id),foreign key(restaurant_id,order_id) references nohut_private.orders
);
do $$ declare t text; begin
  foreach t in array array['guest_checks','guest_allocations','payment_guest_allocations','order_events',
      'order_line_edits','order_voids','deleted_order_audit'] loop
    execute format('alter table nohut_private.%I enable row level security',t);
    execute format('alter table nohut_private.%I force row level security',t);
    execute format('create policy order_rpc_owner on nohut_private.%I for all to %I using (true) with check (true)',t,current_user);
    execute format('revoke all on nohut_private.%I from public,anon,authenticated,service_role',t);
  end loop;
end $$;
commit;
