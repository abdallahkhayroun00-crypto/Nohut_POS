\set ON_ERROR_STOP on
begin;
do $$
declare r uuid:=gen_random_uuid(); p jsonb; edit jsonb; bad jsonb;
begin
  insert into nohut_private.restaurants(restaurant_id) values(r);
  perform nohut_private.apply_employee_projection(r,1,'[{"id":2,"name":"Synthetic staff","active":true}]');
  p:='[{"id":"vp_synthetic_0","employeeId":2,"employeeName":"Synthetic staff","date":"2026-11-27","start":"22:00","end":"06:00","endsNextDay":true,"dayOff":false,"breakMinutes":60,"note":"Synthetic plan","cancelled":false,"createdAt":"2026-11-26T10:00:00Z","createdBy":"Synthetic staff","updatedAt":"2026-11-26T10:00:00Z","updatedBy":"Synthetic staff","history":[]}]';
  perform nohut_private.apply_plan_projection(r,2,p);
  perform nohut_private.apply_plan_projection(r,3,p);
  edit:=jsonb_set(jsonb_set(jsonb_set(p,'{0,end}','"07:00"'),'{0,breakMinutes}','30'),'{0,updatedAt}','"2026-11-26T11:00:00Z"');
  edit:=jsonb_set(edit,'{0,history}','[{"at":"2026-11-26T11:00:00Z","byId":2,"by":"Synthetic staff","action":"düzenlendi","before":{"date":"2026-11-27","start":"22:00","end":"06:00","endsNextDay":true,"dayOff":false,"breakMinutes":60,"note":"Synthetic plan"}}]');
  perform nohut_private.apply_plan_projection(r,4,edit);
  if (select end_minute from nohut_private.shift_plans where restaurant_id=r)<>420
    or (select before_break_minutes from nohut_private.shift_plan_history where restaurant_id=r)<>60
    or exists(select 1 from nohut_private.shifts where restaurant_id=r) then raise exception 'planned/actual separation lost'; end if;
  foreach bad in array array[
    '[]'::jsonb,
    jsonb_set(edit,'{0,breakMinutes}','31'),
    jsonb_set(edit,'{0,history,0,before,breakMinutes}','59'),
    jsonb_set(edit,'{0,history}','[]'),
    jsonb_set(edit,'{0,createdBy}','"forged"'),
    jsonb_set(edit,'{0,employeeId}','999'),
    jsonb_set(edit,'{0,cancelled}','true')
  ] loop
    begin perform nohut_private.apply_plan_projection(r,5,bad);raise exception 'invalid plan accepted';exception when invalid_parameter_value then null;end;
  end loop;
  edit:=jsonb_set(edit,'{0,history}',(edit#>'{0,history}')||'[{"at":"2026-11-26T12:00:00Z","byId":2,"by":"Synthetic staff","action":"iptal"}]'::jsonb);
  edit:=jsonb_set(jsonb_set(edit,'{0,cancelled}','true'),'{0,updatedAt}','"2026-11-26T12:00:00Z"');
  perform nohut_private.apply_plan_projection(r,5,edit);
  begin perform nohut_private.apply_plan_projection(r,6,jsonb_set(edit,'{0,cancelled}','false'));
    raise exception 'cancelled plan restored'; exception when invalid_parameter_value then null; end;
  if (select count(*) from nohut_private.shift_plan_history where restaurant_id=r)<>2 then raise exception 'plan audit lost';end if;
end $$;
set local role authenticated;
do $$ begin
  begin perform 1 from nohut_private.shift_plans;raise exception 'client read private plans';exception when insufficient_privilege then null;end;
end $$;
reset role;
rollback;
