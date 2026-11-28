-- Synthetic tests for Increment B: QR Menu Management Cloud Integration
-- Verifies:
--   1. menu.* role parity for Personel & Yönetici (including menu.qr.publish), Muhasebe read-only
--   2. Zero permission broadening outside menu.* (Personel still blocked from payroll.view / sync.view)
--   3. Defense-in-depth rejection of any secret/token keys in projection & commands
--   4. public.nohut_qr_menu_view exact shape, dynamic `can` map, syncMeta freshness & staleness
--   5. Remote commands (qr_menu_write, qr_menu_publish, qr_menu_reconcile, qr_menu_image, qr_menu_sync)
--   6. expectedStamp, confirmed:true, MIME/path validation, requestId idempotency & conflict detection
--   7. Cross-tenant isolation and FORCE RLS direct-table access denial
begin;

do $$
declare
  r1 uuid := '31111111-1111-4111-8111-111111111111';
  r2 uuid := '32222222-2222-4222-8222-222222222222';
  ep1 uuid := '3e111111-1111-4111-8111-111111111111';
  ep2 uuid := '3e222222-2222-4222-8222-222222222222';
  u_owner uuid := '3a111111-1111-4111-8111-111111111111';
  u_staff uuid := '3a222222-2222-4222-8222-222222222222';
  u_acct  uuid := '3a333333-3333-4333-8333-333333333333';
  u_other uuid := '3a444444-4444-4444-8444-444444444444';
  d_owner uuid := '3d111111-1111-4111-8111-111111111111';
  d_staff uuid := '3d222222-2222-4222-8222-222222222222';
  d_acct  uuid := '3d333333-3333-4333-8333-333333333333';
  d_other uuid := '3d444444-4444-4444-8444-444444444444';
  s_owner uuid := '3b111111-1111-4111-8111-111111111111';
  s_staff uuid := '3b222222-2222-4222-8222-222222222222';
  s_acct  uuid := '3b333333-3333-4333-8333-333333333333';
  s_other uuid := '3b444444-4444-4444-8444-444444444444';
  pv_staff bigint;
  pv_acct bigint;
  res jsonb;
  req1 uuid := '3c111111-1111-4111-8111-111111111111';
  req2 uuid := '3c222222-2222-4222-8222-222222222222';
  req3 uuid := '3c333333-3333-4333-8333-333333333333';
  req4 uuid := '3c444444-4444-4444-8444-444444444444';
  req5 uuid := '3c555555-5555-4555-8555-555555555555';
  req6 uuid := '3c666666-6666-4666-8666-666666666666';
  stamp1 text := '0123456789abcdef';
