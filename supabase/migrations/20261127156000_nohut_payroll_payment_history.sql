begin;
create table nohut_private.payroll_payments(
  restaurant_id uuid not null,payment_id uuid not null,source_reference text not null,
  employee_id uuid not null,employee_name_at_record text not null,
  week_start date not null check(extract(isodow from week_start)=1),paid_on date not null,
  kind text not null check(kind in ('Ödeme','Avans','Düzeltme')),
  method text not null check(method in ('Nakit','Havale/EFT','Karma')),
  cash_kurus bigint not null,bank_kurus bigint not null,amount_kurus bigint not null check(amount_kurus<>0),
  reverses_id uuid,note text not null,recorded_at timestamptz not null,actor_label text not null,
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,payment_id),unique(restaurant_id,source_reference),unique(restaurant_id,reverses_id),
  foreign key(restaurant_id,employee_id) references nohut_private.employees,
  foreign key(restaurant_id,reverses_id) references nohut_private.payroll_payments,
  check(cash_kurus::numeric+bank_kurus::numeric=amount_kurus),
  check((kind in ('Ödeme','Avans') and reverses_id is null and amount_kurus>0 and cash_kurus>=0 and bank_kurus>=0)
    or (kind='Düzeltme' and reverses_id is not null and amount_kurus<0 and cash_kurus<=0 and bank_kurus<=0 and length(trim(note))>0)),
  check((method='Nakit' and bank_kurus=0) or (method='Havale/EFT' and cash_kurus=0)
    or (method='Karma' and cash_kurus<>0 and bank_kurus<>0)),
  check(paid_on<=(recorded_at at time zone 'Europe/Istanbul')::date)
);
create table nohut_private.payroll_reviews(
  restaurant_id uuid not null,review_id uuid not null,employee_id uuid not null,
  week_start date not null check(extract(isodow from week_start)=1),state text not null check(state='Ödenmedi'),
  note text not null,recorded_at timestamptz not null,actor_label text not null,
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,review_id),unique(restaurant_id,employee_id,week_start,recorded_at),
  foreign key(restaurant_id,employee_id) references nohut_private.employees
);
do $$ declare t text; begin
  foreach t in array array['payroll_payments','payroll_reviews'] loop
    execute format('alter table nohut_private.%I enable row level security',t);
    execute format('alter table nohut_private.%I force row level security',t);
    execute format('create policy payroll_ledger_owner on nohut_private.%I for all to %I using(true) with check(true)',t,current_user);
    execute format('revoke all on nohut_private.%I from public,anon,authenticated,service_role',t);
  end loop;
end $$;
commit;
