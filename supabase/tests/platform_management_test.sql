-- Synthetic tests for Increment E (Platform Yönetimi control plane):
--   * platform.view & platform.store.toggle permission enforcement
--   * fixed 3-provider PlatformCard wire shape (trendyol_go, yemeksepeti, migros_yemek)
--   * fail-closed guards: confirmation, provider_unavailable, unverified_store,
--     stale_status (>10m), status_mismatch, pending_mutation_in_flight
--   * idempotent duplicate vs conflict on same request_id
--   * lost-response unknown outcome locked until readback reconciliation
--   * append-only platform_status_audit immutability
--   * cross-restaurant isolation
begin;

do $$
declare
  r1 uuid := 'e1000000-0000-4000-8000-000000000001';
  r2 uuid := 'e2000000-0000-4000-8000-000000000002';
  ep1 uuid := 'e1000000-0000-4000-8000-000000000011';
  ep2 uuid := 'e2000000-0000-4000-8000-000000000012';
  u_owner uuid := 'e1000000-0000-4000-8000-000000000101';
  u_staff uuid := 'e1000000-0000-4000-8000-000000000102';
  u_other uuid := 'e2000000-0000-4000-8000-000000000103';
  d_owner uuid := 'e1000000-0000-4000-8000-000000000201';
  d_staff uuid := 'e1000000-0000-4000-8000-000000000202';
  d_other uuid := 'e2000000-0000-4000-8000-000000000203';
  s_owner uuid := 'e1000000-0000-4000-8000-000000000301';
  s_staff uuid := 'e1000000-0000-4000-8000-000000000302';
  s_other uuid := 'e2000000-0000-4000-8000-000000000303';
  w_dev uuid := 'e1000000-0000-4000-8000-000000000401';
  agent_token text := repeat('e', 64);
  req1 uuid := 'e1000000-0000-4000-8000-000000000501';
  req2 uuid := 'e1000000-0000-4000-8000-000000000502';
  req_ref uuid := 'e1000000-0000-4000-8000-000000000503';
  req_rec uuid := 'e1000000-0000-4000-8000-000000000504';
  res jsonb;
  card jsonb;
  caught boolean;
