begin;
create table nohut_private.combined_payment_groups(
  restaurant_id uuid not null,group_id uuid not null,source_reference text not null,method text not null check(method in ('cash','card','mixed')),
  amount_kurus bigint not null check(amount_kurus>0),cash_kurus bigint not null check(cash_kurus>=0),card_kurus bigint not null check(card_kurus>=0),
  received_kurus bigint,recorded_at timestamptz not null,order_count bigint not null check(order_count>0),
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,group_id),unique(restaurant_id,source_reference)
);
create table nohut_private.combined_payment_members(
  restaurant_id uuid not null,group_id uuid not null,order_id uuid not null,ordinal bigint not null check(ordinal>=0),
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,group_id,order_id),unique(restaurant_id,group_id,ordinal),
  foreign key(restaurant_id,group_id) references nohut_private.combined_payment_groups,
  foreign key(restaurant_id,order_id) references nohut_private.orders
);
create table nohut_private.terminal_attempts(
  restaurant_id uuid not null,attempt_id uuid not null,source_reference text not null,order_id uuid not null,local_order_id bigint not null,
  amount_kurus bigint not null check(amount_kurus>0),status text not null check(status in ('waiting','unknown','approved','declined','cancelled')),
  dispatched boolean not null,transaction_id text,first_observed_at timestamptz not null,last_observed_at timestamptz not null,event_count bigint not null check(event_count>0),
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,attempt_id),unique(restaurant_id,source_reference),unique(restaurant_id,transaction_id),
  foreign key(restaurant_id,order_id) references nohut_private.orders
);
create table nohut_private.terminal_attempt_events(
  restaurant_id uuid not null,attempt_id uuid not null,event_id uuid not null,ordinal bigint not null check(ordinal>=0),observed_at timestamptz not null,
  origin text not null check(origin in ('created','legacy_current','transition')),status text not null check(status in ('waiting','unknown','approved','declined','cancelled')),
  dispatched boolean not null,transaction_id text,
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,event_id),unique(restaurant_id,attempt_id,ordinal),foreign key(restaurant_id,attempt_id) references nohut_private.terminal_attempts
);
create table nohut_private.cash_sessions(
  restaurant_id uuid not null,session_id uuid not null,local_id bigint not null,opened_at timestamptz not null,opened_by text not null,opening_kurus bigint not null check(opening_kurus>=0),
  closed_at timestamptz,closed_by text,counted_kurus bigint check(counted_kurus>=0),expected_kurus bigint,difference_kurus bigint,
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,session_id),unique(restaurant_id,local_id)
);
create table nohut_private.cash_movements(
  restaurant_id uuid not null,movement_id uuid not null,session_id uuid not null,amount_kurus bigint not null check(amount_kurus<>0),
  note text not null,recorded_at timestamptz not null,actor_label text not null,
  entity_version bigint not null,source_revision bigint not null,updated_at timestamptz not null,deleted_at timestamptz,
  primary key(restaurant_id,movement_id),foreign key(restaurant_id,session_id) references nohut_private.cash_sessions
);
alter table nohut_private.payments add foreign key(restaurant_id,combined_payment_id)
  references nohut_private.combined_payment_groups(restaurant_id,source_reference) deferrable initially deferred;
alter table nohut_private.payments add foreign key(restaurant_id,terminal_reference)
  references nohut_private.terminal_attempts(restaurant_id,source_reference) deferrable initially deferred;
do $$ declare t text;begin
  foreach t in array array['combined_payment_groups','combined_payment_members','terminal_attempts','terminal_attempt_events','cash_sessions','cash_movements'] loop
    execute format('alter table nohut_private.%I enable row level security',t);
    execute format('alter table nohut_private.%I force row level security',t);
    execute format('create policy payment_ledger_owner on nohut_private.%I for all to %I using (true) with check (true)',t,current_user);
    execute format('revoke all on nohut_private.%I from public,anon,authenticated,service_role',t);
  end loop;
end $$;
commit;
