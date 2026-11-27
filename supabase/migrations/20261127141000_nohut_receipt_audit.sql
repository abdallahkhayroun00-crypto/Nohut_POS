begin;
create table nohut_private.receipt_snapshots(
  restaurant_id uuid not null,order_id uuid not null,snapshot_id uuid not null,
  schema_version integer not null check(schema_version=1),receipt_kind text not null check(receipt_kind in ('kitchen','payment')),
  source_format text not null check(source_format in ('frozen_kitchen','payment_text')),
  body text not null check(length(body)<=65536),privacy text not null check(privacy='customer_contact_redacted'),
  content_sha256 text not null check(content_sha256 ~ '^[0-9a-f]{64}$'),
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,snapshot_id),unique(restaurant_id,order_id,snapshot_id),
  foreign key(restaurant_id,order_id) references nohut_private.orders
);
create table nohut_private.print_jobs(
  restaurant_id uuid not null,order_id uuid not null,job_id uuid not null,snapshot_id uuid not null,
  source_key text not null,batch_local_id bigint not null,local_kind text,receipt_request_id text,receipt_kind text not null,
  status text not null check(status in ('queued','dispatching','spooled','ambiguous','cancelled','skipped')),
  attempts bigint not null check(attempts>=0),created_at timestamptz not null,spooled_at timestamptz,
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,job_id),unique(restaurant_id,source_key),unique(restaurant_id,order_id,job_id),
  foreign key(restaurant_id,order_id,snapshot_id) references nohut_private.receipt_snapshots(restaurant_id,order_id,snapshot_id)
);
create table nohut_private.print_job_events(
  restaurant_id uuid not null,order_id uuid not null,job_id uuid not null,event_id uuid not null,
  ordinal bigint not null check(ordinal>=0),observed_at timestamptz not null,origin text not null check(origin in ('created','legacy_current','transition')),
  status text not null check(status in ('queued','dispatching','spooled','ambiguous','cancelled','skipped')),
  attempts bigint not null check(attempts>=0),spooled_at timestamptz,
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,job_id,event_id),unique(restaurant_id,event_id),unique(restaurant_id,job_id,ordinal),
  foreign key(restaurant_id,order_id,job_id) references nohut_private.print_jobs(restaurant_id,order_id,job_id)
);
do $$ declare t text; begin
  foreach t in array array['receipt_snapshots','print_jobs','print_job_events'] loop
    execute format('alter table nohut_private.%I enable row level security',t);
    execute format('alter table nohut_private.%I force row level security',t);
    execute format('create policy receipt_rpc_owner on nohut_private.%I for all to %I using (true) with check (true)',t,current_user);
    execute format('revoke all on nohut_private.%I from public,anon,authenticated,service_role',t);
  end loop;
end $$;
commit;