begin
  -- Seed two isolated restaurants + epochs + active migrations + users + devices + Windows agent
  insert into nohut_private.restaurants(restaurant_id) values (r1), (r2);
  insert into nohut_private.authority_epochs(restaurant_id, authority_epoch) values (r1, ep1), (r2, ep2);
  insert into nohut_private.sync_migrations(restaurant_id, migration_id, authority_epoch, snapshot_revision, snapshot_seq, schema_version, manifest_sha256, status)
    values (r1, gen_random_uuid(), ep1, 1, 1, 1, repeat('a', 64), 'active'),
           (r2, gen_random_uuid(), ep2, 1, 1, 1, repeat('b', 64), 'active');
  insert into nohut_private.sync_checkpoints(restaurant_id, authority_epoch) values (r1, ep1), (r2, ep2);

  insert into nohut_private.app_users(user_id, restaurant_id, username, pos_employee_id, role_template, is_owner)
    values (u_owner, r1, 'syn_plat_owner', 1, 'Yönetici', true),
           (u_staff, r1, 'syn_plat_staff', 2, 'Personel', false),
           (u_other, r2, 'syn_plat_other', 1, 'Yönetici', true);

  perform nohut_private.enroll_device(u_owner, d_owner, s_owner, 'yonetici', 'Owner Phone');
  perform nohut_private.enroll_device(u_staff, d_staff, s_staff, 'personel', 'Staff Phone');
  perform nohut_private.enroll_device(u_other, d_other, s_other, 'yonetici', 'Other Owner Phone');

  insert into nohut_private.windows_agents(restaurant_id, authority_epoch, windows_device_id, token_sha256, expires_at)
    values (r1, ep1, w_dev, sha256(convert_to(agent_token, 'UTF8')), now() + interval '1 day');

  -- 1. Staff without platform.view is forbidden
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_staff, 'session_id', s_staff, 'aal', 'aal1')::text, true);
  set local role authenticated;
  caught := false;
  begin
    perform public.nohut_platform_cards_view(d_staff, 'personel', 1);
  exception when insufficient_privilege then caught := true;
  end;
  if not caught then raise exception 'staff without platform.view must be denied'; end if;

  -- 2. Owner sees all 3 cards in fixed order even before any provider readback
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_owner, 'aal', 'aal2')::text, true);
  res := public.nohut_platform_cards_view(d_owner, 'yonetici', 1);
  if jsonb_array_length(res->'cards') <> 3
    or res->'cards'->0->>'provider' <> 'trendyol_go'
    or res->'cards'->1->>'provider' <> 'yemeksepeti'
    or res->'cards'->2->>'provider' <> 'migros_yemek'
    or res->'cards'->0->>'connectionState' <> 'not_connected' then
    raise exception 'expected 3 fixed-order default cards, got %', res;
  end if;

  -- 3. Unconnected provider toggle is rejected (provider_unavailable)
  caught := false;
  begin
    perform public.nohut_platform_enqueue_status_set(d_owner, 'yonetici', 1, req1, 'yemeksepeti', 'CLOSED', 'OPEN', true, null);
  exception when invalid_parameter_value then caught := true;
  end;
  if not caught then raise exception 'unconnected provider must be rejected'; end if;

  -- 4. Windows agent reports stale Trendyol GO readback (> 10 minutes old)
  reset role;
  set local role anon;
  perform public.nohut_agent_report_platform_state(
    agent_token, 'trendyol_go', 'connected', 'OPEN',
    '316490', 'Synthetic Store', now() - interval '15 minutes',
    'within_hours',
    '[{"dayOfWeek":"MONDAY","openingTime":"09:00:00","closingTime":"22:00:00"}]'::jsonb,
    true, false, false, null, 10
  );

  -- Stale readback (>10m) must refuse toggle
  reset role;
  set local role authenticated;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_owner, 'aal', 'aal2')::text, true);
  caught := false;
  begin
    perform public.nohut_platform_enqueue_status_set(d_owner, 'yonetici', 1, req1, 'trendyol_go', 'CLOSED', 'OPEN', true, 'test');
  exception when invalid_parameter_value then caught := true;
  end;
  if not caught then raise exception 'stale readback (>10m) must be refused'; end if;

  -- 5. Windows agent reports fresh Trendyol GO readback (OPEN)
  reset role;
  set local role anon;
  perform public.nohut_agent_report_platform_state(
    agent_token, 'trendyol_go', 'connected', 'OPEN',
    '316490', 'Synthetic Store', now(),
    'within_hours',
    '[{"dayOfWeek":"MONDAY","openingTime":"09:00:00","closingTime":"22:00:00"}]'::jsonb,
    true, false, false, null, 11
  );

  -- 6. Confirmation required (confirmed=false rejected) and status_mismatch rejected
  reset role;
  set local role authenticated;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_owner, 'aal', 'aal2')::text, true);
  caught := false;
  begin
    perform public.nohut_platform_enqueue_status_set(d_owner, 'yonetici', 1, req1, 'trendyol_go', 'CLOSED', 'OPEN', false, null);
  exception when invalid_parameter_value then caught := true;
  end;
  if not caught then raise exception 'confirmed=false must be refused'; end if;

  caught := false;
  begin
    perform public.nohut_platform_enqueue_status_set(d_owner, 'yonetici', 1, req1, 'trendyol_go', 'OPEN', 'CLOSED', true, null);
  exception when invalid_parameter_value then caught := true;
  end;
  if not caught then raise exception 'status_mismatch must be refused'; end if;

  -- 7. Staff with platform.view ONLY still cannot toggle store
  reset role;
  insert into nohut_private.user_grants(user_id, operation_id, granted_by)
    values (u_staff, 'platform.view', u_owner);
  update nohut_private.app_users set permission_version = 2 where user_id = u_staff;
  set local role authenticated;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_staff, 'session_id', s_staff, 'aal', 'aal1')::text, true);
  res := public.nohut_platform_cards_view(d_staff, 'personel', 2);
  if res->'cards'->0->>'workingStatus' <> 'OPEN' then raise exception 'staff with platform.view should read card'; end if;
  caught := false;
  begin
    perform public.nohut_platform_enqueue_status_set(d_staff, 'personel', 2, req1, 'trendyol_go', 'CLOSED', 'OPEN', true, null);
  exception when insufficient_privilege then caught := true;
  end;
  if not caught then raise exception 'staff without platform.store.toggle must be denied'; end if;

  -- 8. Owner enqueues valid OPEN -> CLOSED toggle (accepted), retry returns duplicate, mutated payload returns conflict
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_owner, 'aal', 'aal2')::text, true);
  res := public.nohut_platform_enqueue_status_set(d_owner, 'yonetici', 1, req1, 'trendyol_go', 'CLOSED', 'OPEN', true, 'Yoğunluk');
  if res->>'status' <> 'accepted' then raise exception 'expected accepted, got %', res; end if;

  res := public.nohut_platform_enqueue_status_set(d_owner, 'yonetici', 1, req1, 'trendyol_go', 'CLOSED', 'OPEN', true, 'Yoğunluk');
  if res->>'status' <> 'duplicate' then raise exception 'expected duplicate, got %', res; end if;

  res := public.nohut_platform_enqueue_status_set(d_owner, 'yonetici', 1, req1, 'trendyol_go', 'CLOSED', 'OPEN', true, 'Different reason');
  if res->>'status' <> 'conflict' then raise exception 'expected conflict, got %', res; end if;

  -- Second distinct request_id while pending must be rejected (pending_mutation_in_flight)
  caught := false;
  begin
    perform public.nohut_platform_enqueue_status_set(d_owner, 'yonetici', 1, req2, 'trendyol_go', 'CLOSED', 'OPEN', true, null);
  exception when invalid_parameter_value then caught := true;
  end;
  if not caught then raise exception 'concurrent toggle while pending must be refused'; end if;

  -- Refresh command works with platform.view
  res := public.nohut_platform_enqueue_refresh(d_owner, 'yonetici', 1, req_ref, 'trendyol_go');
  if res->>'status' <> 'accepted' then raise exception 'expected refresh accepted, got %', res; end if;

  -- 9. Windows agent reports lost-response UNKNOWN outcome -> stays locked even across report_platform_state
  reset role;
  set local role anon;
  perform public.nohut_agent_resolve_platform_mutation(agent_token, 'trendyol_go', req1, 'unknown', null, null, 'syn_plat_owner', 'HTTP 504 timeout');
  perform public.nohut_agent_report_platform_state(
    agent_token, 'trendyol_go', 'connected', 'OPEN',
    '316490', 'Synthetic Store', now(), 'within_hours', '[]'::jsonb, true, false, false, null, 12
  );

  reset role;
  set local role authenticated;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_owner, 'aal', 'aal2')::text, true);
  res := public.nohut_platform_cards_view(d_owner, 'yonetici', 1);
  card := res->'cards'->0;
  if card->'pendingMutation'->>'outcome' <> 'unknown'
    or card->'pendingMutation'->>'requestId' <> req1::text then
    raise exception 'unknown pendingMutation must remain locked, got %', card;
  end if;

  -- Reconcile command succeeds for unknown mutation
  res := public.nohut_platform_enqueue_reconcile(d_owner, 'yonetici', 1, req_rec, 'trendyol_go', req1);
  if res->>'status' <> 'accepted' then raise exception 'expected reconcile accepted, got %', res; end if;

  -- 10. Readback confirms CLOSED -> pendingMutation cleared, workingStatus=CLOSED, audit has 3 entries
  reset role;
  set local role anon;
  perform public.nohut_agent_resolve_platform_mutation(agent_token, 'trendyol_go', req1, 'confirmed', 'CLOSED', now(), 'syn_plat_owner', 'Verified via GET /stores');

  reset role;
  set local role authenticated;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_owner, 'aal', 'aal2')::text, true);
  res := public.nohut_platform_cards_view(d_owner, 'yonetici', 1);
  card := res->'cards'->0;
  if card->>'workingStatus' <> 'CLOSED'
    or (card->'pendingMutation') is distinct from 'null'::jsonb
    or jsonb_array_length(card->'auditHistory') <> 3 then
    raise exception 'expected confirmed CLOSED with 3 audit rows, got %', card;
  end if;

  -- 11. Cross-restaurant isolation: r2 owner sees default not_connected, zero r1 audit rows
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_other, 'session_id', s_other, 'aal', 'aal2')::text, true);
  res := public.nohut_platform_cards_view(d_other, 'yonetici', 1);
  if res->'cards'->0->>'connectionState' <> 'not_connected'
    or jsonb_array_length(res->'cards'->0->'auditHistory') <> 0 then
    raise exception 'cross-restaurant isolation violated: %', res;
  end if;

  -- 12. Append-only audit immutability
  reset role;
  caught := false;
  begin
    update nohut_private.platform_status_audit set outcome = 'failed' where restaurant_id = r1;
  exception when insufficient_privilege then caught := true;
  end;
  if not caught then raise exception 'platform_status_audit update must be denied'; end if;

  caught := false;
  begin
    delete from nohut_private.platform_status_audit where restaurant_id = r1;
  exception when insufficient_privilege then caught := true;
  end;
  if not caught then raise exception 'platform_status_audit delete must be denied'; end if;

  -- 13. Expired unclaimed 'pending' lock auto-clears on read/enqueue (never clears 'unknown')
  set local role authenticated;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_owner, 'aal', 'aal2')::text, true);
  res := public.nohut_platform_enqueue_status_set(d_owner, 'yonetici', 1, req2, 'trendyol_go', 'OPEN', 'CLOSED', true, 'Reopen test');
  if res->>'status' <> 'accepted' then raise exception 'expected req2 accepted, got %', res; end if;

  -- Simulate TTL expiry while still unclaimed (lease_generation = 0, state = 'pending')
  reset role;
  update nohut_private.commands
     set issued_at = now() - interval '6 minutes',
         expires_at = now() - interval '1 minute',
         envelope = envelope || jsonb_build_object(
           'issued_at', now() - interval '6 minutes',
           'expires_at', now() - interval '1 minute'
         )
   where restaurant_id = r1 and request_id = req2::text;

  set local role authenticated;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_owner, 'aal', 'aal2')::text, true);
  res := public.nohut_platform_cards_view(d_owner, 'yonetici', 1);
  card := res->'cards'->0;
  if (card->'pendingMutation') is distinct from 'null'::jsonb then
    raise exception 'expired unclaimed pending lock must auto-clear, got %', card;
  end if;

  -- 14. Atomic public.nohut_agent_validate_and_read_claim (tenant + epoch scoped)
  reset role;
  set local role anon;
  res := public.nohut_agent_validate_and_read_claim(agent_token, req2, 1, repeat('0', 64));
  if (res->>'valid')::boolean is not false then
    raise exception 'expired/unclaimed command must return valid=false, got %', res;
  end if;
end $$;

rollback;
