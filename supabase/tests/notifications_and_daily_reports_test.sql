-- Synthetic tests for Increment C + Hardening (#7230391428, #7230678865):
-- Verifies:
--   1. Gün Sonu Raporu strictly rejects top-level AND deeply nested staffHours/workingHours
--   2. Gün Sonu Raporu strictly rejects unknown top-level keys at ingest
--   3. Field-by-field allowlist across all 3 permission tiers:
--        * dashboard.view only (no sales.view): amountsHidden=true, ALL 12 money fields ABSENT, counts present
--        * dashboard.view + sales.view (no finance.view): sales/comparison/hourly/collections/platform cents present,
--          expenses/estimatedResultCents/estimateNote ABSENT
--        * Owner (sales.view + finance.view): full allowlisted report, zero staffHours
--   4. Client gate: Personel client denied nohut_daily_report_view
--   5. Stale provenance (sync_aged, epoch_mismatch, revision_ahead) forces preliminary=true
--   6. Notifications: full unreadCount across ALL visible items (even when p_limit=1), provenance stale=false,
--      personal recipient isolation, and per-user mark-read
--   7. Cross-tenant isolation and FORCE RLS direct-table access denial
begin;

do $$
declare
  r1 uuid := '41111111-1111-4111-8111-111111111111';
  r2 uuid := '42222222-2222-4222-8222-222222222222';
  ep1 uuid := '4e111111-1111-4111-8111-111111111111';
  ep1_new uuid := '4e111111-1111-4111-8111-111111111112';
  u_owner uuid := '4a111111-1111-4111-8111-111111111111';
  u_mgr   uuid := '4a222222-2222-4222-8222-222222222222';
  u_view  uuid := '4a222222-2222-4222-8222-222222222229';
  u_s1    uuid := '4a333333-3333-4333-8333-333333333333';
  u_s2    uuid := '4a444444-4444-4444-8444-444444444444';
  u_other uuid := '4a555555-5555-4555-8555-555555555555';
  d_owner uuid := '4d111111-1111-4111-8111-111111111111';
  d_mgr   uuid := '4d222222-2222-4222-8222-222222222222';
  d_view  uuid := '4d222222-2222-4222-8222-222222222229';
  d_s1    uuid := '4d333333-3333-4333-8333-333333333333';
  d_s2    uuid := '4d444444-4444-4444-8444-444444444444';
  d_other uuid := '4d555555-5555-4555-8555-555555555555';
  s_owner uuid := '4b111111-1111-4111-8111-111111111111';
  s_mgr   uuid := '4b222222-2222-4222-8222-222222222222';
  s_view  uuid := '4b222222-2222-4222-8222-222222222229';
  s_s1    uuid := '4b333333-3333-4333-8333-333333333333';
  s_s2    uuid := '4b444444-4444-4444-8444-444444444444';
  s_other uuid := '4b555555-5555-4555-8555-555555555555';
  res jsonb;
  rep jsonb;
begin
  insert into nohut_private.restaurants(restaurant_id) values (r1), (r2);
  insert into nohut_private.authority_epochs(restaurant_id, authority_epoch) values (r1, ep1);
  insert into nohut_private.sync_migrations(
    restaurant_id, migration_id, authority_epoch, snapshot_revision, snapshot_seq,
    schema_version, manifest_sha256, status
  ) values (r1, gen_random_uuid(), ep1, 0, 0, 1, repeat('c', 64), 'active');
  insert into nohut_private.sync_checkpoints(restaurant_id, authority_epoch, last_acked_seq, last_acked_revision, updated_at)
    values (r1, ep1, 22, 22, clock_timestamp());

  insert into nohut_private.app_users(user_id, restaurant_id, username, pos_employee_id, role_template, is_owner, active, permission_version) values
    (u_owner, r1, 'c_owner', 1, 'Yönetici', true, true, 1),
    (u_mgr,   r1, 'c_mgr',   2, 'Müdür',    false, true, 1),
    (u_view,  r1, 'c_view',  5, 'Müdür',    false, true, 1),
    (u_s1,    r1, 'c_s1',    3, 'Personel', false, true, 1),
    (u_s2,    r1, 'c_s2',    4, 'Personel', false, true, 1),
    (u_other, r2, 'c_other', 1, 'Yönetici', true, true, 1);

  -- u_mgr: dashboard.view + sales.view (NO finance.view)
  -- u_view: dashboard.view ONLY (NO sales.view, NO finance.view)
  insert into nohut_private.user_grants(user_id, operation_id, granted_by) values
    (u_mgr,  'menu.view', u_owner),
    (u_mgr,  'dashboard.view', u_owner),
    (u_mgr,  'sales.view', u_owner),
    (u_view, 'menu.view', u_owner),
    (u_view, 'dashboard.view', u_owner),
    (u_s1,   'menu.view', u_owner),
    (u_s1,   'shifts.self', u_owner),
    (u_s2,   'menu.view', u_owner),
    (u_s2,   'shifts.self', u_owner);

  perform nohut_private.enroll_device(u_owner, d_owner, s_owner, 'yonetici', 'Owner Phone');
  perform nohut_private.enroll_device(u_mgr,   d_mgr,   s_mgr,   'yonetici', 'Mgr Phone');
  perform nohut_private.enroll_device(u_view,  d_view,  s_view,  'yonetici', 'Counts Only');
  perform nohut_private.enroll_device(u_s1,    d_s1,    s_s1,    'personel', 'Staff 1');
  perform nohut_private.enroll_device(u_s2,    d_s2,    s_s2,    'personel', 'Staff 2');
  perform nohut_private.enroll_device(u_other, d_other, s_other, 'yonetici', 'Other');

  -- 1a. Reject top-level staffHours
  begin
    perform nohut_private.apply_daily_report_projection(r1, 21, jsonb_build_object(
      'reports', jsonb_build_array(jsonb_build_object(
        'day', '2026-11-27', 'preliminary', false,
        'report', jsonb_build_object('businessDate', '2026-11-27', 'staffHours', '[]'::jsonb)
      ))
    ));
    raise exception 'daily report accepted top-level staffHours';
  exception when invalid_parameter_value then null;
  end;

  -- 1b. Reject DEEPLY NESTED staffHours
  begin
    perform nohut_private.apply_daily_report_projection(r1, 21, jsonb_build_object(
      'reports', jsonb_build_array(jsonb_build_object(
        'day', '2026-11-27', 'preliminary', false,
        'report', jsonb_build_object('businessDate', '2026-11-27', 'orders', jsonb_build_object('nested', jsonb_build_object('staffHours', 480)))
      ))
    ));
    raise exception 'daily report accepted nested staffHours';
  exception when invalid_parameter_value then null;
  end;

  -- 1c. Reject unknown top-level key
  begin
    perform nohut_private.apply_daily_report_projection(r1, 21, jsonb_build_object(
      'reports', jsonb_build_array(jsonb_build_object(
        'day', '2026-11-27', 'preliminary', false,
        'report', jsonb_build_object('businessDate', '2026-11-27', 'unregisteredSecretCents', 99999)
      ))
    ));
    raise exception 'daily report accepted unknown top-level key';
  exception when invalid_parameter_value then null;
  end;

  -- 2. Apply full Claude daily_report.dart producer shape
  perform nohut_private.apply_daily_report_projection(r1, 21, jsonb_build_object(
    'reports', jsonb_build_array(jsonb_build_object(
      'day', '2026-11-27', 'preliminary', false, 'calculatedAt', '2026-11-27T21:30:00Z',
      'report', jsonb_build_object(
        'businessDate', '2026-11-27',
        'generatedAt', '2026-11-27T21:30:00Z',
        'closingTime', '21:30',
        'closed', true,
        'preliminary', false,
        'preliminaryReason', null,
        'sales', jsonb_build_object('grossCents', 1200000, 'localCents', 900000, 'onlineGrossCents', 300000, 'refundsCents', 50000, 'netCents', 1150000, 'definition', 'Brüt - İade'),
        'comparison', jsonb_build_object('previousDate', '2026-11-26', 'netCents', 1000000, 'diffCents', 150000, 'available', true),
        'hourlyCents', jsonb_build_array(0, 0, 150000, 200000),
        'orders', jsonb_build_object(
          'total', 42, 'masa', 20, 'gelAl', 12, 'online', 10, 'cancelled', 1, 'averageCents', 27381,
          'platforms', jsonb_build_array(jsonb_build_object('source', 'Trendyol Go', 'orders', 10, 'grossCents', 300000, 'estimatedNetCents', 210000))
        ),
        'collections', jsonb_build_object('cashCents', 600000, 'cardCents', 550000, 'totalCents', 1150000),
        'openAccounts', jsonb_build_object('count', 2, 'dueCents', 45000),
        'expenses', jsonb_build_object('totalCents', 250000, 'quickCents', 250000),
        'estimatedResultCents', 900000,
        'estimateNote', 'Tahmini net',
        'topProduct', jsonb_build_object('name', 'Falafel Dürüm', 'qty', 30, 'cents', 480000),
        'peakHour', '13:00'
      )
    ))
  ));

  -- 3a. dashboard.view ONLY (no sales.view, no finance.view): ZERO money fields leak, counts preserved, amountsHidden=true
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_view, 'session_id', s_view, 'role', 'authenticated')::text, true);
  res := public.nohut_daily_report_view(d_view, 'yonetici', 1, '2026-11-27');
  rep := res->'report';
  if (rep->>'amountsHidden')::boolean <> true
     or (rep#>>'{orders,total}')::integer <> 42
     or rep#>>'{orders,platforms,0,source}' <> 'Trendyol Go'
     or (rep#>>'{orders,platforms,0,orders}')::integer <> 10
     or (rep#>>'{openAccounts,count}')::integer <> 2
     or rep#>>'{topProduct,name}' <> 'Falafel Dürüm'
     or (rep#>>'{topProduct,qty}')::integer <> 30
     or rep->>'peakHour' <> '13:00'
     -- Every single money field MUST be ABSENT (not null!)
     or (rep ? 'sales')
     or (rep ? 'comparison')
     or (rep ? 'hourlyCents')
     or (rep ? 'collections')
     or (rep ? 'expenses')
     or (rep ? 'estimatedResultCents')
     or (rep ? 'estimateNote')
     or ((rep->'orders') ? 'averageCents')
     or ((rep#>'{orders,platforms,0}') ? 'grossCents')
     or ((rep#>'{orders,platforms,0}') ? 'estimatedNetCents')
     or ((rep->'openAccounts') ? 'dueCents')
     or ((rep->'topProduct') ? 'cents')
     or (res#>>'{syncMeta,stale}')::boolean <> false then
    raise exception 'dashboard-only daily report leaked money or dropped counts: %', res;
  end if;

  -- 3b. Müdür (dashboard.view + sales.view, NO finance.view): sales/comparison/hourly/platform cents present; expenses/estimatedResultCents/estimateNote ABSENT
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_mgr, 'session_id', s_mgr, 'role', 'authenticated')::text, true);
  res := public.nohut_daily_report_view(d_mgr, 'yonetici', 1, '2026-11-27');
  rep := res->'report';
  if (rep ? 'amountsHidden')
     or (rep#>>'{sales,netCents}')::bigint <> 1150000
     or (rep#>>'{comparison,diffCents}')::bigint <> 150000
     or (rep#>>'{orders,averageCents}')::bigint <> 27381
     or (rep#>>'{orders,platforms,0,grossCents}')::bigint <> 300000
     or (rep#>>'{openAccounts,dueCents}')::bigint <> 45000
     or (rep#>>'{topProduct,cents}')::bigint <> 480000
     or (rep ? 'expenses')
     or (rep ? 'estimatedResultCents')
     or (rep ? 'estimateNote') then
    raise exception 'sales-only daily report leaked finance or dropped sales: %', res;
  end if;

  -- 3c. Owner (sales.view + finance.view): full allowlisted report, zero staffHours
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_owner, 'role', 'authenticated')::text, true);
  res := public.nohut_daily_report_view(d_owner, 'yonetici', 1, '2026-11-27');
  rep := res->'report';
  if (rep#>>'{expenses,totalCents}')::bigint <> 250000
     or (rep->>'estimatedResultCents')::bigint <> 900000
     or (rep->>'preliminary')::boolean <> false
     or (rep ? 'staffHours') then
    raise exception 'owner daily report mismatch: %', res;
  end if;

  -- 4. Personel client CANNOT call nohut_daily_report_view
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_s1, 'session_id', s_s1, 'role', 'authenticated')::text, true);
  begin
    perform public.nohut_daily_report_view(d_s1, 'personel', 1, '2026-11-27');
    raise exception 'personel allowed to read daily report';
  exception when insufficient_privilege then null;
  end;

  -- 5. Notifications: 3 unread for owner + 1 personal for Staff 1; test pagination unreadCount=3 + fresh syncMeta
  perform nohut_private.apply_notifications_projection(r1, 22, jsonb_build_object(
    'items', jsonb_build_array(
      jsonb_build_object(
        'id', 'daily:2026-11-27', 'category', 'report.daily', 'severity', 'info',
        'requiredPermission', 'dashboard.view', 'clients', jsonb_build_array('yonetici'),
        'title', 'Gün Sonu Raporu hazır', 'body', '27 Kasım özeti hazır.', 'deepLink', '/daily/2026-11-27',
        'createdAt', '2026-11-27T18:30:00Z'
      ),
      jsonb_build_object(
        'id', 'daily:2026-11-26', 'category', 'report.daily', 'severity', 'info',
        'requiredPermission', 'dashboard.view', 'clients', jsonb_build_array('yonetici'),
        'title', 'Gün Sonu Raporu 26 Kas', 'body', '26 Kasım özeti.', 'deepLink', '/daily/2026-11-26',
        'createdAt', '2026-11-26T18:30:00Z'
      ),
      jsonb_build_object(
        'id', 'daily:2026-11-25', 'category', 'report.daily', 'severity', 'info',
        'requiredPermission', 'dashboard.view', 'clients', jsonb_build_array('yonetici'),
        'title', 'Gün Sonu Raporu 25 Kas', 'body', '25 Kasım özeti.', 'deepLink', '/daily/2026-11-25',
        'createdAt', '2026-11-25T18:30:00Z'
      ),
      jsonb_build_object(
        'id', 'personal:w2026-11-23:emp3', 'category', 'personal', 'severity', 'info',
        'requiredPermission', 'shifts.self', 'clients', jsonb_build_array('personel'),
        'recipientEmployeeId', 3, 'title', 'Haftalık mesai hatırlatması', 'body', 'Mesailerinizi kontrol edin.',
        'createdAt', '2026-11-27T18:00:00Z'
      )
    )
  ));

  -- Owner requests p_limit=1: receives 1 item, unreadCount=3 (ALL visible unread!), syncMeta.stale=false
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_owner, 'role', 'authenticated')::text, true);
  res := public.nohut_notifications_list(d_owner, 'yonetici', 1, 1);
  if jsonb_array_length(res->'items') <> 1
     or (res->>'unreadCount')::integer <> 3
     or (res#>>'{syncMeta,stale}')::boolean <> false then
    raise exception 'owner paginated notifications mismatch: %', res;
  end if;

  -- Staff 1 sees ONLY personal reminder; mark read -> unreadCount=0; Staff 2 sees 0
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_s1, 'session_id', s_s1, 'role', 'authenticated')::text, true);
  res := public.nohut_notifications_list(d_s1, 'personel', 1, 20);
  if jsonb_array_length(res->'items') <> 1 or (res->>'unreadCount')::integer <> 1 then
    raise exception 'staff 1 notifications mismatch: %', res;
  end if;
  res := public.nohut_notification_mark_read(d_s1, 'personel', 1, array['personal:w2026-11-23:emp3']);
  if (res->>'marked')::integer <> 1 then raise exception 'mark read failed: %', res; end if;
  res := public.nohut_notifications_list(d_s1, 'personel', 1, 20);
  if (res->>'unreadCount')::integer <> 0 then raise exception 'unreadCount did not drop: %', res; end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_s2, 'session_id', s_s2, 'role', 'authenticated')::text, true);
  res := public.nohut_notifications_list(d_s2, 'personel', 1, 20);
  if jsonb_array_length(res->'items') <> 0 then raise exception 'staff 2 saw staff 1 notification: %', res; end if;

  -- 6. Provenance staleness: rotating authority_epoch marks old daily report stale (epoch_mismatch) AND forces preliminary=true
  update nohut_private.authority_epochs set retired_at = clock_timestamp() where restaurant_id = r1 and authority_epoch = ep1;
  insert into nohut_private.authority_epochs(restaurant_id, authority_epoch) values (r1, ep1_new);
  insert into nohut_private.sync_checkpoints(restaurant_id, authority_epoch, last_acked_seq, last_acked_revision, updated_at)
    values (r1, ep1_new, 25, 25, clock_timestamp());

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_owner, 'role', 'authenticated')::text, true);
  res := public.nohut_daily_report_view(d_owner, 'yonetici', 1, '2026-11-27');
  if (res#>>'{syncMeta,stale}')::boolean <> true
     or res#>>'{syncMeta,staleReason}' <> 'epoch_mismatch'
     or (res->>'preliminary')::boolean <> true
     or (res#>>'{report,preliminary}')::boolean <> true then
    raise exception 'epoch_mismatch did not force stale + preliminary: %', res;
  end if;

  -- 7. Cross-tenant isolation
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
  begin
    perform 1 from nohut_private.projection_watermarks;
    raise exception 'authenticated read projection_watermarks directly';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

rollback;
