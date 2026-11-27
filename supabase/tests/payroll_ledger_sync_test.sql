\set ON_ERROR_STOP on
begin;
do $$
declare r uuid:=gen_random_uuid(); p jsonb; bad jsonb; original jsonb; reverse_row jsonb; eid uuid;
begin
  insert into nohut_private.restaurants(restaurant_id) values(r);
  perform nohut_private.apply_employee_projection(r,1,'[{"id":2,"name":"Synthetic staff","active":true}]');
  select employee_id into eid from nohut_private.employee_source_ids where restaurant_id=r and local_id=2;
  p:='{"source_updated_at":"2026-11-30T10:00:00Z","rows":[
    {"table":"payroll_payments","data":{"payment_id":"71111111-1111-4111-8111-111111111111","source_reference":"pp_synthetic","employee_local_id":2,"employee_name_at_record":"Synthetic staff","week_start":"2026-11-23","paid_on":"2026-11-30","kind":"Ödeme","method":"Karma","cash_kurus":30000,"bank_kurus":50000,"amount_kurus":80000,"reverses_id":null,"note":"Synthetic partial","recorded_at":"2026-11-30T09:00:00Z","actor_label":"Synthetic manager"}},
    {"table":"payroll_reviews","data":{"review_id":"72222222-2222-4222-8222-222222222222","employee_local_id":2,"week_start":"2026-11-23","state":"Ödenmedi","note":"No movement","recorded_at":"2026-11-30T08:00:00Z","actor_label":"Synthetic manager"}}
  ]}';
  foreach bad in array array[
    jsonb_set(p,'{rows,0,data,amount_kurus}','80001'),
    jsonb_set(p,'{rows,0,data,cash_kurus}','0'),
    jsonb_set(p,'{rows,0,data,method}','"Nakit"'),
    jsonb_set(p,'{rows,0,data,week_start}','"2026-11-24"'),
    jsonb_set(p,'{rows,0,data,paid_on}','"2026-12-01"')
  ] loop
    begin perform nohut_private.apply_typed_projection(r,2,'finance',bad);
      raise exception 'invalid new payroll accepted'; exception when check_violation then null; end;
  end loop;
  perform nohut_private.apply_typed_projection(r,2,'finance',p);
  perform nohut_private.apply_typed_projection(r,3,'finance',p);
  if (select sum(amount_kurus) from nohut_private.payroll_payments where restaurant_id=r)<>80000
    or (select employee_id from nohut_private.payroll_payments where restaurant_id=r)<>eid then
    raise exception 'partial/mixed payroll not retained'; end if;
  foreach bad in array array[
    jsonb_set(p,'{rows,0,data,amount_kurus}','80001'),
    jsonb_set(p,'{rows,0,data,cash_kurus}','30001'),
    jsonb_set(p,'{rows,0,data,actor_label}','"forged"'),
    jsonb_set(p,'{rows,0,data,employee_local_id}','999'),
    jsonb_set(p,'{rows,1,data,state}','"Ödendi"'),
    jsonb_set(p,'{rows}',(p->'rows')-0)
  ] loop
    begin perform nohut_private.apply_typed_projection(r,4,'finance',bad);
      raise exception 'payroll history altered'; exception when invalid_parameter_value then null; end;
  end loop;
  original:=p#>'{rows,0,data}';
  reverse_row:=original||'{"payment_id":"73333333-3333-4333-8333-333333333333","source_reference":"pr_pp_synthetic","kind":"Düzeltme","cash_kurus":-30000,"bank_kurus":-50000,"amount_kurus":-80000,"reverses_id":"71111111-1111-4111-8111-111111111111","note":"Synthetic correction","recorded_at":"2026-11-30T10:00:00Z"}'::jsonb;
  bad:=p||jsonb_build_object('rows',(p->'rows')||jsonb_build_array(jsonb_build_object('table','payroll_payments','data',reverse_row||'{"cash_kurus":-29999,"amount_kurus":-79999}'::jsonb)));
  begin perform nohut_private.apply_typed_projection(r,4,'finance',bad);
    raise exception 'partial reversal accepted'; exception when invalid_parameter_value then null; end;
  p:=p||jsonb_build_object('rows',(p->'rows')||jsonb_build_array(jsonb_build_object('table','payroll_payments','data',reverse_row)));
  perform nohut_private.apply_typed_projection(r,4,'finance',p);
  if (select sum(amount_kurus) from nohut_private.payroll_payments where restaurant_id=r)<>0
    or (select count(*) from nohut_private.payroll_payments where restaurant_id=r)<>2 then
    raise exception 'reversal must preserve original and net zero'; end if;
  bad:=p||jsonb_build_object('rows',(p->'rows')||jsonb_build_array(jsonb_build_object('table','payroll_payments','data',reverse_row||'{"payment_id":"74444444-4444-4444-8444-444444444444","source_reference":"duplicate-reversal"}'::jsonb)));
  begin perform nohut_private.apply_typed_projection(r,5,'finance',bad);
    raise exception 'double reversal accepted'; exception when unique_violation then null; end;
  if exists(select 1 from nohut_private.payroll_payments where restaurant_id=r and source_revision=5) then raise exception 'partial invalid payroll'; end if;
end $$;
set local role authenticated;
do $$ begin
  begin perform 1 from nohut_private.payroll_payments; raise exception 'client read other wages'; exception when insufficient_privilege then null; end;
  begin perform 1 from nohut_private.payroll_reviews; raise exception 'client read other reviews'; exception when insufficient_privilege then null; end;
end $$;
reset role;
rollback;
