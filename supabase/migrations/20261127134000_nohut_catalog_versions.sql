begin;
alter table nohut_private.products add column local_id bigint, add column source_kind text,
  add column current_version_id uuid;
alter table nohut_private.products add constraint current_product_version foreign key(restaurant_id,product_id,current_version_id)
  references nohut_private.product_versions(restaurant_id,product_id,product_version_id) deferrable initially deferred;
alter table nohut_private.product_versions
  add column category_key text, add column description_tr text, add column description_en text, add column description_ar text,
  add column display_name_tr text, add column display_name_en text, add column display_name_ar text,
  add column image_path text, add column active boolean not null default true,
  add column available boolean not null default true, add column internal_only boolean not null default false;

create table nohut_private.categories(
  restaurant_id uuid not null references nohut_private.restaurants, category_id uuid not null,
  local_key text not null, current_version_id uuid not null,
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,category_id),unique(restaurant_id,local_key)
);
create table nohut_private.category_versions(
  restaurant_id uuid not null,category_id uuid not null,category_version_id uuid not null,
  label_tr text not null,label_en text,label_ar text,description_tr text,description_en text,description_ar text,
  active boolean not null,sort_order integer not null,content_sha256 text not null check(content_sha256~'^[0-9a-f]{64}$'),
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,category_id,category_version_id),
  foreign key(restaurant_id,category_id) references nohut_private.categories
);
alter table nohut_private.categories add foreign key(restaurant_id,category_id,current_version_id)
  references nohut_private.category_versions(restaurant_id,category_id,category_version_id) deferrable initially deferred;
create table nohut_private.campaigns(
  restaurant_id uuid not null references nohut_private.restaurants,campaign_id uuid not null,
  local_key text not null,current_version_id uuid not null,
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,campaign_id),unique(restaurant_id,local_key)
);
create table nohut_private.campaign_versions(
  restaurant_id uuid not null,campaign_id uuid not null,campaign_version_id uuid not null,
  label_tr text not null,label_en text,label_ar text,description_tr text,description_en text,description_ar text,
  price_kurus bigint not null check(price_kurus>=0),active boolean not null,
  starts_at timestamptz,ends_at timestamptz,poster_path text,thumbnail_path text,
  items jsonb not null check(jsonb_typeof(items)='array'),
  content_sha256 text not null check(content_sha256~'^[0-9a-f]{64}$'),
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,campaign_id,campaign_version_id),
  foreign key(restaurant_id,campaign_id) references nohut_private.campaigns,
  check(ends_at is null or starts_at is null or ends_at>=starts_at)
);
alter table nohut_private.campaigns add foreign key(restaurant_id,campaign_id,current_version_id)
  references nohut_private.campaign_versions(restaurant_id,campaign_id,campaign_version_id) deferrable initially deferred;
do $$ declare t text; begin
  foreach t in array array['categories','category_versions','campaigns','campaign_versions'] loop
    execute format('alter table nohut_private.%I enable row level security',t);
    execute format('alter table nohut_private.%I force row level security',t);
    execute format('create policy catalog_rpc_owner on nohut_private.%I for all to %I using (true) with check (true)',t,current_user);
    execute format('revoke all on nohut_private.%I from public,anon,authenticated,service_role',t);
  end loop;
end $$;
commit;
