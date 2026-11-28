\set ON_ERROR_STOP on
begin;
do $$
declare r uuid:=gen_random_uuid(); payload jsonb; changed jsonb; bad jsonb; original jsonb;
begin
  insert into nohut_private.restaurants(restaurant_id) values(r);
  perform nohut_private.apply_employee_projection(r,1,'[{"id":1,"name":"Synthetic employee","active":true}]');
  payload:='{"source_updated_at":"2026-11-27T12:00:00Z","rows":[
    {"table":"material_purchases","data":{"purchase_id":"10000000-0000-4000-8000-000000000001","local_id":1,"business_day":"2026-11-01","title":"Synthetic purchase","record_type":"quick","total_kurus":1200,"amounts_kurus":[500,700],"payment_method":"Nakit","voided":false,"created_at":"2026-11-01T12:00:00Z"}},
    {"table":"material_purchase_history","data":{"purchase_id":"10000000-0000-4000-8000-000000000001","history_id":"10000000-0000-4000-8000-000000000002","changed_at":"2026-11-02T12:00:00Z","previous_total_kurus":1100,"previous_amounts_kurus":[500,600]}},
    {"table":"expenses","data":{"expense_id":"20000000-0000-4000-8000-000000000001","local_id":1,"business_day":"2026-11-01","category":"Diğer","label":"Synthetic expense","amount_kurus":100,"payment_method":"Nakit","voided":false,"created_at":"2026-11-01T12:00:00Z"}},
    {"table":"fixed_expenses","data":{"fixed_expense_id":"30000000-0000-4000-8000-000000000001","local_id":1,"category":"Kira","label":"Synthetic rent","amount_kurus":20000,"start_month":"2026-10-01","due_day":1,"active":true,"created_at":"2026-10-01T12:00:00Z"}},
    {"table":"fixed_expense_active_ranges","data":{"fixed_expense_id":"30000000-0000-4000-8000-000000000001","from_month":"2026-10-01","to_month":null}},
    {"table":"fixed_expense_amount_history","data":{"fixed_expense_id":"30000000-0000-4000-8000-000000000001","from_month":"2026-10-01","amount_kurus":20000}},
    {"table":"fixed_expense_payments","data":{"fixed_expense_id":"30000000-0000-4000-8000-000000000001","payment_month":"2026-10-01","amount_kurus":20000,"paid_at":"2026-10-02T12:00:00Z"}},
    {"table":"weekly_payroll","data":{"payroll_id":"40000000-0000-4000-8000-000000000001","local_id":1,"employee_local_id":1,"employee_name_at_record":"Synthetic employee","week_start":"2026-11-23","week_end":"2026-11-29","pay_type":"hourly","rate_kurus":1000,"worked_minutes":600,"base_kurus":10000,"bonus_kurus":1000,"advance_kurus":2000,"gross_kurus":11000,"payable_kurus":9000,"paid":true,"paid_at":"2026-11-27T12:00:00Z","created_at":"2026-11-27T12:00:00Z"}},
    {"table":"manual_platform_sales","data":{"sale_id":"50000000-0000-4000-8000-000000000001","local_id":1,"platform":"yemeksepeti","sales_month":"2026-11-01","amount_kind":"net","amount_kurus":10000,"voided":false,"created_at":"2026-11-01T12:00:00Z"}},
    {"table":"manual_platform_sales_history","data":{"sale_id":"50000000-0000-4000-8000-000000000001","history_id":"50000000-0000-4000-8000-000000000002","changed_at":"2026-11-02T12:00:00Z","amount_kind":"gross","amount_kurus":9000}}
  ]}';
  perform nohut_private.apply_typed_finance(r,2,payload);
  perform nohut_private.apply_typed_finance(r,2,payload);
  if (select count(*) from nohut_private.typed_record_versions where restaurant_id=r)<>10 then raise exception 'typed coverage missing'; end if;
  if (select payable_kurus from nohut_private.weekly_payroll where restaurant_id=r)<>9000 then raise exception 'payroll mismatch'; end if;
  changed:=jsonb_set(payload,'{rows,2,data,amount_kurus}','200');
  perform nohut_private.apply_typed_finance(r,3,changed);
  if (select count(*) from nohut_private.typed_record_history where restaurant_id=r)<>1 then raise exception 'old financial version lost'; end if;
  original:=changed;
  foreach bad in array array[
    jsonb_set(original,'{rows,2,data,amount_kurus}','200.5'),
    jsonb_set(original,'{rows,2,data,amount_kurus}','"200"'),
    jsonb_set(original,'{rows,2,data,customerPhone}','"synthetic"'),
    jsonb_set(original,'{rows,2,data,business_day}','"today"'),
    jsonb_set(original,'{rows,0,data,total_kurus}','1234'),
    jsonb_set(original,'{rows,6,data,amount_kurus}','30000'),
    jsonb_set(original,'{rows,7,data,advance_kurus}','3000'),
    jsonb_set(original,'{rows,7,data,employee_local_id}','999'),
    jsonb_set(original,'{rows}',(original->'rows')-2)
  ] loop
    begin perform nohut_private.apply_typed_finance(r,4,bad); raise exception 'invalid finance accepted';
      exception when invalid_parameter_value then null; end;
  end loop;
  if (select amount_kurus from nohut_private.expenses where restaurant_id=r)<>200
    or (select count(*) from nohut_private.typed_record_history where restaurant_id=r)<>1 then raise exception 'partial finance persisted'; end if;
end $$;
rollback;
