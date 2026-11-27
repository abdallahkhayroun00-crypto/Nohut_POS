\set ON_ERROR_STOP on
begin;
do $$
declare r uuid:=gen_random_uuid(); other_r uuid:=gen_random_uuid(); eid uuid; p jsonb; bad jsonb;
begin
  insert into nohut_private.restaurants(restaurant_id) values(r),(other_r);
  p:='[{"id":1,"name":"Synthetic owner","active":true,"payrollEligible":false},
    {"id":2,"name":"Synthetic staff","active":true,"payType":"Saatlik","payRateCents":12000,"payHistory":[
      {"effectiveFrom":"2026-11-23","payType":"Saatlik","rateCents":10000,"setAt":"2026-11-22T20:00:00Z","setBy":"Synthetic manager"},
      {"effectiveFrom":"2026-11-25","payType":"Saatlik","rateCents":12000,"setAt":"2026-11-24T20:00:00Z","setBy":"Synthetic manager"}]}]';
  perform nohut_private.apply_employee_projection(r,1,p);
  select employee_id into eid from nohut_private.employee_source_ids where restaurant_id=r and local_id=2;
  if (select payroll_eligible from nohut_private.employees where restaurant_id=r and employee_id=eid) is not true
    or (select count(*) from nohut_private.employee_wage_history where restaurant_id=r)<>2
    or (select payroll_eligible from nohut_private.employees where restaurant_id=r and display_name='Synthetic owner') is not false then
    raise exception 'eligibility/history lost'; end if;
  -- Same local IDs in another tenant map to different employee identities.
  perform nohut_private.apply_employee_projection(other_r,1,p);
  if exists(select 1 from nohut_private.employee_source_ids where restaurant_id=other_r and employee_id=eid) then
    raise exception 'cross tenant wage identity'; end if;
  perform nohut_private.apply_employee_projection(r,2,p);
  foreach bad in array array[
    jsonb_set(p,'{0,payrollEligible}','"false"'),
    jsonb_set(p,'{1,payRateCents}','12000.5'),
    jsonb_set(p,'{1,payHistory,0,rateCents}','11000'),
    jsonb_set(p,'{1,payHistory,0,setBy}','"forged"'),
    jsonb_set(p,'{1,payHistory}','[]'),
    jsonb_set(p,'{1,payHistory,0,deviceSecret}','"never allowed"')
  ] loop
    begin
      perform nohut_private.apply_employee_projection(r,3,bad);
      raise exception 'invalid wage accepted';
    exception when invalid_parameter_value then null; end;
  end loop;
  if (select source_revision from nohut_private.employees where restaurant_id=r and employee_id=eid)<>2 then
    raise exception 'partial employee transaction'; end if;
  -- An explicit later owner choice is retained; departed employees keep rates.
  p:=jsonb_set(jsonb_set(p,'{0,payrollEligible}','true'),'{1,active}','false');
  perform nohut_private.apply_employee_projection(r,3,p);
  if (select count(*) from nohut_private.employee_wage_history where restaurant_id=r)<>2
    or (select payroll_eligible from nohut_private.employees where restaurant_id=r and display_name='Synthetic owner') is not true then
    raise exception 'explicit choice or departed wage history lost'; end if;
  if has_table_privilege('authenticated','nohut_private.employee_wage_history','select,insert,update,delete')
    or has_table_privilege('service_role','nohut_private.employee_wage_history','select,insert,update,delete') then
    raise exception 'wage data grant leaked'; end if;
end $$;
set local role authenticated;
do $$ begin
  begin perform 1 from nohut_private.employee_wage_history; raise exception 'client read salaries';
    exception when insufficient_privilege then null; end;
end $$;
reset role;
rollback;
