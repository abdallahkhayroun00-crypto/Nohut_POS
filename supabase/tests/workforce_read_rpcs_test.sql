\set ON_ERROR_STOP on
begin;

do $$
declare
  r1 uuid := gen_random_uuid();
  r2 uuid := gen_random_uuid();
  u_owner uuid := gen_random_uuid();
  u_staff_a uuid := gen_random_uuid();
  u_staff_b uuid := gen_random_uuid();
  u_unlinked uuid := gen_random_uuid();
  u_other_tenant uuid := gen_random_uuid();
  s_owner uuid := gen_random_uuid();
  s_staff_a uuid := gen_random_uuid();
  s_staff_b uuid := gen_random_uuid();
  s_unlinked uuid := gen_random_uuid();
  s_other uuid := gen_random_uuid();
  d_owner uuid := gen_random_uuid();
  d_staff_a uuid := gen_random_uuid();
  d_staff_b uuid := gen_random_uuid();
  d_unlinked uuid := gen_random_uuid();
  d_other uuid := gen_random_uuid();
  ep uuid := gen_random_uuid();
  res jsonb;
begin
  -- Seed two isolated restaurants + active sync checkpoint for r1
  insert into nohut_private.restaurants(restaurant_id) values (r1), (r2);
  insert into nohut_private.authority_epochs(restaurant_id, authority_epoch) values (r1, ep);
  insert into nohut_private.sync_migrations(restaurant_id, migration_id, authority_epoch, snapshot_revision, snapshot_seq, schema_version, manifest_sha256, status)
    values (r1, gen_random_uuid(), ep, 0, 0, 1, repeat('a', 64), 'active');
  insert into nohut_private.sync_checkpoints(restaurant_id, authority_epoch, last_acked_seq, last_acked_revision, updated_at)
    values (r1, ep, 10, 5, clock_timestamp());

  -- Seed auth users: owner (emp 1), staff A (emp 2), staff B (emp 3), unlinked staff, other tenant
  insert into nohut_private.app_users(user_id, restaurant_id, username, role_template, is_owner, active, pos_employee_id, permission_version)
  values
    (u_owner, r1, 'syn_owner', 'Yönetici', true, true, 1, 1),
    (u_staff_a, r1, 'syn_staff_a', 'Personel', false, true, 2, 1),
    (u_staff_b, r1, 'syn_staff_b', 'Personel', false, true, 3, 1),
    (u_unlinked, r1, 'syn_unlinked', 'Personel', false, true, null, 1),
    (u_other_tenant, r2, 'syn_other', 'Yönetici', true, true, 1, 1);

  insert into nohut_private.user_grants(user_id, operation_id)
  values
    (u_staff_a, 'shifts.self'), (u_staff_a, 'payroll.self.view'),
    (u_staff_b, 'shifts.self'), (u_staff_b, 'payroll.self.view'),
    (u_unlinked, 'shifts.self');

  perform nohut_private.enroll_device(u_owner, d_owner, s_owner, 'yonetici', 'Owner Phone');
  perform nohut_private.enroll_device(u_staff_a, d_staff_a, s_staff_a, 'personel', 'Staff A Phone');
  perform nohut_private.enroll_device(u_staff_b, d_staff_b, s_staff_b, 'personel', 'Staff B Phone');
  perform nohut_private.enroll_device(u_unlinked, d_unlinked, s_unlinked, 'personel', 'Unlinked Phone');
  perform nohut_private.enroll_device(u_other_tenant, d_other, s_other, 'yonetici', 'Other Tenant Phone');

  -- Project employees, plans, shifts, payroll payment, and authoritative Windows summaries
  perform nohut_private.apply_employee_projection(r1, 2, '[
    {"id":1,"name":"Synthetic Owner","active":true,"payrollEligible":false},
    {"id":2,"name":"Synthetic Staff A","active":true,"payrollEligible":true,"payType":"Saatlik","payRateCents":12000},
    {"id":3,"name":"Synthetic Staff B","active":true,"payrollEligible":true},
    {"id":4,"name":"Synthetic Departed","active":false,"payrollEligible":true,"payType":"Saatlik","payRateCents":10000}
  ]'::jsonb);

  perform nohut_private.apply_plan_projection(r1, 3, '[
    {"id":"pl_1","employeeId":2,"employeeName":"Synthetic Staff A","date":"2026-11-23","start":"10:00","end":"18:00","endsNextDay":false,"dayOff":false,"breakMinutes":60,"note":"Private manager note","cancelled":false,"createdAt":"2026-11-20T10:00:00Z","createdBy":"Owner","updatedAt":"2026-11-20T10:00:00Z","updatedBy":"Owner","history":[]}
  ]'::jsonb);

  perform nohut_private.apply_typed_projection(r1, 4, 'finance', '{
    "source_updated_at":"2026-11-30T10:00:00Z",
    "rows":[
      {"table":"payroll_payments","data":{
        "payment_id":"91111111-1111-4111-8111-111111111111","source_reference":"pp_a1",
        "employee_local_id":2,"employee_name_at_record":"Synthetic Staff A",
        "week_start":"2026-11-23","paid_on":"2026-11-30","kind":"Ödeme","method":"Nakit",
        "cash_kurus":80000,"bank_kurus":0,"amount_kurus":80000,"reverses_id":null,
        "note":"First partial","recorded_at":"2026-11-30T09:00:00Z","actor_label":"Synthetic Owner"
      }}
    ]
  }'::jsonb);

  perform nohut_private.apply_workforce_summary_projection(r1, 5, '{
    "as_of_day":"2026-11-30",
    "calculated_at":"2026-11-30T10:05:00Z",
    "rows":[
      {"employeeLocalId":1,"employeeName":"Synthetic Owner","weekStart":"2026-11-23","weekEnd":"2026-11-29","dueDate":"2026-11-30","payrollEligible":false,"workedMinutes":0,"plannedMinutes":0,"missingRateMinutes":0,"rateComplete":true,"payType":null,"rateKurus":null,"earnedKurus":0,"paidKurus":0,"advanceKurus":0,"overpaidKurus":0,"remainingKurus":0,"financialStatus":"Çalışma kaydı yok","reviewStatus":"Belirtildi","submissionStatus":"Taslak","submittedAt":null,"overdue":false,"legacy":false,"lastPaidOn":null},
      {"employeeLocalId":2,"employeeName":"Synthetic Staff A","weekStart":"2026-11-23","weekEnd":"2026-11-29","dueDate":"2026-11-30","payrollEligible":true,"workedMinutes":960,"plannedMinutes":420,"missingRateMinutes":0,"rateComplete":true,"payType":"Saatlik","rateKurus":12000,"earnedKurus":176000,"paidKurus":80000,"advanceKurus":0,"overpaidKurus":0,"remainingKurus":96000,"financialStatus":"Kısmen Ödendi","reviewStatus":"Belirtildi","submissionStatus":"Gönderildi","submittedAt":"2026-11-29T18:00:00Z","overdue":true,"legacy":false,"lastPaidOn":"2026-11-30"},
      {"employeeLocalId":3,"employeeName":"Synthetic Staff B","weekStart":"2026-11-23","weekEnd":"2026-11-29","dueDate":"2026-11-30","payrollEligible":true,"workedMinutes":240,"plannedMinutes":0,"missingRateMinutes":240,"rateComplete":false,"payType":null,"rateKurus":null,"earnedKurus":null,"paidKurus":0,"advanceKurus":0,"overpaidKurus":0,"remainingKurus":null,"financialStatus":"Ücret belirlenmedi","reviewStatus":"Belirtilmedi","submissionStatus":"Taslak","submittedAt":null,"overdue":false,"legacy":false,"lastPaidOn":null},
      {"employeeLocalId":4,"employeeName":"Synthetic Departed","weekStart":"2026-11-23","weekEnd":"2026-11-29","dueDate":"2026-11-30","payrollEligible":true,"workedMinutes":240,"plannedMinutes":0,"missingRateMinutes":0,"rateComplete":true,"payType":"Saatlik","rateKurus":10000,"earnedKurus":40000,"paidKurus":0,"advanceKurus":0,"overpaidKurus":0,"remainingKurus":40000,"financialStatus":"Ödenmedi","reviewStatus":"Belirtilmedi","submissionStatus":"Taslak","submittedAt":null,"overdue":true,"legacy":false,"lastPaidOn":null}
    ]
  }'::jsonb);

  -- 1. Staff A reads own week: exact 1760 / 800 / 960 Kısmen Ödendi, fresh syncMeta
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_staff_a, 'session_id', s_staff_a, 'role', 'authenticated')::text, true);
  res := public.nohut_workforce_own_week(d_staff_a, 'personel', 1, '2026-11-23');
  if (res#>>'{week,pay,earnedCents}')::bigint <> 176000
     or (res#>>'{week,pay,paidCents}')::bigint <> 80000
     or (res#>>'{week,pay,remainingCents}')::bigint <> 96000
     or res#>>'{week,pay,financialStatus}' <> 'Kısmen Ödendi'
     or (res#>>'{syncMeta,stale}')::boolean <> false then
    raise exception 'staff A own week mismatch: %', res;
  end if;

  -- 2. Staff A CANNOT call nohut_payroll_week (missing payroll.view)
  begin
    perform public.nohut_payroll_week(d_staff_a, 'personel', 1, '2026-11-23');
    raise exception 'staff A allowed to read multi-employee payroll';
  exception when insufficient_privilege then null;
  end;

  -- 3. Staff B reads own week: missing rate -> NULL earnedCents/remainingCents (never 0!)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_staff_b, 'session_id', s_staff_b, 'role', 'authenticated')::text, true);
  res := public.nohut_workforce_own_week(d_staff_b, 'personel', 1, '2026-11-23');
  if res#>'{week,pay,earnedCents}' <> 'null'::jsonb
     or res#>'{week,pay,remainingCents}' <> 'null'::jsonb
     or res#>>'{week,pay,financialStatus}' <> 'Ücret belirlenmedi' then
    raise exception 'staff B missing wage fabricated: %', res;
  end if;

  -- 4. Staff B reads shared team schedule: sees Staff A's name/times ONLY (no note, no wages)
  res := public.nohut_team_schedule(d_staff_b, 'personel', 1, '2026-11-23', '2026-11-29');
  if jsonb_array_length(res->'plans') <> 1
     or res#>>'{plans,0,employeeName}' <> 'Synthetic Staff A'
     or (res#>'{plans,0}') ? 'note' or (res#>'{plans,0}') ? 'earnedCents' then
    raise exception 'team schedule leaked private fields: %', res;
  end if;

  -- 5. Unlinked employee is refused on nohut_workforce_own_week
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_unlinked, 'session_id', s_unlinked, 'role', 'authenticated')::text, true);
  begin
    perform public.nohut_workforce_own_week(d_unlinked, 'personel', 1, '2026-11-23');
    raise exception 'unlinked employee allowed';
  exception when insufficient_privilege then null;
  end;

  -- 6. Owner reads nohut_payroll_week: owner excluded (3 rows: Staff A, Staff B, Departed), 1 payment
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_owner, 'role', 'authenticated')::text, true);
  res := public.nohut_payroll_week(d_owner, 'yonetici', 1, '2026-11-23');
  if jsonb_array_length(res->'rows') <> 3
     or jsonb_array_length(res->'payments') <> 1
     or exists(select 1 from jsonb_array_elements(res->'rows') x where (x->>'employeeId')::int = 1) then
    raise exception 'owner payroll week mismatch: %', res;
  end if;

  -- 7. Owner's own week shows payrollEligible=false
  res := public.nohut_workforce_own_week(d_owner, 'yonetici', 1, '2026-11-23');
  if (res#>>'{week,pay,payrollEligible}')::boolean <> false then
    raise exception 'owner should be excluded from payroll: %', res;
  end if;

  -- 8. Cross-tenant isolation: other tenant sees 0 rows
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_other_tenant, 'session_id', s_other, 'role', 'authenticated')::text, true);
  res := public.nohut_payroll_week(d_other, 'yonetici', 1, '2026-11-23');
  if jsonb_array_length(res->'rows') <> 0 or (res#>>'{syncMeta,stale}')::boolean <> true then
    raise exception 'cross-tenant leak or wrong stale flag: %', res;
  end if;

  -- 9. Stale checkpoint (>15 min) flips syncMeta.stale = true
  update nohut_private.sync_checkpoints set updated_at = clock_timestamp() - interval '20 minutes'
    where restaurant_id = r1;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_owner, 'role', 'authenticated')::text, true);
  res := public.nohut_payroll_week(d_owner, 'yonetici', 1, '2026-11-23');
  if (res#>>'{syncMeta,stale}')::boolean <> true or res#>>'{syncMeta,staleReason}' <> 'sync_aged' then
    raise exception 'stale flag not set on aged checkpoint: %', res;
  end if;

  -- 10. Stale permission_version rejected
  begin
    perform public.nohut_payroll_week(d_owner, 'yonetici', 999, '2026-11-23');
    raise exception 'stale permission_version accepted';
  exception when insufficient_privilege then null;
  end;
end $$;

-- 11. Direct table access by authenticated role is refused
set local role authenticated;
do $$ begin
  begin
    perform 1 from nohut_private.weekly_workforce_summaries;
    raise exception 'authenticated read private weekly_workforce_summaries';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

rollback;