begin
  insert into nohut_private.restaurants(restaurant_id) values (r1), (r2);
  insert into nohut_private.authority_epochs(restaurant_id, authority_epoch) values
    (r1, ep1),
    (r2, ep2);
  insert into nohut_private.sync_migrations(
    restaurant_id, migration_id, authority_epoch, snapshot_revision, snapshot_seq,
    schema_version, manifest_sha256, status
  ) values
    (r1, gen_random_uuid(), ep1, 0, 0, 1, repeat('a', 64), 'active'),
    (r2, gen_random_uuid(), ep2, 0, 0, 1, repeat('b', 64), 'active');
  insert into nohut_private.sync_checkpoints(restaurant_id, authority_epoch, last_acked_seq, last_acked_revision, updated_at) values
    (r1, ep1, 10, 10, clock_timestamp()),
    (r2, ep2, 1, 1, clock_timestamp());

  -- Create Owner, Personel (uses updated default_roles -> full menu.* parity), Muhasebe, and Tenant 2 Owner
  insert into nohut_private.app_users(user_id, restaurant_id, username, pos_employee_id, role_template, is_owner, active, permission_version) values
    (u_owner, r1, 'qr_owner', 1, 'Yönetici', true, true, 1),
    (u_staff, r1, 'qr_staff', 2, 'Personel', false, true, 1),
    (u_acct,  r1, 'qr_acct',  3, 'Muhasebe', false, true, 1),
    (u_other, r2, 'qr_other', 1, 'Yönetici', true, true, 1);

  -- Populate default grants from operation_catalogue (simulating user provisioning)
  insert into nohut_private.user_grants(user_id, operation_id, granted_by)
  select u.user_id, c.operation_id, u_owner
    from nohut_private.app_users u
    join nohut_private.operation_catalogue c on u.role_template = any(c.default_roles)
   where u.user_id in (u_staff, u_acct) and c.sensitivity <> 'ownerOnly';

  select permission_version into pv_staff from nohut_private.app_users where user_id = u_staff;
  select permission_version into pv_acct  from nohut_private.app_users where user_id = u_acct;

  perform nohut_private.enroll_device(u_owner, d_owner, s_owner, 'yonetici', 'Owner Phone');
  perform nohut_private.enroll_device(u_staff, d_staff, s_staff, 'personel', 'Staff Phone');
  perform nohut_private.enroll_device(u_acct,  d_acct,  s_acct,  'yonetici', 'Acct Tablet');
  perform nohut_private.enroll_device(u_other, d_other, s_other, 'yonetici', 'Other Phone');

  -- 1. Secret-key defense-in-depth: projection MUST reject any credential field
  begin
    perform nohut_private.apply_qr_menu_projection(r1, 11, jsonb_build_object(
      'available', true, 'stamp', stamp1, 'githubToken', 'ghp_FAKE_TEST_ONLY',
      'catalog', '{"categories":[],"products":[],"campaigns":[]}'::jsonb
    ));
    raise exception 'qr menu projection accepted forbidden secret key';
  exception when insufficient_privilege then null;
  end;

  -- Nested secret key inside catalog must ALSO be rejected
  begin
    perform nohut_private.apply_qr_menu_projection(r1, 11, jsonb_build_object(
      'available', true, 'stamp', stamp1,
      'catalog', jsonb_build_object('categories', '[]'::jsonb, 'products', jsonb_build_array(jsonb_build_object('id', 'p1', 'publisherKey', 'leak')), 'campaigns', '[]'::jsonb)
    ));
    raise exception 'qr menu projection accepted nested secret key';
  exception when insufficient_privilege then null;
  end;

  -- 2. Apply valid synthetic QR menu projection (checkpoint already at 11)
  update nohut_private.sync_checkpoints set last_acked_revision = 11 where restaurant_id = r1 and authority_epoch = ep1;
  perform nohut_private.apply_qr_menu_projection(r1, 11, jsonb_build_object(
    'available', true,
    'stamp', stamp1,
    'revision', 'rev-synthetic-001',
    'revisionLabel', 'rev-synt',
    'offline', false,
    'pendingPublish', false,
    'link', 'ready',
    'calculated_at', '2026-11-27T21:00:00Z',
    'changes', jsonb_build_array(jsonb_build_object('list', 'products', 'id', 'falafel-wrap', 'label', 'Falafel Dürüm', 'detail', 'Fiyat 150 -> 160 TL')),
    'catalog', jsonb_build_object(
      'categories', jsonb_build_array(jsonb_build_object('id', 'wraps', 'name', jsonb_build_object('tr','Dürümler','en','Wraps','ar','لفائف'), 'active', true, 'order', 1)),
      'products', jsonb_build_array(jsonb_build_object('id', 'falafel-wrap', 'category', 'wraps', 'name', jsonb_build_object('tr','Falafel Dürüm','en','Falafel Wrap','ar','لفافة فلافل'), 'price', 160, 'available', true, 'active', true, 'image', 'assets/falafel_wrap.webp', 'order', 1)),
      'campaigns', '[]'::jsonb
    ),
    'recentAudit', jsonb_build_array(jsonb_build_object('at', '2026-11-27T20:59:00Z', 'actor', 'Synthetic Staff', 'action', 'set_price', 'id', 'falafel-wrap'))
  ));

  -- 3. Personel reads QR menu view: sees full catalog + ALL 6 menu.* edit/publish grants = true
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_staff, 'session_id', s_staff, 'role', 'authenticated')::text, true);
  res := public.nohut_qr_menu_view(d_staff, 'personel', pv_staff);
  if (res->>'available')::boolean <> true
     or res->>'stamp' <> stamp1
     or res->>'publish' <> 'here'
     or res->>'link' <> 'ready'
     or (res#>>'{can,menu.product.edit}')::boolean <> true
     or (res#>>'{can,menu.price.edit}')::boolean <> true
     or (res#>>'{can,menu.category.edit}')::boolean <> true
     or (res#>>'{can,menu.campaign.edit}')::boolean <> true
     or (res#>>'{can,menu.stock.toggle}')::boolean <> true
     or (res#>>'{can,menu.qr.publish}')::boolean <> true
     or (res#>>'{syncMeta,stale}')::boolean <> false then
    raise exception 'personel qr menu view mismatch: %', res;
  end if;

  -- Verify zero broadening outside menu.*: Personel still denied payroll.view and sync.view
  if nohut_private.authorize(u_staff, s_staff, d_staff, 'personel', 'payroll.view', pv_staff) = 'ok'
     or nohut_private.authorize(u_staff, s_staff, d_staff, 'personel', 'sync.view', pv_staff) = 'ok' then
    raise exception 'personel permissions broadened outside menu.*';
  end if;

  -- 4. Personel enqueues qr_menu_write (set_price) + idempotent replay + conflict check
  res := public.nohut_enqueue_command(d_staff, 'personel', pv_staff, req1, 'qr_menu_write',
    jsonb_build_object('expectedStamp', stamp1, 'action', 'set_price', 'id', 'falafel-wrap', 'priceCents', 16500));
  if res->>'status' <> 'accepted' then raise exception 'expected accepted qr_menu_write: %', res; end if;

  res := public.nohut_enqueue_command(d_staff, 'personel', pv_staff, req1, 'qr_menu_write',
    jsonb_build_object('expectedStamp', stamp1, 'action', 'set_price', 'id', 'falafel-wrap', 'priceCents', 16500));
  if res->>'status' <> 'duplicate' then raise exception 'expected duplicate qr_menu_write: %', res; end if;

  res := public.nohut_enqueue_command(d_staff, 'personel', pv_staff, req1, 'qr_menu_write',
    jsonb_build_object('expectedStamp', stamp1, 'action', 'set_price', 'id', 'falafel-wrap', 'priceCents', 17000));
  if res->>'status' <> 'conflict' then raise exception 'expected conflict qr_menu_write: %', res; end if;

  -- 5. Personel enqueues qr_menu_publish (with matching draftSha256), qr_menu_reconcile (exact v2 payload), qr_menu_image, qr_menu_sync
  res := public.nohut_enqueue_command(d_staff, 'personel', pv_staff, req2, 'qr_menu_publish',
    jsonb_build_object('expectedStamp', stamp1, 'confirmed', true, 'draftSha256', stamp1 || repeat('0', 48)));
  if res->>'status' <> 'accepted' then raise exception 'personel publish failed: %', res; end if;

  res := public.nohut_enqueue_command(d_staff, 'personel', pv_staff, req3, 'qr_menu_reconcile',
    jsonb_build_object('targetRequestId', req2::text, 'mode', 'reconcile'));
  if res->>'status' <> 'accepted' then raise exception 'personel reconcile failed: %', res; end if;

  -- Legacy {} qr_menu_reconcile and mismatched draftSha256 MUST be rejected (#7230501923)
  begin
    perform public.nohut_enqueue_command(d_staff, 'personel', pv_staff, req6, 'qr_menu_reconcile', '{}'::jsonb);
    raise exception 'legacy empty qr_menu_reconcile accepted';
  exception when invalid_parameter_value then null;
  end;

  begin
    perform public.nohut_enqueue_command(d_staff, 'personel', pv_staff, req6, 'qr_menu_reconcile',
      jsonb_build_object('targetRequestId', req2::text, 'mode', 'invalid_mode'));
    raise exception 'invalid reconcile mode accepted';
  exception when invalid_parameter_value then null;
  end;

  begin
    perform public.nohut_enqueue_command(d_staff, 'personel', pv_staff, req6, 'qr_menu_publish',
      jsonb_build_object('expectedStamp', stamp1, 'confirmed', true, 'draftSha256', repeat('f', 64)));
    raise exception 'mismatched draftSha256 accepted';
  exception when invalid_parameter_value then null;
  end;

  res := public.nohut_enqueue_command(d_staff, 'personel', pv_staff, req4, 'qr_menu_image',
    jsonb_build_object('expectedStamp', stamp1, 'id', 'falafel-wrap', 'mime', 'image/webp', 'storagePath', 'qr-uploads/synthetic_img_1.webp', 'sizeBytes', 240000));
  if res->>'status' <> 'accepted' then raise exception 'personel image failed: %', res; end if;

  res := public.nohut_enqueue_command(d_staff, 'personel', pv_staff, req5, 'qr_menu_sync', '{}'::jsonb);
  if res->>'status' <> 'accepted' then raise exception 'personel sync failed: %', res; end if;

  -- Invalid publish (confirmed: false) and invalid image path (..) MUST fail
  begin
    perform public.nohut_enqueue_command(d_staff, 'personel', pv_staff, req6, 'qr_menu_publish',
      jsonb_build_object('expectedStamp', stamp1, 'draftSha256', stamp1 || repeat('0', 48), 'confirmed', false));
    raise exception 'unconfirmed publish accepted';
  exception when invalid_parameter_value then null;
  end;

  begin
    perform public.nohut_enqueue_command(d_staff, 'personel', pv_staff, req6, 'qr_menu_image',
      jsonb_build_object('expectedStamp', stamp1, 'id', 'falafel-wrap', 'mime', 'image/webp', 'storagePath', 'qr-uploads/../secret.webp'));
    raise exception 'path traversal accepted';
  exception when invalid_parameter_value then null;
  end;

  -- 6. Muhasebe can view QR menu (can.* all false) but CANNOT write or publish
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_acct, 'session_id', s_acct, 'role', 'authenticated')::text, true);
  res := public.nohut_qr_menu_view(d_acct, 'yonetici', pv_acct);
  if (res#>>'{can,menu.qr.publish}')::boolean <> false or (res#>>'{can,menu.price.edit}')::boolean <> false then
    raise exception 'muhasebe unexpectedly granted menu edit/publish: %', res;
  end if;
  begin
    perform public.nohut_enqueue_command(d_acct, 'yonetici', pv_acct, req6, 'qr_menu_publish',
      jsonb_build_object('expectedStamp', stamp1, 'draftSha256', stamp1 || repeat('0', 48), 'confirmed', true));
    raise exception 'muhasebe allowed to publish qr menu';
  exception when insufficient_privilege then null;
  end;

  -- 7. Cross-tenant isolation: Tenant 2 sees available: false (never Tenant 1's catalog)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_other, 'session_id', s_other, 'role', 'authenticated')::text, true);
  res := public.nohut_qr_menu_view(d_other, 'yonetici', 1);
  if (res->>'available')::boolean <> false then
    raise exception 'cross-tenant qr menu leak: %', res;
  end if;

  -- 8. Aged checkpoint surfaces stale: true
  update nohut_private.sync_checkpoints set updated_at = clock_timestamp() - interval '25 minutes'
    where restaurant_id = r1 and authority_epoch = ep1;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner, 'session_id', s_owner, 'role', 'authenticated')::text, true);
  res := public.nohut_qr_menu_view(d_owner, 'yonetici', 1);
  if (res#>>'{syncMeta,stale}')::boolean <> true or res#>>'{syncMeta,staleReason}' <> 'sync_aged' then
    raise exception 'stale qr menu syncMeta not reported: %', res;
  end if;
end $$;

-- 9. Direct table access from authenticated role is blocked
set local role authenticated;
do $$
begin
  begin
    perform 1 from nohut_private.qr_menu_state;
    raise exception 'authenticated role read nohut_private.qr_menu_state directly';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

rollback;
