-- Phase 2: finance source facts, isolated from client access.
-- Based on finance_logic.dart; not a complete serialization contract.
begin;
create table nohut_private.material_purchases (
  restaurant_id uuid not null references nohut_private.restaurants,
  purchase_id uuid not null,
  local_id bigint not null,
  business_day date not null,
  title text not null,
  record_type text not null check (record_type in ('detailed','quick')),
  unit text,
  quantity_milli bigint check (quantity_milli > 0),
  unit_price_kurus bigint check (unit_price_kurus >= 0),
  subtotal_kurus bigint check (subtotal_kurus >= 0),
  discount_kurus bigint check (discount_kurus >= 0),
  total_kurus bigint not null check (total_kurus >= 0),
  store_brand text,
  payment_method text not null,
  voided boolean not null default false,
  created_at timestamptz not null,
  entity_version bigint not null check (entity_version > 0),
  source_revision bigint not null check (source_revision >= 0),
  updated_at timestamptz not null,
  deleted_at timestamptz,
  primary key (restaurant_id,purchase_id),
  unique (restaurant_id,local_id),
  check (record_type <> 'detailed' or (quantity_milli is not null and unit_price_kurus is not null and unit is not null))
);
create table nohut_private.material_purchase_history (
  restaurant_id uuid not null,
  purchase_id uuid not null,
  history_id uuid not null,
  changed_at timestamptz not null,
  previous_total_kurus bigint not null check (previous_total_kurus >= 0),
  previous_discount_kurus bigint check (previous_discount_kurus >= 0),
  previous_unit_price_kurus bigint check (previous_unit_price_kurus >= 0),
  previous_quantity_milli bigint check (previous_quantity_milli > 0),
  entity_version bigint not null check (entity_version > 0),
  source_revision bigint not null check (source_revision >= 0),
  updated_at timestamptz not null,
  deleted_at timestamptz,
  primary key (restaurant_id,purchase_id,history_id),
  foreign key (restaurant_id,purchase_id) references nohut_private.material_purchases
);
create table nohut_private.expenses (
  restaurant_id uuid not null references nohut_private.restaurants,
  expense_id uuid not null,
  local_id bigint not null,
  business_day date not null,
  category text not null,
  label text not null,
  amount_kurus bigint not null check (amount_kurus > 0),
  payment_method text not null,
  voided boolean not null default false,
  voided_at timestamptz,
  created_at timestamptz not null,
  entity_version bigint not null check (entity_version > 0),
  source_revision bigint not null check (source_revision >= 0),
  updated_at timestamptz not null,
  deleted_at timestamptz,
  primary key (restaurant_id,expense_id),
  unique (restaurant_id,local_id)
);
create table nohut_private.fixed_expenses (
  restaurant_id uuid not null references nohut_private.restaurants,
  fixed_expense_id uuid not null,
  local_id bigint not null,
  category text not null,
  label text not null,
  amount_kurus bigint not null check (amount_kurus > 0),
  start_month date not null check (extract(day from start_month)=1),
  due_day smallint not null check (due_day between 1 and 28),
  active boolean not null,
  created_at timestamptz not null,
  entity_version bigint not null check (entity_version > 0),
  source_revision bigint not null check (source_revision >= 0),
  updated_at timestamptz not null,
  deleted_at timestamptz,
  primary key (restaurant_id,fixed_expense_id),
  unique (restaurant_id,local_id)
);
create table nohut_private.fixed_expense_active_ranges (
  restaurant_id uuid not null,
  fixed_expense_id uuid not null,
  from_month date not null check (extract(day from from_month)=1),
  to_month date check (extract(day from to_month)=1),
  entity_version bigint not null check (entity_version > 0),
  source_revision bigint not null check (source_revision >= 0),
  updated_at timestamptz not null,
  deleted_at timestamptz,
  primary key (restaurant_id,fixed_expense_id,from_month),
  foreign key (restaurant_id,fixed_expense_id) references nohut_private.fixed_expenses,
  check (to_month is null or to_month >= from_month)
);
create table nohut_private.fixed_expense_amount_history (
  restaurant_id uuid not null,
  fixed_expense_id uuid not null,
  from_month date not null check (extract(day from from_month)=1),
  amount_kurus bigint not null check (amount_kurus > 0),
  entity_version bigint not null check (entity_version > 0),
  source_revision bigint not null check (source_revision >= 0),
  updated_at timestamptz not null,
  deleted_at timestamptz,
  primary key (restaurant_id,fixed_expense_id,from_month),
  foreign key (restaurant_id,fixed_expense_id) references nohut_private.fixed_expenses
);
create table nohut_private.fixed_expense_payments (
  restaurant_id uuid not null,
  fixed_expense_id uuid not null,
  payment_month date not null check (extract(day from payment_month)=1),
  amount_kurus bigint not null check (amount_kurus > 0),
  paid_at timestamptz not null,
  entity_version bigint not null check (entity_version > 0),
  source_revision bigint not null check (source_revision >= 0),
  updated_at timestamptz not null,
  deleted_at timestamptz,
  primary key (restaurant_id,fixed_expense_id,payment_month),
  foreign key (restaurant_id,fixed_expense_id) references nohut_private.fixed_expenses
);
-- Weekly payroll is the existing local financial fact. Do not invent
-- individual advance payments or clock events from these aggregate amounts.
create table nohut_private.weekly_payroll (
  restaurant_id uuid not null,
  payroll_id uuid not null,
  local_id bigint not null,
  employee_id uuid not null,
  employee_name_at_record text not null,
  week_start date not null,
  week_end date not null,
  pay_type text not null check (pay_type in ('hourly','weekly_fixed')),
  rate_kurus bigint not null check (rate_kurus > 0),
  worked_minutes integer not null check (worked_minutes between 0 and 10080),
  base_kurus bigint not null check (base_kurus >= 0),
  bonus_kurus bigint not null check (bonus_kurus >= 0),
  advance_kurus bigint not null check (advance_kurus >= 0),
  gross_kurus bigint not null check (gross_kurus > 0),
  payable_kurus bigint not null check (payable_kurus >= 0),
  paid boolean not null,
  paid_at timestamptz,
  created_at timestamptz not null,
  entity_version bigint not null check (entity_version > 0),
  source_revision bigint not null check (source_revision >= 0),
  updated_at timestamptz not null,
  deleted_at timestamptz,
  primary key (restaurant_id,payroll_id),
  unique (restaurant_id,local_id),
  unique (restaurant_id,employee_id,week_start),
  foreign key (restaurant_id,employee_id) references nohut_private.employees,
  check (week_end = week_start + 6),
  check (gross_kurus = base_kurus + bonus_kurus),
  check (payable_kurus = gross_kurus - advance_kurus),
  check (paid = (paid_at is not null))
);
create table nohut_private.manual_platform_sales (
  restaurant_id uuid not null references nohut_private.restaurants,
  sale_id uuid not null,
  local_id bigint not null,
  platform text not null check (platform in ('yemeksepeti','migros')),
  sales_month date not null check (extract(day from sales_month)=1),
  amount_kind text not null check (amount_kind in ('gross','net')),
  amount_kurus bigint not null check (amount_kurus > 0),
  voided boolean not null default false,
  created_at timestamptz not null,
  entity_version bigint not null check (entity_version > 0),
  source_revision bigint not null check (source_revision >= 0),
  updated_at timestamptz not null,
  deleted_at timestamptz,
  primary key (restaurant_id,sale_id),
  unique (restaurant_id,local_id)
);
create unique index manual_platform_one_active_month
  on nohut_private.manual_platform_sales(restaurant_id,platform,sales_month)
  where not voided and deleted_at is null;
create table nohut_private.manual_platform_sales_history (
  restaurant_id uuid not null,
  sale_id uuid not null,
  history_id uuid not null,
  changed_at timestamptz not null,
  amount_kind text not null check (amount_kind in ('gross','net')),
  amount_kurus bigint not null check (amount_kurus > 0),
  entity_version bigint not null check (entity_version > 0),
  source_revision bigint not null check (source_revision >= 0),
  updated_at timestamptz not null,
  deleted_at timestamptz,
  primary key (restaurant_id,sale_id,history_id),
  foreign key (restaurant_id,sale_id) references nohut_private.manual_platform_sales
);
create index material_day on nohut_private.material_purchases(restaurant_id,business_day);
create index expense_day on nohut_private.expenses(restaurant_id,business_day);
-- No direct application access, even to payroll; scoped RPC and owner/self
-- authorization must be built and tested before enabling any cloud reads.
do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname='nohut_private' loop
    execute format('alter table nohut_private.%I enable row level security',t.tablename);
    execute format('alter table nohut_private.%I force row level security',t.tablename);
  end loop;
end $$;
revoke all on all tables in schema nohut_private from public, anon, authenticated, service_role;
commit;
