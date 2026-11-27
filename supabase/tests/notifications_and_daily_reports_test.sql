-- Synthetic tests for Increment C: Cloud Notifications & Gün Sonu Raporu
-- Verifies:
--   1. Gün Sonu Raporu strictly REJECTS any payload containing staffHours (QA-05 superseded owner decision)
--   2. Gün Sonu Raporu requires dashboard.view (Personel denied); masks sales/expenses per sales.view / finance.view
--   3. Notifications are filtered by client, requiredPermission, and personal recipientEmployeeId
--   4. Per-user mark-read updates unreadCount only for the calling user (never mutates other users)
--   5. Cross-tenant isolation and FORCE RLS direct-table access denial
begin;

do $$
declare
  r1 uuid := '41111111-1111-4111-8111-111111111111';
  r2 uuid := '42222222-2222-4222-8222-222222222222';
  ep1 uuid := '4e111111-1111-4111-8111-111111111111';
  u_owner uuid := '4a111111-1111-4111-8111-111111111111';
  u_mgr   uuid := '4a222222-2222-4222-8222-222222222222';
  u_s1    uuid := '4a333333-3333-4333-8333-333333333333';
  u_s2    uuid := '4a444444-4444-4444-8444-444444444444';
  u_other uuid := '4a555555-5555-4555-8555-555555555555';
  d_owner uuid := '4d111111-1111-4111-8111-111111111111';
  d_mgr   uuid := '4d222222-2222-4222-8222-222222222222';
  d_s1    uuid := '4d333333-3333-4333-8333-333333333333';
  d_s2    uuid := '4d444444-4444-4444-8444-444444444444';
  d_other uuid := '4d555555-5555-4555-8555-555555555555';
  s_owner uuid := '4b111111-1111-4111-8111-111111111111';
  s_mgr   uuid := '4b222222-2222-4222-8222-222222222222';
  s_s1    uuid := '4b333333-3333-4333-8333-333333333333';
  s_s2    uuid := '4b444444-4444-4444-8444-444444444444';
  s_other uuid := '4b555555-5555-4555-8555-555555555555';
  res jsonb;
