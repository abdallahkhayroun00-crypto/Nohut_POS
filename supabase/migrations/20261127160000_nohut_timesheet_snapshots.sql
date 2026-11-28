begin;
create table nohut_private.timesheet_weeks(
  restaurant_id uuid not null,week_id text not null,employee_id uuid not null,employee_label text not null,
  week_start date not null check(extract(isodow from week_start)=1),
  submitted_at timestamptz not null,no_work boolean not null,minutes bigint not null check(minutes>=0),
  source_revision bigint not null check(source_revision>=0),
  primary key(restaurant_id,week_id),unique(restaurant_id,employee_id,week_start),
  foreign key(restaurant_id,employee_id) references nohut_private.employees
);
create table nohut_private.timesheet_submissions(
  restaurant_id uuid not null,week_id text not null,ordinal integer not null check(ordinal>=0),
  submitted_at timestamptz not null,no_work boolean not null,minutes bigint not null check(minutes>=0),
  primary key(restaurant_id,week_id,ordinal),foreign key(restaurant_id,week_id) references nohut_private.timesheet_weeks
);
create table nohut_private.timesheet_entries(
  restaurant_id uuid not null,week_id text not null,submission_ordinal integer not null,entry_ordinal integer not null check(entry_ordinal>=0),
  shift_id text not null,started_at timestamptz not null,ended_at timestamptz not null,
  break_minutes integer not null check(break_minutes between 0 and 600),
  primary key(restaurant_id,week_id,submission_ordinal,shift_id),unique(restaurant_id,week_id,submission_ordinal,entry_ordinal),
  foreign key(restaurant_id,week_id,submission_ordinal) references nohut_private.timesheet_submissions,
  foreign key(restaurant_id,shift_id) references nohut_private.shifts,
  check(ended_at>=started_at and break_minutes<=floor(extract(epoch from ended_at-started_at)/60))
);
do $$ declare t text; begin
  foreach t in array array['timesheet_weeks','timesheet_submissions','timesheet_entries'] loop
    execute format('alter table nohut_private.%I enable row level security',t);
    execute format('alter table nohut_private.%I force row level security',t);
    execute format('create policy timesheet_owner on nohut_private.%I for all to %I using(true) with check(true)',t,current_user);
    execute format('revoke all on nohut_private.%I from public,anon,authenticated,service_role',t);
  end loop;
end $$;
commit;
