-- QA-09 / O-03: Authorized weekly workforce & payroll cloud read RPCs.
-- Shapes match Claude's /api/work/week and ownerPayroll contracts (#7228113217).
-- Enforces verified JWT session/device/permission_version, self-only staff privacy,
-- payroll.view for multi-employee payroll, owner exclusion, and explicit stale metadata.
begin;

create function nohut_private.sync_freshness(p_restaurant uuid, p_summary_revision bigint default null, p_calculated_at timestamptz default null)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare
  cp record;
  stale boolean := true;
  reason text := 'no_sync';
begin
  select c.last_acked_revision, c.updated_at into cp
    from nohut_private.sync_checkpoints c
    join nohut_private.authority_epochs a
      on a.restaurant_id = c.restaurant_id and a.authority_epoch = c.authority_epoch
   where c.restaurant_id = p_restaurant and a.retired_at is null
   order by c.updated_at desc limit 1;
  if found then
    if clock_timestamp() - cp.updated_at > interval '15 minutes' then
      stale := true;
      reason := 'sync_aged';
    elsif p_summary_revision is null then
      stale := true;
      reason := 'summary_missing';
    else
      stale := false;
      reason := null;
    end if;
  end if;
  return jsonb_build_object(
    'sourceRevision', coalesce(p_summary_revision, cp.last_acked_revision),
    'calculatedAt', p_calculated_at,
    'syncedAt', cp.updated_at,
    'stale', stale,
    'staleReason', reason
  );
end $$;
revoke all on function nohut_private.sync_freshness(uuid, bigint, timestamptz)
  from public, anon, authenticated, service_role;

create function nohut_private.monday_of(p_day date) returns date
language sql immutable set search_path = '' as $$
  select p_day - (extract(isodow from p_day)::integer - 1)
$$;
revoke all on function nohut_private.monday_of(date) from public, anon, authenticated, service_role;

