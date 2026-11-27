-- V5.1 PR-05, foundation only. Do not apply to production yet.
-- No client grants, no public API, no credentials, no seed data.
-- Run through the migration runner in a disposable PostgreSQL database.
begin;

create schema nohut_private;
revoke all on schema nohut_private from public, anon, authenticated, service_role;
alter default privileges in schema nohut_private revoke all on tables from public, anon, authenticated, service_role;
alter default privileges in schema nohut_private revoke all on sequences from public, anon, authenticated, service_role;
alter default privileges in schema nohut_private revoke execute on functions from public, anon, authenticated, service_role;

create table nohut_private.restaurants (
  restaurant_id uuid primary key,
  created_at timestamptz not null default now()
);

-- Control plane: epoch identity is not a reusable credential.
create table nohut_private.authority_epochs (
  restaurant_id uuid not null references nohut_private.restaurants,
  authority_epoch uuid not null,
  created_at timestamptz not null default now(),
  retired_at timestamptz,
  primary key (restaurant_id, authority_epoch),
  check (retired_at is null or retired_at >= created_at)
);
create unique index authority_one_active_epoch
  on nohut_private.authority_epochs(restaurant_id) where retired_at is null;

create table nohut_private.sync_migrations (
  restaurant_id uuid not null,
  migration_id uuid not null,
  authority_epoch uuid not null,
  snapshot_revision bigint not null check (snapshot_revision >= 0),
  snapshot_seq bigint not null check (snapshot_seq >= 0),
  schema_version integer not null check (schema_version > 0),
  manifest_sha256 text not null check (manifest_sha256 ~ '^[0-9a-f]{64}$'),
  status text not null check (status in (
    'preflight','backup_verified','snapshot_ready','uploading','paused',
    'catching_up','verifying','verified_pending_activation','active',
    'failed','safely_aborted')),
  created_at timestamptz not null default now(),
  primary key (restaurant_id, migration_id),
  foreign key (restaurant_id, authority_epoch)
    references nohut_private.authority_epochs
);

create table nohut_private.migration_batches (
  restaurant_id uuid not null,
  migration_id uuid not null,
  batch_id uuid not null,
  category text not null check (length(category) between 1 and 64),
  item_count integer not null check (item_count >= 0),
  body_sha256 text not null check (body_sha256 ~ '^[0-9a-f]{64}$'),
  committed_at timestamptz not null default now(),
  primary key (restaurant_id, migration_id, batch_id),
  foreign key (restaurant_id, migration_id)
    references nohut_private.sync_migrations
);

-- Durable identity ledgers, not raw customer or platform payload archives.
create table nohut_private.sync_transactions (
  restaurant_id uuid not null,
  authority_epoch uuid not null,
  tx_id uuid not null,
  source_revision bigint not null check (source_revision >= 0),
  first_seq bigint not null check (first_seq > 0),
  last_seq bigint not null,
  event_count integer not null check (event_count > 0),
  schema_version integer not null check (schema_version > 0),
  body_sha256 text not null check (body_sha256 ~ '^[0-9a-f]{64}$'),
  committed_at timestamptz not null default now(),
  primary key (restaurant_id, authority_epoch, tx_id),
  unique (restaurant_id, authority_epoch, source_revision),
  foreign key (restaurant_id, authority_epoch)
    references nohut_private.authority_epochs,
  check (last_seq >= first_seq and last_seq - first_seq + 1 = event_count)
);
create table nohut_private.sync_event_ids (
  restaurant_id uuid not null,
  authority_epoch uuid not null,
  tx_id uuid not null,
  event_id text not null check (length(event_id) between 1 and 512),
  event_ordinal integer not null check (event_ordinal >= 0),
  seq bigint not null check (seq > 0),
  entity_type text not null check (length(entity_type) between 1 and 64),
  entity_id text not null check (length(entity_id) between 1 and 256),
  op text not null check (op in ('upsert','delete')),
  body_sha256 text not null check (body_sha256 ~ '^[0-9a-f]{64}$'),
  primary key (restaurant_id, authority_epoch, event_id),
  unique (restaurant_id, authority_epoch, seq),
  unique (restaurant_id, authority_epoch, tx_id, event_ordinal),
  foreign key (restaurant_id, authority_epoch, tx_id)
    references nohut_private.sync_transactions
);
create table nohut_private.sync_checkpoints (
  restaurant_id uuid not null,
  authority_epoch uuid not null,
  last_acked_seq bigint not null default 0 check (last_acked_seq >= 0),
  last_acked_revision bigint not null default 0 check (last_acked_revision >= 0),
  updated_at timestamptz not null default now(),
  primary key (restaurant_id, authority_epoch),
  foreign key (restaurant_id, authority_epoch)
    references nohut_private.authority_epochs
);
create table nohut_private.request_identities (
  restaurant_id uuid not null references nohut_private.restaurants,
  request_id text not null check (length(request_id) between 1 and 128),
  body_sha256 text not null check (body_sha256 ~ '^[0-9a-f]{64}$'),
  outcome_code text not null,
  committed_at timestamptz not null default now(),
  primary key (restaurant_id, request_id)
);

