-- QA-09 / spec 24.5: business facts only, never authorization or login data.
begin;
alter table nohut_private.employees
  add column payroll_eligible boolean not null default true,
  add column pay_type text check(pay_type in ('Saatlik','Haftalık Sabit')),
  add column pay_rate_kurus bigint check(pay_rate_kurus>0 and pay_rate_kurus<=9007199254740991);
create table nohut_private.employee_wage_history(
  restaurant_id uuid not null,
  employee_id uuid not null,
  effective_from date not null,
  set_at timestamptz not null,
  pay_type text not null check(pay_type in ('Saatlik','Haftalık Sabit')),
  rate_kurus bigint not null check(rate_kurus>0 and rate_kurus<=9007199254740991),
  actor_label text not null,
  source_revision bigint not null check(source_revision>=0),
  primary key(restaurant_id,employee_id,effective_from,set_at),
  foreign key(restaurant_id,employee_id) references nohut_private.employees
);
alter table nohut_private.employee_wage_history enable row level security;
alter table nohut_private.employee_wage_history force row level security;
do $$ begin
  execute format('create policy wage_owner on nohut_private.employee_wage_history for all to %I using(true) with check(true)',current_user);
end $$;
revoke all on nohut_private.employee_wage_history from public,anon,authenticated,service_role;

alter function nohut_private.apply_employee_projection(uuid,bigint,jsonb) rename to apply_employee_projection_v1;
create function nohut_private.apply_employee_projection(p_restaurant uuid,p_revision bigint,p_rows jsonb)
returns void language plpgsql security invoker set search_path='' as $$
declare row_data jsonb; base_rows jsonb; h jsonb; eid uuid; prior nohut_private.employee_wage_history;
  day date; instant timestamptz; key text; seen text[];
begin
  if jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'employees core must be an array' using errcode='22023'; end if;
  select coalesce(jsonb_agg(x-array['payrollEligible','payType','payRateCents','payHistory']),'[]') into base_rows
    from jsonb_array_elements(p_rows) x;
  perform nohut_private.apply_employee_projection_v1(p_restaurant,p_revision,base_rows);
  for row_data in select value from jsonb_array_elements(p_rows) loop
    if (row_data ? 'payrollEligible' and jsonb_typeof(row_data->'payrollEligible')<>'boolean')
      or (row_data->'payType'<>'null'::jsonb and row_data->>'payType' not in ('Saatlik','Haftalık Sabit'))
      or (row_data->'payRateCents'<>'null'::jsonb and
        (jsonb_typeof(row_data->'payRateCents')<>'number' or row_data->>'payRateCents' !~ '^[1-9][0-9]*$'
          or (row_data->>'payRateCents')::numeric>9007199254740991)) then
      raise exception 'invalid employee payroll facts' using errcode='22023'; end if;
    select employee_id into strict eid from nohut_private.employee_source_ids
      where restaurant_id=p_restaurant and local_id=(row_data->>'id')::bigint;
    update nohut_private.employees set payroll_eligible=coalesce((row_data->>'payrollEligible')::boolean,true),
      pay_type=row_data->>'payType',pay_rate_kurus=(row_data->>'payRateCents')::bigint
      where restaurant_id=p_restaurant and employee_id=eid;
    h:=coalesce(row_data->'payHistory','[]');
    if jsonb_typeof(h)<>'array' then raise exception 'wage history array required' using errcode='22023'; end if;
    seen:=array[]::text[];
    for h in select value from jsonb_array_elements(h) loop
      if jsonb_typeof(h)<>'object' or
        (select array_agg(k order by k) from jsonb_object_keys(h) k) is distinct from
          array['effectiveFrom','payType','rateCents','setAt','setBy']::text[]
        or jsonb_typeof(h->'effectiveFrom')<>'string' or h->>'effectiveFrom' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
        or jsonb_typeof(h->'payType')<>'string' or h->>'payType' not in ('Saatlik','Haftalık Sabit')
        or jsonb_typeof(h->'rateCents')<>'number' or h->>'rateCents' !~ '^[1-9][0-9]*$'
        or (h->>'rateCents')::numeric>9007199254740991 or jsonb_typeof(h->'setBy')<>'string' then
        raise exception 'invalid wage history' using errcode='22023'; end if;
      day:=(h->>'effectiveFrom')::date;
      instant:=nohut_private.shift_timestamp(h->'setAt');
      if instant is null then raise exception 'wage timestamp required' using errcode='22023'; end if;
      key:=day::text||':'||instant::text;
      if key=any(seen) then raise exception 'duplicate wage identity' using errcode='22023'; end if;
      seen:=array_append(seen,key);
      select * into prior from nohut_private.employee_wage_history where restaurant_id=p_restaurant
        and employee_id=eid and effective_from=day and set_at=instant for update;
      if found then
        if prior.pay_type is distinct from h->>'payType' or prior.rate_kurus is distinct from (h->>'rateCents')::bigint
          or prior.actor_label is distinct from h->>'setBy' then
          raise exception 'immutable wage history changed' using errcode='22023'; end if;
      else
        insert into nohut_private.employee_wage_history values
          (p_restaurant,eid,day,instant,h->>'payType',(h->>'rateCents')::bigint,h->>'setBy',p_revision);
      end if;
    end loop;
    if exists(select 1 from nohut_private.employee_wage_history where restaurant_id=p_restaurant and employee_id=eid
      and not((effective_from::text||':'||set_at::text)=any(seen))) then
      raise exception 'wage history omitted' using errcode='22023'; end if;
  end loop;
end $$;
revoke all on function nohut_private.apply_employee_projection_v1(uuid,bigint,jsonb) from public,anon,authenticated,service_role;
revoke all on function nohut_private.apply_employee_projection(uuid,bigint,jsonb) from public,anon,authenticated,service_role;
commit;