-- 1. Self-only employee week view (/api/work/week contract).
-- Impossible to pass another employee's ID: always bound to auth.uid() -> pos_employee_id.
create function public.nohut_workforce_own_week(
  p_device_id uuid,
  p_client text,
  p_permission_version bigint,
  p_week_start date default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  u nohut_private.app_users;
  eid uuid;
  emp nohut_private.employees;
  today_day date := (clock_timestamp() at time zone 'Europe/Istanbul')::date;
  ws date;
  we date;
  s nohut_private.weekly_workforce_summaries;
  can_pay boolean;
  plans_json jsonb;
  work_json jsonb;
  pay_json jsonb;
  status_json jsonb;
  fresh jsonb;
begin
  if nohut_private.authorize(auth.uid(), public.nohut_jwt_claim('session_id')::uuid,
      p_device_id, p_client, 'shifts.self', p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into u from nohut_private.app_users where user_id = auth.uid();
  if not found or u.pos_employee_id is null then
    raise exception 'actor not linked' using errcode = '42501';
  end if;
  select employee_id into eid from nohut_private.employee_source_ids
    where restaurant_id = u.restaurant_id and local_id = u.pos_employee_id;
  if not found then
    raise exception 'actor not linked' using errcode = '42501';
  end if;
  select * into emp from nohut_private.employees
    where restaurant_id = u.restaurant_id and employee_id = eid;

  ws := nohut_private.monday_of(coalesce(p_week_start, today_day));
  we := ws + 6;

  select * into s from nohut_private.weekly_workforce_summaries
    where restaurant_id = u.restaurant_id and employee_id = eid and week_start = ws;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.plan_id,
    'date', to_char(p.planned_day, 'YYYY-MM-DD'),
    'start', lpad((p.start_minute / 60)::text, 2, '0') || ':' || lpad((p.start_minute % 60)::text, 2, '0'),
    'end', lpad((p.end_minute / 60)::text, 2, '0') || ':' || lpad((p.end_minute % 60)::text, 2, '0'),
    'endsNextDay', p.ends_next_day,
    'dayOff', p.day_off,
    'breakMinutes', p.break_minutes,
    'note', p.note,
    'cancelled', p.cancelled
  ) order by p.planned_day, p.start_minute), '[]'::jsonb)
  into plans_json
  from nohut_private.shift_plans p
  where p.restaurant_id = u.restaurant_id and p.employee_id = eid
    and p.planned_day between ws and we and not p.cancelled;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', sh.shift_id,
    'start', sh.started_at,
    'end', sh.ended_at,
    'breakMinutes', sh.break_minutes,
    'note', sh.note,
    'source', sh.source,
    'voided', sh.voided
  ) order by sh.started_at), '[]'::jsonb)
  into work_json
  from nohut_private.shifts sh
  where sh.restaurant_id = u.restaurant_id and sh.employee_id = eid
    and (sh.started_at at time zone 'Europe/Istanbul')::date between ws and we
    and not sh.voided;

  can_pay := nohut_private.authorize(auth.uid(), public.nohut_jwt_claim('session_id')::uuid,
      p_device_id, p_client, 'payroll.self.view', p_permission_version) = 'ok';

  if s.employee_id is not null then
    status_json := jsonb_build_object(
      'status', s.submission_status,
      'minutes', s.worked_minutes,
      'submittedAt', s.submitted_at
    );
    if can_pay and s.payroll_eligible then
      pay_json := jsonb_build_object(
        'payrollEligible', true,
        'minutes', s.worked_minutes,
        'earnedCents', s.earned_kurus,
        'paidCents', s.paid_kurus,
        'advanceCents', s.advance_kurus,
        'remainingCents', s.remaining_kurus,
        'financialStatus', s.financial_status,
        'reviewStatus', s.review_status,
        'overdue', s.overdue,
        'lastPaidOn', case when s.last_paid_on is null then null else to_char(s.last_paid_on, 'YYYY-MM-DD') end,
        'rate', case when s.pay_type is null then null else jsonb_build_object('payType', s.pay_type, 'rateCents', s.rate_kurus) end
      );
    else
      pay_json := jsonb_build_object('payrollEligible', false);
    end if;
    fresh := nohut_private.sync_freshness(u.restaurant_id, s.source_revision, s.calculated_at);
  else
    status_json := jsonb_build_object('status', 'Taslak', 'minutes', 0, 'submittedAt', null);
    pay_json := case when can_pay and coalesce(emp.payroll_eligible, true)
      then jsonb_build_object('payrollEligible', true, 'earnedCents', null, 'remainingCents', null, 'financialStatus', 'Çalışma kaydı yok')
      else jsonb_build_object('payrollEligible', false) end;
    fresh := nohut_private.sync_freshness(u.restaurant_id, null, null);
  end if;

  return jsonb_build_object(
    'today', to_char(today_day, 'YYYY-MM-DD'),
    'weekStart', to_char(ws, 'YYYY-MM-DD'),
    'syncMeta', fresh,
    'week', jsonb_build_object(
      'employee', jsonb_build_object(
        'id', u.pos_employee_id,
        'name', emp.display_name,
        'payrollEligible', coalesce(emp.payroll_eligible, true),
        'payType', case when can_pay and coalesce(emp.payroll_eligible, true) then emp.pay_type else null end,
        'payRateCents', case when can_pay and coalesce(emp.payroll_eligible, true) then emp.pay_rate_kurus else null end
      ),
      'status', status_json,
      'plannedMinutes', coalesce(s.planned_minutes, 0),
      'plans', plans_json,
      'work', work_json,
      'pay', pay_json
    )
  );
end $$;

-- 2. Shared team planned Vardiya schedule: names and times ONLY (no wages, no actual hours, no private notes).
create function public.nohut_team_schedule(
  p_device_id uuid,
  p_client text,
  p_permission_version bigint,
  p_from date,
  p_to date
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  u nohut_private.app_users;
  items jsonb;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 31 then
    raise exception 'invalid schedule range' using errcode = '22023';
  end if;
  if nohut_private.authorize(auth.uid(), public.nohut_jwt_claim('session_id')::uuid,
      p_device_id, p_client, 'shifts.self', p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into u from nohut_private.app_users where user_id = auth.uid();
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'employeeName', p.employee_label,
    'date', to_char(p.planned_day, 'YYYY-MM-DD'),
    'start', lpad((p.start_minute / 60)::text, 2, '0') || ':' || lpad((p.start_minute % 60)::text, 2, '0'),
    'end', lpad((p.end_minute / 60)::text, 2, '0') || ':' || lpad((p.end_minute % 60)::text, 2, '0'),
    'endsNextDay', p.ends_next_day,
    'dayOff', p.day_off
  ) order by p.planned_day, p.start_minute, p.employee_label), '[]'::jsonb)
  into items
  from nohut_private.shift_plans p
  where p.restaurant_id = u.restaurant_id
    and p.planned_day between p_from and p_to
    and not p.cancelled;

  return jsonb_build_object(
    'from', to_char(p_from, 'YYYY-MM-DD'),
    'to', to_char(p_to, 'YYYY-MM-DD'),
    'syncMeta', nohut_private.sync_freshness(u.restaurant_id),
    'plans', items
  );
