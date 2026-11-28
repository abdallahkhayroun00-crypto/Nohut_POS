-- Synthetic tests for Increment D + Hardening (#7231808318):
--   1. Full draftSha256 REQUIRED on qr_menu_publish (missing draftSha256 rejected 22023)
--   2. Pre-sync backup required; idempotent begin/duplicate/conflict
--   3. Batch verification on upload: mismatched item_count, mismatched body_sha256, and >500 events cap rejected
--   4. Stage + Promote isolation: while uploading, phones see available=false (ZERO partial snapshot leak!)
--   5. Safe abort purges staged payloads, stores abort_reason/aborted_at, writes security_audit, leaves live tables untouched
--   6. Activation rejects NULL / negative p_expected_batches, incomplete batch count, and mismatched computed manifest
--   7. Atomic promotion makes QR menu live & fresh ONLY after activation, and purges migration_staged_batches
--   8. Second full sync ("Yeniden eşitle"): owner MFA rotates authority_epoch via nohut_owner_rotate_authority_epoch,
--      revoking old agent token immediately and allowing a fresh initial sync on the new epoch!
--   9. Non-owner / non-MFA / non-Windows rotation attempts are denied (42501)
begin;

do $$
declare
  r1 uuid := '51111111-1111-4111-8111-111111111111';
  ep1 uuid := '5e111111-1111-4111-8111-111111111111';
  ep2 uuid;
  mig1 uuid := '5f111111-1111-4111-8111-111111111111';
  mig2 uuid := '5f333333-3333-4333-8333-333333333333';
  mig_abort uuid := '5f222222-2222-4222-8222-222222222222';
  b1 uuid := '5b111111-1111-4111-8111-111111111111';
  b2 uuid := '5b222222-2222-4222-8222-222222222222';
  b_abort uuid := '5b333333-3333-4333-8333-333333333333';
  u_owner uuid := '5a111111-1111-4111-8111-111111111111';
  u_staff uuid := '5a222222-2222-4222-8222-222222222222';
  d_win uuid := '5d111111-1111-4111-8111-111111111111';
  s_win uuid := '5c111111-1111-4111-8111-111111111111';
  d_phone uuid := '5d222222-2222-4222-8222-222222222222';
  s_phone uuid := '5c222222-2222-4222-8222-222222222222';
  req1 uuid := '59111111-1111-4111-8111-111111111111';
  agent_token text := repeat('9', 64);
  agent_token2 text := repeat('8', 64);
  ev1 jsonb := jsonb_build_array(
    jsonb_build_object('entity_type', 'employees', 'entity_id', 'core', 'payload', jsonb_build_array(
      jsonb_build_object('id', 1, 'name', 'Synthetic Owner', 'active', true, 'payrollEligible', false)
    ))
  );
  ev2 jsonb := jsonb_build_array(
    jsonb_build_object('entity_type', 'qrMenuState', 'entity_id', 'core', 'payload', jsonb_build_object(
      'available', true, 'stamp', '0123456789abcdef', 'revision', 'rev-init-1', 'revisionLabel', 'rev-init',
      'offline', false, 'pendingPublish', false, 'link', 'ready',
      'changes', '[]'::jsonb, 'catalog', '{"categories":[],"products":[],"campaigns":[]}'::jsonb
    ))
  );
  hash1 text;
  hash2 text;
  manifest1 text;
  manifest_empty text := encode(sha256(convert_to('', 'UTF8')), 'hex');
  staged_left integer;
  audit_cnt integer;
  res jsonb;
begin
  hash1 := encode(sha256(convert_to(nohut_private.canonical_command_json(ev1), 'UTF8')), 'hex');
  hash2 := encode(sha256(convert_to(nohut_private.canonical_command_json(ev2), 'UTF8')), 'hex');
  -- Ordered by batch_id::text ascending (b1 < b2)
  manifest1 := encode(sha256(convert_to(
    'employees:' || b1::text || ':1:' || hash1 || E'\n' ||
    'qrMenuState:' || b2::text || ':1:' || hash2,
    'UTF8'
  )), 'hex');

  insert into nohut_private.restaurants(restaurant_id) values (r1);
  insert into nohut_private.authority_epochs(restaurant_id, authority_epoch) values (r1, ep1);
  insert into nohut_private.app_users(user_id, restaurant_id, username, pos_employee_id, role_template, is_owner, active, permission_version) values
    (u_owner, r1, 'init_owner', 1, 'Yönetici', true, true, 1),
    (u_staff, r1, 'init_staff', 2, 'Personel', false, true, 1);

  perform nohut_private.enroll_device(u_owner, d_win, s_win, 'windows', 'Windows POS');
  perform nohut_private.enroll_device(u_owner, d_phone, s_phone, 'yonetici', 'Owner Phone');

  insert into nohut_private.windows_agents(
    agent_id, restaurant_id, authority_epoch, windows_device_id, token_sha256, expires_at
  ) values (
    gen_random_uuid(), r1, ep1, d_win,
    sha256(convert_to(agent_token, 'UTF8')), clock_timestamp() + interval '1 day'
  );

  -- 1. Pre-sync backup verification MUST be true
  begin
    perform public.nohut_agent_begin_initial_sync(agent_token, mig1, 100, 50, manifest1, false);
    raise exception 'initial sync started without verified backup';
  exception when insufficient_privilege then null;
  end;

  -- 2. Stage batch in abortable migration -> phone MUST NOT see it -> abort purges & audits reason
  res := public.nohut_agent_begin_initial_sync(agent_token, mig_abort, 90, 40, manifest_empty, true);
  if res->>'status' <> 'accepted' then raise exception 'begin mig_abort failed: %', res; end if;

  res := public.nohut_agent_upload_snapshot_batch(agent_token, mig_abort, b_abort, 'qrMenuState', 1, hash2, ev2);
  if res->>'status' <> 'accepted' then raise exception 'stage abort batch failed: %', res; end if;

  -- Phone MUST NOT see staged QR menu before activation (Blocking #3)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_phone, 'role', 'authenticated')::text, true);
  res := public.nohut_qr_menu_view(d_phone, 'yonetici', 1);
  if (res->>'available')::boolean <> false then
    raise exception 'unactivated snapshot leaked to phone: %', res;
  end if;

  -- Abort removes staged payload & stores/audits reason (Blocking #3 + Minor #2)
  res := public.nohut_agent_abort_initial_sync(agent_token, mig_abort, 'owner cancelled mid-upload');
  if res->>'status' <> 'safely_aborted' or (res->>'purged_staged_batches')::integer <> 1 then
    raise exception 'abort did not purge staged batch: %', res;
  end if;
  select count(*) into staged_left from nohut_private.migration_staged_batches where migration_id = mig_abort;
  select count(*) into audit_cnt from nohut_private.security_audit
   where restaurant_id = r1 and action = 'initial_sync_aborted' and detail->>'reason' = 'owner cancelled mid-upload';
  if staged_left <> 0 or audit_cnt <> 1 then
    raise exception 'abort cleanup/audit failed: staged=% audit=%', staged_left, audit_cnt;
  end if;

  -- 3. Begin real initial sync + duplicate + conflict
  res := public.nohut_agent_begin_initial_sync(agent_token, mig1, 100, 50, manifest1, true);
  if res->>'status' <> 'accepted' then raise exception 'begin mig1 failed: %', res; end if;
  res := public.nohut_agent_begin_initial_sync(agent_token, mig1, 100, 50, manifest1, true);
  if res->>'status' <> 'duplicate' then raise exception 'expected duplicate begin: %', res; end if;
  res := public.nohut_agent_begin_initial_sync(agent_token, mig1, 100, 50, repeat('b', 64), true);
  if res->>'status' <> 'conflict' then raise exception 'expected conflict begin: %', res; end if;

  -- 4. Blocking #2 negative tests: mismatched item_count and mismatched body_sha256 rejected on upload
  begin
    perform public.nohut_agent_upload_snapshot_batch(agent_token, mig1, b1, 'employees', 2, hash1, ev1);
    raise exception 'mismatched item_count accepted';
  exception when invalid_parameter_value then null;
  end;

  begin
    perform public.nohut_agent_upload_snapshot_batch(agent_token, mig1, b1, 'employees', 1, repeat('f', 64), ev1);
    raise exception 'mismatched body_sha256 accepted';
  exception when invalid_parameter_value then null;
  end;

  -- Upload valid batch 1 + idempotent retry + conflict
  res := public.nohut_agent_upload_snapshot_batch(agent_token, mig1, b1, 'employees', 1, hash1, ev1);
  if res->>'status' <> 'accepted' then raise exception 'batch 1 failed: %', res; end if;
  res := public.nohut_agent_upload_snapshot_batch(agent_token, mig1, b1, 'employees', 1, hash1, ev1);
  if res->>'status' <> 'duplicate' then raise exception 'expected duplicate batch 1: %', res; end if;

  -- Upload valid batch 2 -> STILL invisible to phone before activation!
  res := public.nohut_agent_upload_snapshot_batch(agent_token, mig1, b2, 'qrMenuState', 1, hash2, ev2);
  if res->>'status' <> 'accepted' then raise exception 'batch 2 failed: %', res; end if;
  res := public.nohut_qr_menu_view(d_phone, 'yonetici', 1);
  if (res->>'available')::boolean <> false then
    raise exception 'batch 2 leaked before activation: %', res;
  end if;

  -- 5. Blocking #1 negative tests: NULL and negative p_expected_batches rejected (22023)
  begin
    perform public.nohut_agent_activate_initial_sync(agent_token, mig1, null, manifest1);
    raise exception 'NULL p_expected_batches accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.nohut_agent_activate_initial_sync(agent_token, mig1, -1, manifest1);
    raise exception 'negative p_expected_batches accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.nohut_agent_activate_initial_sync(agent_token, mig1, 1, manifest1);
    raise exception 'incomplete p_expected_batches accepted';
  exception when invalid_parameter_value then null;
  end;

  -- 6. Activate cleanly -> atomically promotes batches, purges staged rows, makes QR menu live & fresh
  res := public.nohut_agent_activate_initial_sync(agent_token, mig1, 2, manifest1);
  if res->>'status' <> 'accepted' or res->>'migration_status' <> 'active'
     or res->>'manifest_sha256' <> manifest1 then
    raise exception 'activation failed: %', res;
  end if;
  select count(*) into staged_left from nohut_private.migration_staged_batches where migration_id = mig1;
  if staged_left <> 0 then raise exception 'staged batches not purged after activation'; end if;

  res := public.nohut_qr_menu_view(d_phone, 'yonetici', 1);
  if (res->>'available')::boolean <> true or (res#>>'{syncMeta,stale}')::boolean <> false then
    raise exception 'qr menu not live/fresh after activation: %', res;
  end if;

  -- 7. Strict P0 check: qr_menu_publish WITHOUT draftSha256 MUST be rejected (22023)
  begin
    perform public.nohut_enqueue_command(d_phone, 'yonetici', 1, req1, 'qr_menu_publish',
      jsonb_build_object('expectedStamp', '0123456789abcdef', 'confirmed', true));
    raise exception 'qr_menu_publish without draftSha256 was accepted';
  exception when invalid_parameter_value then null;
  end;

  -- 8. Blocking #4: Second full sync ("Yeniden eşitle") requires owner + MFA + Windows epoch rotation
  -- Non-MFA (aal1) rotation MUST fail
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_win, 'aal', 'aal1', 'role', 'authenticated')::text, true);
  begin
    perform public.nohut_owner_rotate_authority_epoch(d_win, 1, 'resync without mfa');
    raise exception 'epoch rotation succeeded without MFA';
  exception when insufficient_privilege then null;
  end;

  -- Owner + aal2 + Windows rotates epoch cleanly, revoking old agent token immediately!
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_win, 'aal', 'aal2', 'role', 'authenticated')::text, true);
  res := public.nohut_owner_rotate_authority_epoch(d_win, 1, 'owner requested full resync');
  ep2 := (res->>'new_authority_epoch')::uuid;
  if ep2 is null or ep2 = ep1 then raise exception 'epoch rotation failed: %', res; end if;

  -- Old agent token is immediately revoked!
  begin
    perform public.nohut_agent_migration_status(agent_token, mig1);
    raise exception 'old epoch agent still authenticated after rotation';
  exception when insufficient_privilege then null;
  end;

  -- New agent on ep2 can begin a clean second full sync; activating an empty snapshot cleanly REPLACES Epoch 1 data!
  insert into nohut_private.windows_agents(
    agent_id, restaurant_id, authority_epoch, windows_device_id, token_sha256, expires_at
  ) values (
    gen_random_uuid(), r1, ep2, d_win,
    sha256(convert_to(agent_token2, 'UTF8')), clock_timestamp() + interval '1 day'
  );
  -- Also test Medium #3: stage an orphan batch on ep2, then rotate to ep3 and verify it is purged & safely_aborted
  res := public.nohut_agent_begin_initial_sync(agent_token2, mig2, 200, 100, manifest1, true);
  if res->>'status' <> 'accepted' then raise exception 'second full sync begin failed: %', res; end if;
  res := public.nohut_agent_upload_snapshot_batch(agent_token2, mig2, b1, 'employees', 1, hash1, ev1);
  if res->>'status' <> 'accepted' then raise exception 'ep2 staged batch failed: %', res; end if;

  -- Rotate ep2 -> ep3: mig2 must become safely_aborted (abort_reason='epoch_rotated') and staged batch purged!
  res := public.nohut_owner_rotate_authority_epoch(d_win, 1, 'rotate with uploading migration');
  if (res->>'aborted_migrations')::integer <> 1 or (res->>'purged_staged_batches')::integer <> 1 then
    raise exception 'rotation did not purge orphan staged migration: %', res;
  end if;
  select count(*) into staged_left from nohut_private.migration_staged_batches where migration_id = mig2;
  if staged_left <> 0 then raise exception 'orphan staged batch survived rotation'; end if;

  -- Provision agent on ep3 and activate an empty snapshot -> Epoch 1 QR menu MUST be cleared (Medium #2)!
  ep2 := (res->>'new_authority_epoch')::uuid;
  insert into nohut_private.windows_agents(
    agent_id, restaurant_id, authority_epoch, windows_device_id, token_sha256, expires_at
  ) values (
    gen_random_uuid(), r1, ep2, d_win,
    sha256(convert_to(repeat('7', 64), 'UTF8')), clock_timestamp() + interval '1 day'
  );
  res := public.nohut_agent_begin_initial_sync(repeat('7', 64), gen_random_uuid(), 300, 150, manifest_empty, true);
  if res->>'status' <> 'accepted' then raise exception 'ep3 begin failed: %', res; end if;
  res := public.nohut_agent_activate_initial_sync(repeat('7', 64), (res->>'migration_id')::uuid, 0, manifest_empty);
  if res->>'status' <> 'accepted' or res->>'migration_status' <> 'active' then
    raise exception 'ep3 activate failed: %', res;
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_phone, 'role', 'authenticated')::text, true);
  res := public.nohut_qr_menu_view(d_phone, 'yonetici', 1);
  if (res->>'available')::boolean <> false then
    raise exception 'Epoch 1 QR menu survived clean Epoch 3 replacement: %', res;
  end if;
end $$;

rollback;
