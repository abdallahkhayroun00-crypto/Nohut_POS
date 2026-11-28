-- Synthetic SQL integration test for Increment F (Phase 6 Cloud Sales Analytics: SalesView)
begin;

do $$
declare
  r_a uuid := 'f1000000-0000-4000-8000-000000000001';
  r_b uuid := 'f2000000-0000-4000-8000-000000000002';
  tok_a text := repeat('a', 64);
  tok_b text := repeat('b', 64);
  u_owner_a uuid := 'f1000000-0000-4000-8000-000000000011';
  u_staff_a uuid := 'f1000000-0000-4000-8000-000000000012';
  u_owner_b uuid := 'f2000000-0000-4000-8000-000000000021';
  dev_owner_a uuid := 'f1000000-0000-4000-8000-000000000111';
  dev_staff_a uuid := 'f1000000-0000-4000-8000-000000000112';
  dev_owner_b uuid := 'f2000000-0000-4000-8000-000000000121';
  ses_owner_a uuid := 'f1000000-0000-4000-8000-000000000211';
  ses_staff_a uuid := 'f1000000-0000-4000-8000-000000000212';
  ses_owner_b uuid := 'f2000000-0000-4000-8000-000000000221';
  v_heatmap jsonb;
  v_payload jsonb;
  v_res jsonb;
  v_caught boolean;