end $$;

-- 3. Multi-employee weekly payroll view (ownerPayroll contract). Requires payroll.view (or owner).
create function public.nohut_payroll_week(
  p_device_id uuid,
  p_client text,
  p_permission_version bigint,
  p_week_start date default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  u nohut_private.app_users;
  today_day date := (clock_timestamp() at time zone 'Europe/Istanbul')::date;
  ws date;
  rows_json jsonb;
  payments_json jsonb;
  max_rev bigint;
  max_calc timestamptz;
begin
  if nohut_private.authorize(auth.uid(), public.nohut_jwt_claim('session_id')::uuid,
      p_device_id, p_client, 'payroll.view', p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into u from nohut_private.app_users where user_id = auth.uid();
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;

  ws := case when p_week_start is not null then nohut_private.monday_of(p_week_start)
             else nohut_private.monday_of(today_day) - 7 end;

  select max(s.source_revision), max(s.calculated_at),
    coalesce(jsonb_agg(jsonb_build_object(
      'employeeId', s.employee_local_id,
      'name', s.employee_name,
      'weekStart', to_char(s.week_start, 'YYYY-MM-DD'),
      'weekEnd', to_char(s.week_end, 'YYYY-MM-DD'),
      'dueDate', to_char(s.due_date, 'YYYY-MM-DD'),
      'payrollEligible', s.payroll_eligible,
      'minutes', s.worked_minutes,
      'missingRateMinutes', s.missing_rate_minutes,
      'rateComplete', s.rate_complete,
      'rate', case when s.pay_type is null then null else jsonb_build_object('payType', s.pay_type, 'rateCents', s.rate_kurus) end,
      'earnedCents', s.earned_kurus,
      'paidCents', s.paid_kurus,
      'advanceCents', s.advance_kurus,
      'overpaidCents', s.overpaid_kurus,
      'remainingCents', s.remaining_kurus,
      'financialStatus', s.financial_status,
      'reviewStatus', s.review_status,
      'submission', s.submission_status,
      'submittedAt', s.submitted_at,
      'overdue', s.overdue,
      'legacy', s.legacy,
      'lastPaidOn', case when s.last_paid_on is null then null else to_char(s.last_paid_on, 'YYYY-MM-DD') end
    ) order by s.employee_local_id), '[]'::jsonb)
  into max_rev, max_calc, rows_json
  from nohut_private.weekly_workforce_summaries s
  where s.restaurant_id = u.restaurant_id
    and s.week_start = ws
    and (s.payroll_eligible or s.paid_kurus > 0 or s.legacy);

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.source_reference,
    'employeeId', x.local_id,
    'employeeName', p.employee_name_at_record,
    'weekStart', to_char(p.week_start, 'YYYY-MM-DD'),
    'paidOn', to_char(p.paid_on, 'YYYY-MM-DD'),
    'kind', p.kind,
    'method', p.method,
    'cashCents', p.cash_kurus,
    'bankCents', p.bank_kurus,
    'amountCents', p.amount_kurus,
    'reverses', orig.source_reference,
    'note', p.note,
    'createdAt', p.recorded_at,
    'createdBy', p.actor_label
  ) order by p.recorded_at, p.source_reference), '[]'::jsonb)
  into payments_json
  from nohut_private.payroll_payments p
  join nohut_private.employee_source_ids x
    on x.restaurant_id = p.restaurant_id and x.employee_id = p.employee_id
  left join nohut_private.payroll_payments orig
    on orig.restaurant_id = p.restaurant_id and orig.payment_id = p.reverses_id
  where p.restaurant_id = u.restaurant_id and p.week_start = ws;

  return jsonb_build_object(
    'ok', true,
    'weekStart', to_char(ws, 'YYYY-MM-DD'),
    'today', to_char(today_day, 'YYYY-MM-DD'),
    'syncMeta', nohut_private.sync_freshness(u.restaurant_id, max_rev, max_calc),
    'rows', rows_json,
    'payments', payments_json
  );
end $$;

revoke all on function
  public.nohut_workforce_own_week(uuid, text, bigint, date),
  public.nohut_team_schedule(uuid, text, bigint, date, date),
  public.nohut_payroll_week(uuid, text, bigint, date)
  from public, anon, authenticated, service_role;

grant execute on function
  public.nohut_workforce_own_week(uuid, text, bigint, date),
  public.nohut_team_schedule(uuid, text, bigint, date, date),
  public.nohut_payroll_week(uuid, text, bigint, date)
  to authenticated;

commit;
