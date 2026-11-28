-- Synthetic tests for Increment D (P0 Backend & Security):
--   1. Full draftSha256 REQUIRED on qr_menu_publish (missing draftSha256 rejected 22023)
--   2. First database synchronization: pre-sync backup required, idempotent begin/batch upload,
--      offline resume via nohut_agent_migration_status, batch-count & manifest verification,
--      atomic activation + checkpoint initialization, and seamless incremental ingest afterward
--   3. Safe abort of incomplete migration (and refusal to abort active migration)
--   4. Immediate revocation enforcement when Windows agent token is revoked
begin;

do $$
declare
  r1 uuid := '51111111-1111-4111-8111-111111111111';
  ep1 uuid := '5e111111-1111-4111-8111-111111111111';
  mig1 uuid := '5f111111-1111-4111-8111-111111111111';
  mig_abort uuid := '5f222222-2222-4222-8222-222222222222';
  b1 uuid := '5b111111-1111-4111-8111-111111111111';
  b2 uuid := '5b222222-2222-4222-8222-222222222222';
  u_owner uuid := '5a111111-1111-4111-8111-111111111111';
  d_win uuid := '5d111111-1111-4111-8111-111111111111';
  d_phone uuid := '5d222222-2222-4222-8222-222222222222';
  s_phone uuid := '5c222222-2222-4222-8222-222222222222';
  req1 uuid := '59111111-1111-4111-8111-111111111111';
  agent_token text := repeat('9', 64);
  manifest text := repeat('a', 64);
  hash1 text := repeat('1', 64);
  hash2 text := repeat('2', 64);
  res jsonb;