-- Business projection, not login identity or permissions.
-- IDs are assigned and persisted by a future typed serializer. Never derive
-- them from display labels, list positions, or daily order numbers.
create table nohut_private.employees (
  restaurant_id uuid not null references nohut_private.restaurants,
  employee_id uuid not null,
  display_name text not null,
  active boolean not null,
  entity_version bigint not null check (entity_version > 0),
  source_revision bigint not null check (source_revision >= 0),
  updated_at timestamptz not null,
  deleted_at timestamptz,
  primary key (restaurant_id, employee_id)
);
create table nohut_private.pos_tables (
  restaurant_id uuid not null references nohut_private.restaurants,
  table_id uuid not null,
  label text not null,
  entity_version bigint not null check (entity_version > 0),
  source_revision bigint not null check (source_revision >= 0),
  updated_at timestamptz not null,
  deleted_at timestamptz,
  primary key (restaurant_id, table_id)
);
create table nohut_private.products (
  restaurant_id uuid not null references nohut_private.restaurants,
  product_id uuid not null,
  entity_version bigint not null check (entity_version > 0),
  source_revision bigint not null check (source_revision >= 0),
  updated_at timestamptz not null,
  deleted_at timestamptz,
  primary key (restaurant_id, product_id)
);
create table nohut_private.product_versions (
  restaurant_id uuid not null,
  product_id uuid not null,
  product_version_id uuid not null,
  label_tr text not null,
  label_en text,
  label_ar text,
  price_kurus bigint not null check (price_kurus >= 0),
  content_sha256 text not null check (content_sha256 ~ '^[0-9a-f]{64}$'),
  entity_version bigint not null check (entity_version > 0),
  source_revision bigint not null check (source_revision >= 0),
  updated_at timestamptz not null,
  deleted_at timestamptz,
  primary key (restaurant_id, product_id, product_version_id),
  foreign key (restaurant_id, product_id)
    references nohut_private.products
);
-- Content hash is indexed for candidate lookup only; a future serializer
-- must compare content before reuse. Never deduplicate economic transactions.
create index product_version_hash
  on nohut_private.product_versions(restaurant_id, product_id, content_sha256);

create table nohut_private.orders (
  restaurant_id uuid not null references nohut_private.restaurants,
  order_id uuid not null,
  local_order_id text not null,
  channel text not null check (channel in ('masa','gel_al','trendyol','yemeksepeti','migros')),
  table_id uuid,
  opened_at timestamptz not null,
  closed_at timestamptz,
  business_day date not null,
  daily_number integer,
  status text not null,
  total_kurus bigint check (total_kurus >= 0),
  entity_version bigint not null check (entity_version > 0),
  source_revision bigint not null check (source_revision >= 0),
  updated_at timestamptz not null,
  deleted_at timestamptz,
  primary key (restaurant_id, order_id),
  unique (restaurant_id, local_order_id),
  foreign key (restaurant_id, table_id)
    references nohut_private.pos_tables,
  check (closed_at is null or closed_at >= opened_at)
);
create index order_day_channel
  on nohut_private.orders(restaurant_id, business_day, channel);
