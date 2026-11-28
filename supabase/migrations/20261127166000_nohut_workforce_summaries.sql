-- QA-09 / O-03: Authoritative Windows-calculated weekly payroll & workforce summaries.
-- Windows remains the sole calculator (payrollStatus/payrollWeek/ownWeek);
-- cloud stores the typed projection with explicit revision/as-of metadata.
begin;

create table nohut_private.weekly_workforce_summaries(
  restaurant_id uuid not null,
  employee_id uuid not null,
  employee_local_id bigint not null check(employee_local_id > 0),
  employee_name text not null check(length(trim(employee_name)) between 1 and 256),
  week_start date not null check(extract(isodow from week_start) = 1),
  week_end date not null check(week_end = week_start + 6),
  due_date date not null check(due_date >= week_start + 7 and due_date <= week_start + 13),
  as_of_day date not null,
  calculated_at timestamptz not null,
  payroll_eligible boolean not null,
  worked_minutes integer not null check(worked_minutes >= 0),
  planned_minutes integer not null check(planned_minutes >= 0),
  missing_rate_minutes integer not null check(missing_rate_minutes >= 0),
  rate_complete boolean not null,
  pay_type text check(pay_type is null or pay_type in ('Saatlik','Haftalık Sabit')),
  rate_kurus bigint check(rate_kurus is null or (rate_kurus > 0 and rate_kurus <= 9007199254740991)),
  earned_kurus bigint check(earned_kurus is null or (earned_kurus >= 0 and earned_kurus <= 9007199254740991)),
  paid_kurus bigint not null check(paid_kurus >= 0 and paid_kurus <= 9007199254740991),
  advance_kurus bigint not null check(advance_kurus >= 0 and advance_kurus <= 9007199254740991),
  overpaid_kurus bigint not null check(overpaid_kurus >= 0 and overpaid_kurus <= 9007199254740991),
  remaining_kurus bigint check(remaining_kurus is null or (remaining_kurus >= 0 and remaining_kurus <= 9007199254740991)),
  financial_status text not null check(financial_status in (
    'Çalışma kaydı yok','Ücret belirlenmedi','Ödenmedi','Kısmen Ödendi','Ödendi'
  )),
  review_status text not null check(review_status in ('Belirtildi','Ödenmedi (belirtildi)','Belirtilmedi')),
  submission_status text not null check(submission_status in ('Taslak','Gönderildi','Çalışmadı')),
  submitted_at timestamptz,
  overdue boolean not null,
  legacy boolean not null default false,
  last_paid_on date,
  source_revision bigint not null check(source_revision >= 0),
  updated_at timestamptz not null default clock_timestamp(),
  primary key(restaurant_id, employee_id, week_start),
  foreign key(restaurant_id, employee_id) references nohut_private.employees,
  check(financial_status <> 'Ücret belirlenmedi' or (earned_kurus is null and remaining_kurus is null)),
  check(financial_status <> 'Çalışma kaydı yok' or (worked_minutes = 0 and paid_kurus = 0 and not overdue))
);

alter table nohut_private.weekly_workforce_summaries enable row level security;
alter table nohut_private.weekly_workforce_summaries force row level security;
do $$ begin
  execute format(
    'create policy workforce_summary_owner on nohut_private.weekly_workforce_summaries for all to %I using(true) with check(true)',
    current_user
  );
end $$;
revoke all on nohut_private.weekly_workforce_summaries from public, anon, authenticated, service_role;

create function nohut_private.apply_workforce_summary_projection(p_restaurant uuid, p_revision bigint, p_payload jsonb)
returns void language plpgsql security invoker set search_path = '' as $$
declare
  item jsonb;
  eid uuid;
  ws date;
  we date;
  dd date;
  aod date;
  calc timestamptz;
  sub_at timestamptz;
  seen text[] := array[]::text[];
  key text;
