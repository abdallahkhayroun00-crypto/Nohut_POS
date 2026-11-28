\set ON_ERROR_STOP on
begin;
do $$
declare r uuid:=gen_random_uuid(); p jsonb; edited jsonb; bad jsonb;
begin
  insert into nohut_private.restaurants(restaurant_id) values(r);
  perform nohut_private.apply_employee_projection(r,1,'[{"id":2,"name":"Synthetic staff","active":true}]');
  p:='[{"id":"mw_synthetic","employeeId":2,"employeeName":"Synthetic staff","source":"manual",
    "start":"2026-11-23T06:00:00Z","end":"2026-11-23T15:00:00Z","breakMinutes":60,"note":"Synthetic shift",
    "createdAt":"2026-11-24T10:00:00Z","updatedAt":"2026-11-24T10:00:00Z","corrections":[]}]';
  perform nohut_private.apply_shift_projection(r,2,p);
  edited:=jsonb_set(jsonb_set(p,'{0,breakMinutes}','30'),'{0,corrections}',
    '[{"at":"2026-11-24T11:00:00Z","byId":2,"by":"Synthetic staff","before":{"start":"2026-11-23T06:00:00Z","end":"2026-11-23T15:00:00Z","breakMinutes":60},"after":{"start":"2026-11-23T06:00:00Z","end":"2026-11-23T15:00:00Z","breakMinutes":30},"reason":"Personel düzenlemesi"}]');
  perform nohut_private.apply_shift_projection(r,3,edited);
  if (select break_minutes from nohut_private.shifts where restaurant_id=r)<>30
    or (select before_break_minutes from nohut_private.shift_corrections where restaurant_id=r)<>60 then
    raise exception 'historical breaks lost'; end if;
  foreach bad in array array[
    jsonb_set(edited,'{0,breakMinutes}','31'),
    jsonb_set(edited,'{0,corrections,0,before,breakMinutes}','0'),
    jsonb_set(edited,'{0,createdAt}','"2026-11-24T12:00:00Z"'),
    jsonb_set(edited,'{0,employeeName}','"Changed historical label"'),
    jsonb_set(edited,'{0,voided}','true'),
    jsonb_set(edited,'{0,corrections}','[]')
  ] loop
    begin perform nohut_private.apply_shift_projection(r,4,bad);
      raise exception 'invalid manual shift accepted'; exception when invalid_parameter_value or check_violation then null; end;
  end loop;
  p:=edited;
  edited:=jsonb_set(edited,'{0,corrections}',(edited#>'{0,corrections}')||
    '[{"at":"2026-11-24T12:00:00Z","byId":2,"by":"Synthetic staff","before":{"start":"2026-11-23T06:00:00Z","end":"2026-11-23T15:00:00Z","breakMinutes":30},"after":{"start":"2026-11-23T06:00:00Z","end":"2026-11-23T15:00:00Z","breakMinutes":30},"reason":"İptal: Synthetic correction"}]');
  edited:=jsonb_set(edited,'{0}',(edited->0)||'{"voided":true,"voidedAt":"2026-11-24T12:00:00Z","voidReason":"Synthetic correction"}'::jsonb);
  begin perform nohut_private.apply_shift_projection(r,4,jsonb_set(edited,'{0,corrections,1,before,breakMinutes}','31'));
    raise exception 'broken break correction chain accepted'; exception when invalid_parameter_value then null; end;
  perform nohut_private.apply_shift_projection(r,4,edited);
  begin perform nohut_private.apply_shift_projection(r,5,jsonb_set(edited,'{0,voided}','false'));
    raise exception 'void undone'; exception when invalid_parameter_value then null; end;
  if (select count(*) from nohut_private.shift_corrections where restaurant_id=r)<>2
    or (select source_revision from nohut_private.shifts where restaurant_id=r)<>4 then raise exception 'partial attendance'; end if;
end $$;
rollback;