create table nohut_private.order_batches (
  restaurant_id uuid not null,
  order_id uuid not null,
  batch_id uuid not null,
  employee_id uuid,
  staff_label_at_sale text,
  created_at timestamptz not null,
  entity_version bigint not null check (entity_version > 0),
  source_revision bigint not null check (source_revision >= 0),
  updated_at timestamptz not null,
  deleted_at timestamptz,
  primary key (restaurant_id, order_id, batch_id),
  foreign key (restaurant_id, order_id) references nohut_private.orders,
  foreign key (restaurant_id, employee_id) references nohut_private.employees
);
create table nohut_private.order_items (
  restaurant_id uuid not null,
  order_id uuid not null,
  batch_id uuid not null,
  item_id uuid not null,
  product_id uuid,
  product_version_id uuid,
  -- Retains custom or historical sale facts even after catalog changes.
  sale_label text not null,
  original_qty integer not null check (original_qty >= 0),
  qty integer not null check (qty >= 0),
  unit_price_kurus bigint not null check (unit_price_kurus >= 0),
  voided boolean not null default false,
  entity_version bigint not null check (entity_version > 0),
  source_revision bigint not null check (source_revision >= 0),
  updated_at timestamptz not null,
  deleted_at timestamptz,
  primary key (restaurant_id, order_id, batch_id, item_id),
  foreign key (restaurant_id, order_id, batch_id)
    references nohut_private.order_batches,
  foreign key (restaurant_id, product_id, product_version_id)
    references nohut_private.product_versions,
  check ((product_id is null) = (product_version_id is null))
);
create table nohut_private.payments (
  restaurant_id uuid not null,
  order_id uuid not null,
  payment_id uuid not null,
  method text not null check (method in ('nakit','kart','platform')),
  amount_kurus bigint not null check (amount_kurus > 0),
  received_kurus bigint check (received_kurus >= 0),
  change_kurus bigint check (change_kurus >= 0),
  employee_id uuid,
  recorded_at timestamptz not null,
  entity_version bigint not null check (entity_version > 0),
  source_revision bigint not null check (source_revision >= 0),
  updated_at timestamptz not null,
  deleted_at timestamptz,
  primary key (restaurant_id, order_id, payment_id),
  foreign key (restaurant_id, order_id) references nohut_private.orders,
  foreign key (restaurant_id, employee_id) references nohut_private.employees
);
create table nohut_private.payment_refunds (
  restaurant_id uuid not null,
  order_id uuid not null,
  payment_id uuid not null,
  refund_id uuid not null,
  amount_kurus bigint not null check (amount_kurus > 0),
  recorded_at timestamptz not null,
  entity_version bigint not null check (entity_version > 0),
  source_revision bigint not null check (source_revision >= 0),
  updated_at timestamptz not null,
  deleted_at timestamptz,
  primary key (restaurant_id, order_id, payment_id, refund_id),
  foreign key (restaurant_id, order_id, payment_id)
    references nohut_private.payments
);
create table nohut_private.platform_order_records (
  restaurant_id uuid not null,
  order_id uuid not null,
  platform text not null check (platform in ('trendyol','yemeksepeti','migros')),
  external_store_id text not null,
  external_order_id text not null,
  gross_kurus bigint,
  commission_kurus bigint,
  discount_kurus bigint,
  net_kurus bigint,
  status text not null,
  entity_version bigint not null check (entity_version > 0),
  source_revision bigint not null check (source_revision >= 0),
  updated_at timestamptz not null,
  deleted_at timestamptz,
  primary key (restaurant_id, platform, external_store_id, external_order_id),
  foreign key (restaurant_id, order_id) references nohut_private.orders
);

-- Fail closed: even authenticated users cannot read these tables yet.
-- FORCE RLS is not a defense against BYPASSRLS; never expose service_role.
do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'nohut_private' loop
    execute format('alter table nohut_private.%I enable row level security', t.tablename);
    execute format('alter table nohut_private.%I force row level security', t.tablename);
  end loop;
end $$;
revoke all on all tables in schema nohut_private from public, anon, authenticated, service_role;
revoke all on all sequences in schema nohut_private from public, anon, authenticated, service_role;
revoke all on all functions in schema nohut_private from public, anon, authenticated, service_role;
commit;