begin
  perform nohut_private.command_shape(p_payload, '{"as_of_day":"string","calculated_at":"string","rows":"array"}');
  if p_payload->>'as_of_day' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'invalid workforce summary as_of_day' using errcode = '22023';
  end if;
  aod := (p_payload->>'as_of_day')::date;
  calc := nohut_private.shift_timestamp(p_payload->'calculated_at');
  if calc is null or p_revision is null or p_revision < 0 then
    raise exception 'invalid workforce summary metadata' using errcode = '22023';
  end if;

  for item in select value from jsonb_array_elements(p_payload->'rows') loop
    perform nohut_private.command_shape(
      item,
      '{"employeeLocalId":"integer","employeeName":"string","weekStart":"string","weekEnd":"string","dueDate":"string","payrollEligible":"boolean","workedMinutes":"integer","plannedMinutes":"integer","missingRateMinutes":"integer","rateComplete":"boolean","paidKurus":"integer","advanceKurus":"integer","overpaidKurus":"integer","financialStatus":"string","reviewStatus":"string","submissionStatus":"string","overdue":"boolean","legacy":"boolean"}',
      '{"payType":"nullable_string","rateKurus":"nullable_integer","earnedKurus":"nullable_integer","remainingKurus":"nullable_integer","submittedAt":"nullable_string","lastPaidOn":"nullable_string"}'
    );
    if item->>'weekStart' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      or item->>'weekEnd' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      or item->>'dueDate' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      or (item->>'lastPaidOn' is not null and item->>'lastPaidOn' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') then
      raise exception 'invalid workforce summary date' using errcode = '22023';
    end if;
    ws := (item->>'weekStart')::date;
    we := (item->>'weekEnd')::date;
    dd := (item->>'dueDate')::date;
    sub_at := nohut_private.shift_timestamp(item->'submittedAt');
    select employee_id into eid from nohut_private.employee_source_ids
      where restaurant_id = p_restaurant and local_id = (item->>'employeeLocalId')::bigint;
    if not found then
      raise exception 'unknown workforce summary employee' using errcode = '22023';
    end if;
    key := eid::text || ':' || ws::text;
    if key = any(seen) then
      raise exception 'duplicate workforce summary identity' using errcode = '22023';
    end if;
    seen := array_append(seen, key);

    insert into nohut_private.weekly_workforce_summaries(
      restaurant_id, employee_id, employee_local_id, employee_name,
      week_start, week_end, due_date, as_of_day, calculated_at,
      payroll_eligible, worked_minutes, planned_minutes, missing_rate_minutes, rate_complete,
      pay_type, rate_kurus, earned_kurus, paid_kurus, advance_kurus, overpaid_kurus, remaining_kurus,
      financial_status, review_status, submission_status, submitted_at, overdue, legacy, last_paid_on,
      source_revision, updated_at
    ) values (
      p_restaurant, eid, (item->>'employeeLocalId')::bigint, item->>'employeeName',
      ws, we, dd, aod, calc,
      (item->>'payrollEligible')::boolean, (item->>'workedMinutes')::integer,
      (item->>'plannedMinutes')::integer, (item->>'missingRateMinutes')::integer,
      (item->>'rateComplete')::boolean,
      item->>'payType', (item->>'rateKurus')::bigint, (item->>'earnedKurus')::bigint,
      (item->>'paidKurus')::bigint, (item->>'advanceKurus')::bigint, (item->>'overpaidKurus')::bigint,
      (item->>'remainingKurus')::bigint,
      item->>'financialStatus', item->>'reviewStatus', item->>'submissionStatus',
      sub_at, (item->>'overdue')::boolean, (item->>'legacy')::boolean,
      case when item->>'lastPaidOn' is null then null else (item->>'lastPaidOn')::date end,
      p_revision, clock_timestamp()
    )
    on conflict(restaurant_id, employee_id, week_start) do update set
      employee_name = excluded.employee_name,
      week_end = excluded.week_end,
      due_date = excluded.due_date,
      as_of_day = excluded.as_of_day,
      calculated_at = excluded.calculated_at,
      payroll_eligible = excluded.payroll_eligible,
      worked_minutes = excluded.worked_minutes,
      planned_minutes = excluded.planned_minutes,
      missing_rate_minutes = excluded.missing_rate_minutes,
      rate_complete = excluded.rate_complete,
      pay_type = excluded.pay_type,
      rate_kurus = excluded.rate_kurus,
      earned_kurus = excluded.earned_kurus,
      paid_kurus = excluded.paid_kurus,
      advance_kurus = excluded.advance_kurus,
      overpaid_kurus = excluded.overpaid_kurus,
      remaining_kurus = excluded.remaining_kurus,
      financial_status = excluded.financial_status,
      review_status = excluded.review_status,
      submission_status = excluded.submission_status,
      submitted_at = excluded.submitted_at,
      overdue = excluded.overdue,
      legacy = excluded.legacy,
      last_paid_on = excluded.last_paid_on,
      source_revision = excluded.source_revision,
      updated_at = clock_timestamp()
    where nohut_private.weekly_workforce_summaries.source_revision < excluded.source_revision;
  end loop;
end $$;
revoke all on function nohut_private.apply_workforce_summary_projection(uuid, bigint, jsonb)
  from public, anon, authenticated, service_role;

-- Extend atomic sync ingest to accept workforceSummaries after core & finance projections.
create or replace function nohut_private.ingest_sync_transaction(p_restaurant uuid, p_epoch uuid, p_tx jsonb)
returns jsonb language plpgsql security invoker set search_path = pg_catalog, nohut_private
as $$
declare cp nohut_private.sync_checkpoints%rowtype; old_tx nohut_private.sync_transactions%rowtype;
  rev bigint; fst bigint; lst bigint; n integer; tid uuid; ev jsonb;
begin
  perform nohut_private.validate_sync_transaction(p_epoch, p_tx);
  perform 1 from nohut_private.authority_epochs a where a.restaurant_id = p_restaurant
    and a.authority_epoch = p_epoch and a.retired_at is null for share;
  if not found then raise exception 'inactive authority' using errcode = '42501'; end if;
  perform 1 from nohut_private.sync_migrations m where m.restaurant_id = p_restaurant
    and m.authority_epoch = p_epoch and m.status = 'active' for share;
  if not found then raise exception 'migration not active' using errcode = '42501'; end if;
  select * into cp from nohut_private.sync_checkpoints c where c.restaurant_id = p_restaurant
    and c.authority_epoch = p_epoch for update;
  if not found then raise exception 'checkpoint not provisioned' using errcode = '42501'; end if;
  rev := (p_tx->>'source_revision')::bigint; fst := (p_tx->>'first_seq')::bigint;
  lst := (p_tx->>'last_seq')::bigint; n := (p_tx->>'event_count')::integer; tid := (p_tx->>'tx_id')::uuid;
  select * into old_tx from nohut_private.sync_transactions t
    where t.restaurant_id = p_restaurant and t.authority_epoch = p_epoch and t.tx_id = tid;
  if found then
    if old_tx.source_revision <> rev or old_tx.first_seq <> fst or old_tx.last_seq <> lst
       or old_tx.event_count <> n or old_tx.body_sha256 <> p_tx->>'body_sha256'
       or cp.last_acked_seq < lst
       or (select count(*) from nohut_private.sync_event_ids i where i.restaurant_id = p_restaurant
          and i.authority_epoch = p_epoch and i.tx_id = tid) <> n
       or exists(select 1 from jsonb_array_elements(p_tx->'events') v(ev)
         where not exists(select 1 from nohut_private.sync_event_ids i
          where i.restaurant_id = p_restaurant and i.authority_epoch = p_epoch and i.tx_id = tid
          and i.event_id = v.ev->>'event_id' and i.event_ordinal = (v.ev->>'event_ordinal')::integer
          and i.seq = (v.ev->>'seq')::bigint and i.entity_type = v.ev->>'entity_type'
          and i.entity_id = v.ev->>'entity_id' and i.op = v.ev->>'op'
          and i.body_sha256 = v.ev->>'body_sha256')) then
      return jsonb_build_object('status', 'conflict', 'acked_through_seq', cp.last_acked_seq);
    end if;
    return jsonb_build_object('status', 'duplicate', 'acked_through_seq', cp.last_acked_seq);
  end if;
  if fst > cp.last_acked_seq + 1 then
    return jsonb_build_object('status', 'gap', 'acked_through_seq', cp.last_acked_seq);
  end if;
  if fst <> cp.last_acked_seq + 1 or rev <= cp.last_acked_revision then
    return jsonb_build_object('status', 'conflict', 'acked_through_seq', cp.last_acked_seq);
  end if;
  if exists(select 1 from jsonb_array_elements(p_tx->'events') v(ev)
    where not((v.ev->>'entity_type' in ('employees','shifts','timesheetWeeks','shiftPlans','typed_finance','workforceSummaries') and v.ev->>'entity_id' = 'core')
      or (v.ev->>'entity_type' = 'typed_catalog' and v.ev->>'entity_id' in ('localMenu','internalMenu','qrCategories','qrCampaigns'))
      or (v.ev->>'entity_type' in ('typed_print','typed_platform'))
      or (v.ev->>'entity_type' = 'typed_ledger' and v.ev->>'entity_id' in ('combinedPayments','terminalAttempts','cashBook'))
      or (v.ev->>'entity_type' in ('typed_order','order_archive_marker') and v.ev->>'entity_id' ~ '^[0-9]+$'))
      or v.ev->>'op' <> 'upsert')
    or (select count(distinct (v.ev->>'entity_type', v.ev->>'entity_id')) from jsonb_array_elements(p_tx->'events') v(ev)) <> n then
    raise exception 'typed projection not supported yet' using errcode = '22023';
  end if;
  if exists(select 1 from jsonb_array_elements(p_tx->'events') marker where marker->>'entity_type' = 'order_archive_marker'
    and (marker->'payload' is distinct from jsonb_build_object('local_order_id', marker->>'entity_id', 'archive_required', true)
      or not exists(select 1 from jsonb_array_elements(p_tx->'events') archive where archive->>'entity_type' = 'typed_order'
        and archive->>'entity_id' = marker->>'entity_id' and archive->'payload'->'counts'->'deleted_order_audit' = '1'::jsonb))) then
    raise exception 'order deletion without full archive' using errcode = '22023'; end if;
  for ev in select value from jsonb_array_elements(p_tx->'events') order by case value->>'entity_type'
    when 'employees' then 0 when 'typed_catalog' then 10 when 'shiftPlans' then 15 when 'shifts' then 20
    when 'timesheetWeeks' then 25 when 'typed_order' then 30 when 'typed_platform' then 40 when 'typed_print' then 50
    when 'typed_finance' then 60 when 'typed_ledger' then 70 when 'workforceSummaries' then 80 else 90 end loop
    case ev->>'entity_type'
      when 'employees' then perform nohut_private.apply_employee_projection(p_restaurant, rev, ev->'payload');
      when 'typed_catalog' then perform nohut_private.apply_typed_projection(p_restaurant, rev, ev->>'entity_id', ev->'payload');
      when 'typed_finance' then perform nohut_private.apply_typed_finance(p_restaurant, rev, ev->'payload');
      when 'typed_ledger' then perform nohut_private.apply_typed_ledger(p_restaurant, rev, ev->>'entity_id', ev->'payload');
      when 'typed_platform' then perform nohut_private.apply_typed_platform(p_restaurant, rev, ev->>'entity_id', ev->'payload');
      when 'typed_print' then perform nohut_private.apply_typed_print(p_restaurant, rev, ev->>'entity_id', ev->'payload');
      when 'typed_order' then perform nohut_private.apply_typed_order(p_restaurant, rev, ev->>'entity_id', ev->'payload');
      when 'order_archive_marker' then null;
      when 'shifts' then perform nohut_private.apply_shift_projection(p_restaurant, rev, ev->'payload');
      when 'timesheetWeeks' then perform nohut_private.apply_timesheet_projection(p_restaurant, rev, ev->'payload');
      when 'shiftPlans' then perform nohut_private.apply_plan_projection(p_restaurant, rev, ev->'payload');
      when 'workforceSummaries' then perform nohut_private.apply_workforce_summary_projection(p_restaurant, rev, ev->'payload');
    end case;
  end loop;
  insert into nohut_private.sync_transactions(restaurant_id, authority_epoch, tx_id, source_revision, first_seq, last_seq, event_count, schema_version, body_sha256)
    values(p_restaurant, p_epoch, tid, rev, fst, lst, n, 1, p_tx->>'body_sha256');
  insert into nohut_private.sync_event_ids(restaurant_id, authority_epoch, tx_id, event_id, event_ordinal, seq, entity_type, entity_id, op, body_sha256)
    select p_restaurant, p_epoch, tid, v.ev->>'event_id', (v.ev->>'event_ordinal')::integer, (v.ev->>'seq')::bigint,
      v.ev->>'entity_type', v.ev->>'entity_id', v.ev->>'op', v.ev->>'body_sha256'
    from jsonb_array_elements(p_tx->'events') v(ev);
  update nohut_private.sync_checkpoints c set last_acked_seq = lst, last_acked_revision = rev, updated_at = clock_timestamp()
    where c.restaurant_id = p_restaurant and c.authority_epoch = p_epoch;
  return jsonb_build_object('status', 'accepted', 'acked_through_seq', lst);
end $$;

commit;
