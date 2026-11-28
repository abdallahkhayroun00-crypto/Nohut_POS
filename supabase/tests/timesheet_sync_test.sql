\set ON_ERROR_STOP on
begin;
do $$
declare r uuid:=gen_random_uuid(); w jsonb; bad jsonb; shifts jsonb;
begin
  insert into nohut_private.restaurants(restaurant_id) values(r);
  perform nohut_private.apply_employee_projection(r,1,'[{"id":2,"name":"Synthetic staff","active":true}]');
  shifts:='[{"id":"mw_synthetic","employeeId":2,"employeeName":"Synthetic staff","source":"manual","start":"2026-11-23T06:00:00Z","end":"2026-11-23T15:00:00Z","breakMinutes":60,"createdAt":"2026-11-24T10:00:00Z","updatedAt":"2026-11-24T10:00:00Z","corrections":[]}]';
  perform nohut_private.apply_shift_projection(r,2,shifts);
  w:='[{"id":"tw_2_2026-11-23","employeeId":2,"employeeName":"Synthetic staff","weekStart":"2026-11-23","submittedAt":"2026-11-24T12:00:00Z","minutes":480,"noWork":false,"history":[{"at":"2026-11-24T12:00:00Z","minutes":480,"noWork":false,"entries":[{"id":"mw_synthetic","start":"2026-11-23T06:00:00Z","end":"2026-11-23T15:00:00Z","breakMinutes":60}]}]}]';
  perform nohut_private.apply_timesheet_projection(r,3,w);
  perform nohut_private.apply_timesheet_projection(r,4,w);
  foreach bad in array array[
    '[]'::jsonb,
    jsonb_set(w,'{0,minutes}','481'),
    jsonb_set(w,'{0,history}','[]'),
    jsonb_set(w,'{0,history,0,entries}','[]'),
    jsonb_set(w,'{0,history,0,entries,0,breakMinutes}','59'),
    jsonb_set(w,'{0,employeeId}','999'),
    jsonb_set(w,'{0,history,0,noWork}','true')
  ] loop
    begin perform nohut_private.apply_timesheet_projection(r,5,bad); raise exception 'invalid snapshot accepted';
      exception when invalid_parameter_value then null; end;
  end loop;
  -- A no-work revision retains the prior submitted hours for audit. It is
  -- communication, never an approval or a rewrite of the first snapshot.
  shifts:=jsonb_set(shifts,'{0}',(shifts->0)||'{"voided":true,"voidedAt":"2026-11-25T12:00:00Z","voidReason":"Synthetic correction","corrections":[{"at":"2026-11-25T12:00:00Z","byId":2,"by":"Synthetic staff","before":{"start":"2026-11-23T06:00:00Z","end":"2026-11-23T15:00:00Z","breakMinutes":60},"after":{"start":"2026-11-23T06:00:00Z","end":"2026-11-23T15:00:00Z","breakMinutes":60},"reason":"İptal: Synthetic correction"}]}'::jsonb);
  perform nohut_private.apply_shift_projection(r,5,shifts);
  w:=jsonb_set(w,'{0,history}',(w#>'{0,history}')||'[{"at":"2026-11-25T12:00:00Z","minutes":0,"noWork":true,"entries":[]}]'::jsonb);
  w:=jsonb_set(w,'{0}',(w->0)||'{"submittedAt":"2026-11-25T12:00:00Z","minutes":0,"noWork":true}'::jsonb);
  perform nohut_private.apply_timesheet_projection(r,6,w);
  if (select count(*) from nohut_private.timesheet_submissions where restaurant_id=r)<>2
    or (select count(*) from nohut_private.timesheet_entries where restaurant_id=r)<>1
    or (select minutes from nohut_private.timesheet_weeks where restaurant_id=r)<>0 then
    raise exception 'submission history lost'; end if;
end $$;
set local role authenticated;
do $$ begin
  begin perform 1 from nohut_private.timesheet_entries;raise exception 'client read private hours';exception when insufficient_privilege then null;end;
end $$;
reset role;
rollback;