begin
  insert into nohut_private.restaurants(restaurant_id) values (r1);
  insert into nohut_private.authority_epochs(restaurant_id, authority_epoch) values (r1, ep1);
  insert into nohut_private.app_users(user_id, restaurant_id, username, pos_employee_id, role_template, is_owner, active, permission_version)
    values (u_owner, r1, 'init_owner', 1, 'Yönetici', true, true, 1);
  perform nohut_private.enroll_device(u_owner, d_phone, s_phone, 'yonetici', 'Owner Phone');

  -- Provision scoped Windows agent directly for synthetic test
  insert into nohut_private.windows_agents(
    agent_id, restaurant_id, authority_epoch, windows_device_id, token_sha256, expires_at
  ) values (
    gen_random_uuid(), r1, ep1, d_win,
    sha256(convert_to(agent_token, 'UTF8')), clock_timestamp() + interval '1 day'
  );

  -- 1. Pre-sync backup verification MUST be true
  begin
    perform public.nohut_agent_begin_initial_sync(agent_token, mig1, 100, 50, manifest, false);
    raise exception 'initial sync started without verified backup';
  exception when insufficient_privilege then null;
  end;

  -- 2. Begin & safely abort an incomplete migration
  res := public.nohut_agent_begin_initial_sync(agent_token, mig_abort, 90, 40, manifest, true);
  if res->>'status' <> 'accepted' then raise exception 'begin mig_abort failed: %', res; end if;
  res := public.nohut_agent_abort_initial_sync(agent_token, mig_abort, 'owner cancelled');
  if res->>'status' <> 'safely_aborted' then raise exception 'abort failed: %', res; end if;

  -- 3. Begin real initial sync + idempotent retry + conflict check
  res := public.nohut_agent_begin_initial_sync(agent_token, mig1, 100, 50, manifest, true);
  if res->>'status' <> 'accepted' then raise exception 'begin mig1 failed: %', res; end if;

  res := public.nohut_agent_begin_initial_sync(agent_token, mig1, 100, 50, manifest, true);
  if res->>'status' <> 'duplicate' then raise exception 'expected duplicate begin: %', res; end if;

  res := public.nohut_agent_begin_initial_sync(agent_token, mig1, 100, 50, repeat('b', 64), true);
  if res->>'status' <> 'conflict' then raise exception 'expected conflict begin: %', res; end if;

  -- 4. Upload snapshot batch 1 (employees) + idempotent retry + tampered conflict
  res := public.nohut_agent_upload_snapshot_batch(agent_token, mig1, b1, 'employees', 1, hash1, jsonb_build_array(
    jsonb_build_object('entity_type', 'employees', 'entity_id', 'core', 'payload', jsonb_build_array(
      jsonb_build_object('id', 1, 'name', 'Synthetic Owner', 'active', true, 'payrollEligible', false)
    ))
  ));
  if res->>'status' <> 'accepted' then raise exception 'batch 1 failed: %', res; end if;

  res := public.nohut_agent_upload_snapshot_batch(agent_token, mig1, b1, 'employees', 1, hash1, '[]'::jsonb);
  if res->>'status' <> 'duplicate' then raise exception 'expected duplicate batch 1: %', res; end if;

  res := public.nohut_agent_upload_snapshot_batch(agent_token, mig1, b1, 'employees', 1, hash2, '[]'::jsonb);
  if res->>'status' <> 'conflict' then raise exception 'expected conflict batch 1: %', res; end if;

  -- 5. Simulate offline crash & resume: migration_status lists batch 1 and shows uploading
  res := public.nohut_agent_migration_status(agent_token, mig1);
  if (res->>'exists')::boolean <> true or res->>'status' <> 'uploading' or jsonb_array_length(res->'batches') <> 1 then
    raise exception 'unexpected migration status mid-upload: %', res;
  end if;

  -- 6. Activation MUST fail when batch count is incomplete
  begin
    perform public.nohut_agent_activate_initial_sync(agent_token, mig1, 2, manifest);
    raise exception 'activated with missing batch';
  exception when invalid_parameter_value then null;
  end;

  -- 7. Upload batch 2 (qrMenuState) and activate cleanly
  res := public.nohut_agent_upload_snapshot_batch(agent_token, mig1, b2, 'qrMenuState', 1, hash2, jsonb_build_array(
    jsonb_build_object('entity_type', 'qrMenuState', 'entity_id', 'core', 'payload', jsonb_build_object(
      'available', true, 'stamp', '0123456789abcdef', 'revision', 'rev-init-1', 'revisionLabel', 'rev-init',
      'offline', false, 'pendingPublish', false, 'link', 'ready',
      'changes', '[]'::jsonb, 'catalog', '{"categories":[],"products":[],"campaigns":[]}'::jsonb
    ))
  ));
  if res->>'status' <> 'accepted' then raise exception 'batch 2 failed: %', res; end if;

  res := public.nohut_agent_activate_initial_sync(agent_token, mig1, 2, manifest);
  if res->>'status' <> 'accepted' or res->>'migration_status' <> 'active'
     or (res->>'snapshot_seq')::bigint <> 50 or (res->>'snapshot_revision')::bigint <> 100 then
    raise exception 'activation failed: %', res;
  end if;

  -- Idempotent re-activation returns duplicate; aborting active migration MUST fail
  res := public.nohut_agent_activate_initial_sync(agent_token, mig1, 2, manifest);
  if res->>'status' <> 'duplicate' then raise exception 'expected duplicate activate: %', res; end if;
  begin
    perform public.nohut_agent_abort_initial_sync(agent_token, mig1, 'cannot abort active');
    raise exception 'aborted active migration';
  exception when insufficient_privilege then null;
  end;

  -- 8. Checkpoint is now live at (50, 100) and QR menu view is fresh (stale=false)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_phone, 'role', 'authenticated')::text, true);
  res := public.nohut_qr_menu_view(d_phone, 'yonetici', 1);
  if (res->>'available')::boolean <> true or (res#>>'{syncMeta,stale}')::boolean <> false then
    raise exception 'qr menu not live/fresh after initial sync activation: %', res;
  end if;

  -- 9. Strict P0 check: qr_menu_publish WITHOUT draftSha256 MUST be rejected (22023)
  begin
    perform public.nohut_enqueue_command(d_phone, 'yonetici', 1, req1, 'qr_menu_publish',
      jsonb_build_object('expectedStamp', '0123456789abcdef', 'confirmed', true));
    raise exception 'qr_menu_publish without draftSha256 was accepted';
  exception when invalid_parameter_value then null;
  end;

  -- 10. Revoking Windows agent token immediately blocks further agent RPCs
  update nohut_private.windows_agents set revoked_at = clock_timestamp()
   where restaurant_id = r1 and windows_device_id = d_win;
  begin
    perform public.nohut_agent_migration_status(agent_token, mig1);
    raise exception 'revoked windows agent still accessed migration_status';
  exception when insufficient_privilege then null;
  end;
end $$;

rollback;