begin
  insert into nohut_private.restaurants(restaurant_id) values (r1), (r2);
  insert into nohut_private.authority_epochs(restaurant_id, authority_epoch) values (r1, ep1);
  insert into nohut_private.sync_migrations(
    restaurant_id, migration_id, authority_epoch, snapshot_revision, snapshot_seq,
    schema_version, manifest_sha256, status
  ) values (r1, gen_random_uuid(), ep1, 0, 0, 1, repeat('c', 64), 'active');
  insert into nohut_private.sync_checkpoints(restaurant_id, authority_epoch, last_acked_seq, last_acked_revision, updated_at)
    values (r1, ep1, 20, 20, clock_timestamp());

  insert into nohut_private.app_users(user_id, restaurant_id, username, pos_employee_id, role_template, is_owner, active, permission_version) values
    (u_owner, r1, 'c_owner', 1, 'Yönetici', true, true, 1),
    (u_mgr,   r1, 'c_mgr',   2, 'Müdür',    false, true, 1),
    (u_s1,    r1, 'c_s1',    3, 'Personel', false, true, 1),
    (u_s2,    r1, 'c_s2',    4, 'Personel', false, true, 1),
    (u_other, r2, 'c_other', 1, 'Yönetici', true, true, 1);

  -- Müdür has dashboard.view + sales.view + menu.view, but NOT finance.view
  insert into nohut_private.user_grants(user_id, operation_id, granted_by) values
    (u_mgr, 'menu.view', u_owner),
    (u_mgr, 'dashboard.view', u_owner),
    (u_mgr, 'sales.view', u_owner),
    (u_s1,  'menu.view', u_owner),
    (u_s1,  'shifts.self', u_owner),
    (u_s2,  'menu.view', u_owner),
    (u_s2,  'shifts.self', u_owner);

  perform nohut_private.enroll_device(u_owner, d_owner, s_owner, 'yonetici', 'Owner Phone');
  perform nohut_private.enroll_device(u_mgr,   d_mgr,   s_mgr,   'yonetici', 'Mgr Phone');
  perform nohut_private.enroll_device(u_s1,    d_s1,    s_s1,    'personel', 'Staff 1');
  perform nohut_private.enroll_device(u_s2,    d_s2,    s_s2,    'personel', 'Staff 2');
  perform nohut_private.enroll_device(u_other, d_other, s_other, 'yonetici', 'Other');

  -- 1. Gün Sonu Raporu MUST reject staffHours (owner decision QA-05 superseded)
  begin
    perform nohut_private.apply_daily_report_projection(r1, 21, jsonb_build_object(
      'reports', jsonb_build_array(jsonb_build_object(
        'day', '2026-11-27', 'preliminary', false,
        'report', jsonb_build_object('orderCount', 12, 'staffHours', '[]'::jsonb)
      ))
    ));
    raise exception 'daily report accepted forbidden staffHours';
  exception when invalid_parameter_value then null;
  end;

  -- 2. Apply valid Gün Sonu Raporu
  perform nohut_private.apply_daily_report_projection(r1, 21, jsonb_build_object(
    'reports', jsonb_build_array(jsonb_build_object(
      'day', '2026-11-27', 'preliminary', false, 'calculatedAt', '2026-11-27T21:30:00Z',
      'report', jsonb_build_object(
        'orderCount', 42,
        'sales', jsonb_build_object('grossCents', 1200000, 'refundsCents', 50000, 'netCents', 1150000),
        'collections', jsonb_build_object('cashCents', 600000, 'cardCents', 550000),
        'expenses', jsonb_build_object('totalCents', 250000),
        'netProfitEstimate', 900000
      )
    ))
  ));

  -- Owner sees full report (sales + expenses + netProfitEstimate) and NO staffHours
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_owner, 'role', 'authenticated')::text, true);
  res := public.nohut_daily_report_view(d_owner, 'yonetici', 1, '2026-11-27');
  if (res->>'available')::boolean <> true
     or (res#>>'{report,sales,netCents}')::bigint <> 1150000
     or (res#>>'{report,expenses,totalCents}')::bigint <> 250000
     or (res->'report' ? 'staffHours') then
    raise exception 'owner daily report mismatch: %', res;
  end if;

  -- Müdür (no finance.view) sees sales, but expenses & netProfitEstimate are stripped
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_mgr, 'session_id', s_mgr, 'role', 'authenticated')::text, true);
  res := public.nohut_daily_report_view(d_mgr, 'yonetici', 1, '2026-11-27');
  if (res#>>'{report,sales,netCents}')::bigint <> 1150000
     or (res->'report' ? 'expenses')
     or (res->'report' ? 'netProfitEstimate') then
    raise exception 'mgr daily report leaked expenses: %', res;
  end if;

  -- Personel CANNOT call nohut_daily_report_view
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_s1, 'session_id', s_s1, 'role', 'authenticated')::text, true);
  begin
    perform public.nohut_daily_report_view(d_s1, 'personel', 1, '2026-11-27');
    raise exception 'personel allowed to read daily report';
  exception when insufficient_privilege then null;
  end;

  -- 3. Notifications: daily report (yonetici/dashboard.view) + personal reminder for Staff 1 ONLY
  perform nohut_private.apply_notifications_projection(r1, 22, jsonb_build_object(
    'items', jsonb_build_array(
      jsonb_build_object(
        'id', 'daily:2026-11-27', 'category', 'report.daily', 'severity', 'info',
        'requiredPermission', 'dashboard.view', 'clients', jsonb_build_array('yonetici'),
        'title', 'Gün Sonu Raporu hazır', 'body', '27 Kasım özeti hazır.', 'deepLink', '/daily/2026-11-27',
        'createdAt', '2026-11-27T18:30:00Z'
      ),
      jsonb_build_object(
        'id', 'personal:w2026-11-23:emp3', 'category', 'personal', 'severity', 'info',
        'requiredPermission', 'shifts.self', 'clients', jsonb_build_array('personel'),
        'recipientEmployeeId', 3, 'title', 'Haftalık mesai hatırlatması', 'body', 'Mesailerinizi kontrol edin.',
        'createdAt', '2026-11-27T18:00:00Z'
      )
    )
  ));

  -- Staff 1 sees ONLY their personal reminder (unreadCount = 1), NOT daily report
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_s1, 'session_id', s_s1, 'role', 'authenticated')::text, true);
  res := public.nohut_notifications_list(d_s1, 'personel', 1, 20);
  if jsonb_array_length(res->'items') <> 1 or (res->>'unreadCount')::integer <> 1
     or res#>>'{items,0,id}' <> 'personal:w2026-11-23:emp3' then
    raise exception 'staff 1 notifications mismatch: %', res;
  end if;

  -- Staff 1 marks read -> unreadCount becomes 0
  res := public.nohut_notification_mark_read(d_s1, 'personel', 1, array['personal:w2026-11-23:emp3']);
  if (res->>'marked')::integer <> 1 then raise exception 'mark read failed: %', res; end if;
  res := public.nohut_notifications_list(d_s1, 'personel', 1, 20);
  if (res->>'unreadCount')::integer <> 0 then raise exception 'unreadCount did not drop: %', res; end if;

  -- Staff 2 sees 0 items (never sees Staff 1's personal reminder!)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_s2, 'session_id', s_s2, 'role', 'authenticated')::text, true);
  res := public.nohut_notifications_list(d_s2, 'personel', 1, 20);
  if jsonb_array_length(res->'items') <> 0 then
    raise exception 'staff 2 saw another employee personal notification: %', res;
  end if;

  -- Owner on yonetici sees ONLY daily:2026-11-27
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_owner, 'role', 'authenticated')::text, true);
  res := public.nohut_notifications_list(d_owner, 'yonetici', 1, 20);
  if jsonb_array_length(res->'items') <> 1 or res#>>'{items,0,id}' <> 'daily:2026-11-27' then
    raise exception 'owner notifications mismatch: %', res;
  end if;

  -- Cross-tenant isolation: Tenant 2 sees available:false and 0 notifications
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_other, 'session_id', s_other, 'role', 'authenticated')::text, true);
  res := public.nohut_daily_report_view(d_other, 'yonetici', 1, '2026-11-27');
  if (res->>'available')::boolean <> false then raise exception 'cross-tenant daily report leak'; end if;
  res := public.nohut_notifications_list(d_other, 'yonetici', 1, 20);
  if jsonb_array_length(res->'items') <> 0 then raise exception 'cross-tenant notification leak'; end if;
end $$;

-- Direct table access blocked for authenticated role
set local role authenticated;
do $$
begin
  begin
    perform 1 from nohut_private.daily_report_summaries;
    raise exception 'authenticated read daily_report_summaries directly';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from nohut_private.cloud_notifications;
    raise exception 'authenticated read cloud_notifications directly';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

rollback;