begin
  -- Build a valid 7x24 integer heatmap
  select jsonb_agg(row_arr) into v_heatmap
  from (
    select (select jsonb_agg(case when d = 4 and h = 13 then 12 else 0 end) from generate_series(0, 23) h) as row_arr
    from generate_series(0, 6) d
  ) t;

  -- Seed synthetic restaurants, epochs, users, devices, sessions & active Windows agents
  insert into nohut_private.restaurants(restaurant_id) values (r_a), (r_b);
  insert into nohut_private.authority_epochs(restaurant_id, authority_epoch)
    values (r_a, 'f1000000-0000-4000-8000-000000000091'),
           (r_b, 'f2000000-0000-4000-8000-000000000092');

  insert into nohut_private.app_users(user_id, restaurant_id, username, pos_employee_id, role_template, is_owner)
  values
    (u_owner_a, r_a, 'owner_sales_a', 1, 'Yönetici', true),
    (u_staff_a, r_a, 'staff_sales_a', 2, 'Personel', false),
    (u_owner_b, r_b, 'owner_sales_b', 1, 'Yönetici', true);

  perform nohut_private.enroll_device(u_owner_a, dev_owner_a, ses_owner_a, 'yonetici', 'Owner A Phone');
  perform nohut_private.enroll_device(u_staff_a, dev_staff_a, ses_staff_a, 'personel', 'Staff A Phone');
  perform nohut_private.enroll_device(u_owner_b, dev_owner_b, ses_owner_b, 'yonetici', 'Owner B Phone');

  insert into nohut_private.windows_agents(restaurant_id, authority_epoch, windows_device_id, token_sha256, expires_at)
  values
    (r_a, 'f1000000-0000-4000-8000-000000000091', 'f1000000-0000-4000-8000-000000000401', sha256(convert_to(tok_a, 'UTF8')), now() + interval '1 day'),
    (r_b, 'f2000000-0000-4000-8000-000000000092', 'f2000000-0000-4000-8000-000000000402', sha256(convert_to(tok_b, 'UTF8')), now() + interval '1 day');

  -- 1. Empty state returns sales=null cleanly (never 500)
  perform set_config('request.jwt.claims', json_build_object('sub', u_owner_a, 'session_id', ses_owner_a)::text, true);
  v_res := public.nohut_sales_analytics_view(dev_owner_a, 'yonetici', 1, 'week');
  assert v_res->>'status' = 'ok', 'empty read must return ok';
  assert v_res->'sales' = 'null'::jsonb, 'empty read must return null sales';
  assert (v_res->'syncMeta'->>'hasData')::boolean = false, 'empty hasData must be false';

  -- 2. Valid Windows agent push succeeds
  v_payload := jsonb_build_object(
    'range', 'week',
    'businessDay', '2026-11-28',
    'from', '2026-11-23',
    'to', '2026-11-29',
    'daily', jsonb_build_array(
      jsonb_build_object(
        'day', '2026-11-28', 'cashCents', 150000, 'cardCents', 250000,
        'otherCents', 0, 'platformCents', 80000, 'refundCents', 10000,
        'netCents', 390000, 'orderCount', 42, 'masaCount', 28, 'gelalCount', 14, 'onlineCount', 9
      )
    ),
    'topProducts', jsonb_build_array(
      jsonb_build_object('name', 'Falafel Dürüm', 'category', 'Dürümler', 'qty', 35, 'grossCents', 560000)
    ),
    'heatmap', v_heatmap,
    'platforms', jsonb_build_array(
      jsonb_build_object('source', 'Trendyol GO', 'orders', 9, 'grossCents', 80000)
    ),
    'totals', jsonb_build_object('netCents', 390000, 'orderCount', 42, 'averageCents', 9286),
    'note', 'Tahsilatlar kasadaki Masa ve Gel-Al ödemeleridir.',
    'calculatedAt', '2026-11-28T14:30:00Z',
    'sourceRevision', 10
  );

  v_res := public.nohut_agent_report_sales_analytics(tok_a, v_payload);
  assert v_res->>'status' = 'ok' and (v_res->>'sourceRevision')::bigint = 10, 'agent push failed';

  -- 3. Stale revision is ignored (monotonic guard)
  v_res := public.nohut_agent_report_sales_analytics(tok_a, jsonb_set(v_payload, '{sourceRevision}', '5'::jsonb));
  assert v_res->>'status' = 'stale_ignored' and (v_res->>'currentRevision')::bigint = 10, 'stale revision must be ignored';

  -- 4. Reject invalid heatmap dimensions (6 rows instead of 7)
  v_caught := false;
  begin
    perform public.nohut_agent_report_sales_analytics(tok_a, jsonb_set(v_payload, '{heatmap}', '[[]]'::jsonb));
  exception when data_exception then
    v_caught := true;
  end;
  assert v_caught, 'invalid heatmap must be rejected';

  -- 5. Reject forbidden secret keys in payload
  v_caught := false;
  begin
    perform public.nohut_agent_report_sales_analytics(tok_a, v_payload || jsonb_build_object('apiKey', 'leaked'));
  exception when insufficient_privilege then
    v_caught := true;
  end;
  assert v_caught, 'secret key in sales payload must be rejected';

  -- 6. Authorized owner reads exact SalesView payload
  perform set_config('request.jwt.claims', json_build_object('sub', u_owner_a, 'session_id', ses_owner_a)::text, true);
  v_res := public.nohut_sales_analytics_view(dev_owner_a, 'yonetici', 1, 'week');
  assert v_res->>'status' = 'ok', 'owner read must succeed';
  assert v_res->'sales'->>'range' = 'week', 'range mismatch';
  assert jsonb_array_length(v_res->'sales'->'heatmap') = 7, 'heatmap rows mismatch';
  assert (v_res->'sales'->'heatmap'->4->13)::int = 12, 'heatmap cell mismatch';
  assert (v_res->'sales'->'topProducts'->0->>'name') = 'Falafel Dürüm', 'topProducts mismatch';
  assert (v_res->'syncMeta'->>'sourceRevision')::bigint = 10, 'revision mismatch';

  -- 7. Staff without sales.view is rejected
  perform set_config('request.jwt.claims', json_build_object('sub', u_staff_a, 'session_id', ses_staff_a)::text, true);
  v_res := public.nohut_sales_analytics_view(dev_staff_a, 'personel', 1, 'week');
  assert v_res->>'status' = 'forbidden', 'staff without sales.view must be forbidden';

  -- 8. Tenant isolation: Owner B sees null, never Restaurant A's sales
  perform set_config('request.jwt.claims', json_build_object('sub', u_owner_b, 'session_id', ses_owner_b)::text, true);
  v_res := public.nohut_sales_analytics_view(dev_owner_b, 'yonetici', 1, 'week');
  assert v_res->>'status' = 'ok' and v_res->'sales' = 'null'::jsonb, 'tenant B must not see tenant A sales';
end $$;

rollback;
