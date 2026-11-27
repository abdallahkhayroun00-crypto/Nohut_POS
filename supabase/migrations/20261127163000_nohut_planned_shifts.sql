begin;
create table nohut_private.shift_plans(
  restaurant_id uuid not null,plan_id text not null check(length(plan_id) between 1 and 160),
  employee_id uuid not null,employee_label text not null,
  planned_day date not null,start_minute integer not null check(start_minute between 0 and 1439),
  end_minute integer not null check(end_minute between 0 and 1439),ends_next_day boolean not null,
  day_off boolean not null,break_minutes integer not null check(break_minutes between 0 and 600),note text not null,
  cancelled boolean not null,created_at timestamptz not null,created_by_label text not null,
  local_updated_at timestamptz not null,updated_by_label text not null,source_revision bigint not null check(source_revision>=0),
  primary key(restaurant_id,plan_id),foreign key(restaurant_id,employee_id) references nohut_private.employees,
  check((day_off and start_minute=0 and end_minute=0 and not ends_next_day and break_minutes=0)
    or (not day_off and ends_next_day=(end_minute<=start_minute)
      and end_minute-start_minute+case when ends_next_day then 1440 else 0 end between 1 and 960
      and break_minutes<end_minute-start_minute+case when ends_next_day then 1440 else 0 end))
);
create table nohut_private.shift_plan_history(
  restaurant_id uuid not null,plan_id text not null,ordinal integer not null check(ordinal>=0),
  recorded_at timestamptz not null,actor_employee_id uuid,actor_label text not null,action text not null check(action in ('düzenlendi','iptal')),
  before_day date,before_start_minute integer,before_end_minute integer,before_ends_next_day boolean,
  before_day_off boolean,before_break_minutes integer,before_note text,
  primary key(restaurant_id,plan_id,ordinal),foreign key(restaurant_id,plan_id) references nohut_private.shift_plans,
  foreign key(restaurant_id,actor_employee_id) references nohut_private.employees,
  check((action='düzenlendi' and before_day is not null and before_start_minute is not null and before_end_minute is not null
    and before_ends_next_day is not null and before_day_off is not null and before_break_minutes is not null and before_note is not null)
    or (action='iptal' and before_day is null and before_start_minute is null and before_end_minute is null
      and before_ends_next_day is null and before_day_off is null and before_break_minutes is null and before_note is null))
);
do $$ declare t text; begin
  foreach t in array array['shift_plans','shift_plan_history'] loop
    execute format('alter table nohut_private.%I enable row level security',t);
    execute format('alter table nohut_private.%I force row level security',t);
    execute format('create policy planned_shift_owner on nohut_private.%I for all to %I using(true) with check(true)',t,current_user);
    execute format('revoke all on nohut_private.%I from public,anon,authenticated,service_role',t);
  end loop;
end $$;
commit;
