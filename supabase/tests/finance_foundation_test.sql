\set ON_ERROR_STOP on
begin;
insert into nohut_private.restaurants(restaurant_id) values
 ('10000000-0000-0000-0000-000000000001'),
 ('10000000-0000-0000-0000-000000000002');
insert into nohut_private.employees(restaurant_id,employee_id,display_name,active,entity_version,source_revision,updated_at)
 values ('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','Synthetic worker',true,1,1,now());
insert into nohut_private.weekly_payroll(restaurant_id,payroll_id,local_id,employee_id,employee_name_at_record,week_start,week_end,pay_type,rate_kurus,worked_minutes,base_kurus,bonus_kurus,advance_kurus,gross_kurus,payable_kurus,paid,paid_at,created_at,entity_version,source_revision,updated_at)
 values ('10000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001',1,'20000000-0000-0000-0000-000000000001','Synthetic worker','2026-11-23','2026-11-29','hourly',10000,600,100000,10000,20000,110000,90000,true,now(),now(),1,1,now());
insert into nohut_private.fixed_expenses(restaurant_id,fixed_expense_id,local_id,category,label,amount_kurus,start_month,due_day,active,created_at,entity_version,source_revision,updated_at)
 values ('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',1,'Kira','Synthetic rent',200000,'2026-10-01',1,true,now(),1,1,now());
insert into nohut_private.fixed_expense_amount_history(restaurant_id,fixed_expense_id,from_month,amount_kurus,entity_version,source_revision,updated_at) values
 ('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','2026-10-01',100000,1,1,now()),
 ('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','2026-11-01',200000,1,1,now());
insert into nohut_private.fixed_expense_payments(restaurant_id,fixed_expense_id,payment_month,amount_kurus,paid_at,entity_version,source_revision,updated_at)
 values ('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','2026-10-01',100000,now(),1,1,now());
do $$
begin
  if (select amount_kurus from nohut_private.fixed_expense_payments) <> 100000 then
    raise exception 'Historical payment changed';
  end if;
  if (select payable_kurus from nohut_private.weekly_payroll) <> 90000 then
    raise exception 'Payroll balance incorrect';
  end if;
  begin
    update nohut_private.weekly_payroll set payable_kurus=1;
    raise exception 'Incorrect payroll accepted';
  exception when check_violation then null;
  end;
  begin
    update nohut_private.weekly_payroll set restaurant_id='10000000-0000-0000-0000-000000000002';
    raise exception 'Cross-restaurant employee accepted';
  exception when foreign_key_violation then null;
  end;
  begin
    insert into nohut_private.fixed_expense_amount_history
      select restaurant_id,fixed_expense_id,'2026-11-15'::date,amount_kurus,entity_version,source_revision,updated_at,deleted_at
      from nohut_private.fixed_expense_amount_history limit 1;
    raise exception 'Non-month-start date accepted';
  exception when check_violation then null;
  end;
end $$;
set local role authenticated;
do $$
begin
  begin
    perform count(*) from nohut_private.weekly_payroll;
    raise exception 'Direct payroll access unexpectedly allowed';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
rollback;
select 'PASS: payroll arithmetic, historical rent, tenant isolation and blocked payroll access' as result;
