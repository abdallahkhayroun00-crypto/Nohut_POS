-- Increment D (P0 Backend & Security on PR #46):
-- 1. Require full 64-hex draftSha256 (prefix matching 16-hex expectedStamp) on qr_menu_publish.
-- 2. Complete First Database Synchronization, Resumable Snapshot Batches, Verification,
--    Activation, Safe Abort & Recovery Status RPCs (Windows-agent authenticated only).
begin;

-- 1. Require full draftSha256 on qr_menu_publish (no longer optional)
create or replace function nohut_private.validate_command_payload(p_action text, p jsonb)
returns void language plpgsql immutable set search_path = '' as $$
declare
  line jsonb;
  action text := p->>'action';
  required_fields jsonb;
  optional_fields jsonb := '{}';
  k text;
  v jsonb;
  stamp text;
  sha text;
  img_path text;
begin
  if p is null or octet_length(p::text) > 65536 then
    raise exception 'invalid command size' using errcode = '22023';
  end if;
  if nohut_private.contains_forbidden_secret_key(p) then
    raise exception 'credentials forbidden in command' using errcode = '42501';
  end if;
  if p_action ~ '^(sync_|backup_|restore_)' or p_action in ('first_sync', 'full_resync') then
    raise exception 'windows_only' using errcode = '42501';
  end if;

  if p_action in ('create_order', 'add_order_items') then
    required_fields := '{"expectedRevision":"integer","source":"string","lines":"array"}';
    if p_action = 'add_order_items' then required_fields := required_fields || '{"orderId":"integer"}'; end if;
    optional_fields := '{"table":"nullable_integer","pickupChannel":"string","customer":"object","expectedTableOrderId":"nullable_integer"}';
  elsif p_action in ('record_payment','split_bill','move_order','close_order','mark_delivered','edit_order_line','delete_order','print_payment_receipt') then
    required_fields := '{"expectedRevision":"integer","orderId":"integer","action":"string"}';
    case p_action
      when 'record_payment' then
        if action not in ('pay','payMixed','payProducts') or action is null then raise exception 'action mismatch' using errcode = '22023'; end if;
        required_fields := required_fields || '{"amountCents":"integer","confirmed":"boolean"}';
        optional_fields := '{"guestId":"nullable_integer","receivedCents":"nullable_integer"}';
        if action = 'payMixed' then required_fields := required_fields || '{"cashCents":"integer","printReceipt":"boolean"}';
        else required_fields := required_fields || '{"method":"string"}'; end if;
        if action = 'pay' then required_fields := required_fields || '{"printReceipt":"boolean"}'; end if;
        if action = 'payProducts' then required_fields := required_fields || '{"shares":"object"}'; optional_fields := optional_fields || '{"cashCents":"nullable_integer"}'; end if;
      when 'split_bill' then
        case action
          when 'splitEqual' then required_fields := required_fields || '{"count":"integer"}';
          when 'addGuest' then required_fields := required_fields || '{"name":"string"}';
          when 'allocate' then required_fields := required_fields || '{"guestId":"integer","key":"string","cents":"integer"}';
          when 'resetGuests' then null;
          else raise exception 'action mismatch' using errcode = '22023';
        end case;
      when 'move_order' then
        if action is distinct from 'move' then raise exception 'action mismatch' using errcode = '22023'; end if;
        required_fields := required_fields || '{"table":"integer"}';
      when 'close_order' then if action is distinct from 'close' then raise exception 'action mismatch' using errcode = '22023'; end if;
      when 'mark_delivered' then if action is distinct from 'status' then raise exception 'action mismatch' using errcode = '22023'; end if;
      when 'edit_order_line' then
        if action is distinct from 'editLine' then raise exception 'action mismatch' using errcode = '22023'; end if;
        required_fields := required_fields || '{"key":"string","qty":"integer","note":"string","removed":"array"}';
        optional_fields := '{"adjustmentCents":"integer","components":"array"}';
      when 'delete_order' then
        if action is distinct from 'delete' then raise exception 'action mismatch' using errcode = '22023'; end if;
        required_fields := required_fields || '{"confirmed":"boolean","reason":"string"}';
      when 'print_payment_receipt' then
        if action is distinct from 'printProductPayment' then raise exception 'action mismatch' using errcode = '22023'; end if;
        required_fields := required_fields || '{"paymentId":"string"}';
    end case;
  elsif p_action = 'clock_in_out' then
    required_fields := '{"action":"string"}';
    if action is null or action not in ('clockIn','clockOut') then raise exception 'action mismatch' using errcode = '22023'; end if;
  elsif p_action = 'correct_shift' then
    required_fields := '{"shiftId":"string","reason":"string"}';
    optional_fields := '{"start":"string","end":"nullable_string"}';
  elsif p_action = 'retry_print' then
    required_fields := '{"target":"string","checked":"boolean"}';
    case p->>'target'
      when 'kitchen' then required_fields := required_fields || '{"orderId":"integer","batchId":"integer"}';
      when 'payment' then required_fields := required_fields || '{"receiptRequestId":"string"}';
      when 'platform' then required_fields := required_fields || '{"orderKey":"string"}';
      else raise exception 'invalid print target' using errcode = '22023';
    end case;
  elsif p_action = 'set_product_sale' then
    required_fields := '{"productId":"integer","active":"boolean"}';
  elsif p_action = 'platform_action' then
    required_fields := '{"action":"string","packageId":"string"}';
    optional_fields := '{"preparationMinutes":"integer"}';
    if action is null or action not in ('accept','ready') then raise exception 'action mismatch' using errcode = '22023'; end if;
  elsif p_action = 'qr_menu_write' then
    required_fields := '{"expectedStamp":"string","action":"string"}';
    case action
      when 'set_price' then
        required_fields := required_fields || '{"id":"string","priceCents":"integer"}';
      when 'set_stock' then
        required_fields := required_fields || '{"id":"string","available":"boolean"}';
      when 'set_visible' then
        required_fields := required_fields || '{"id":"string","active":"boolean"}';
      when 'set_image' then
        required_fields := required_fields || '{"id":"string","image":"string"}';
        optional_fields := '{"target":"string"}';
      when 'save_product' then
        required_fields := required_fields || '{"category":"string","name":"object","priceCents":"integer","available":"boolean","active":"boolean"}';
        optional_fields := '{"id":"string","displayName":"object","description":"object","image":"nullable_string","order":"integer"}';
      when 'save_category' then
        required_fields := required_fields || '{"name":"object","active":"boolean"}';
        optional_fields := '{"id":"string","description":"object","order":"integer"}';
      when 'save_campaign' then
        required_fields := required_fields || '{"title":"object","priceCents":"integer","active":"boolean"}';
        optional_fields := '{"id":"string","description":"object","poster":"nullable_string","thumbnail":"nullable_string"}';
      else
        raise exception 'action mismatch' using errcode = '22023';
    end case;
  elsif p_action = 'qr_menu_publish' then
    -- P0 checklist: full 64-hex draftSha256 is REQUIRED (never optional).
    required_fields := '{"expectedStamp":"string","draftSha256":"string","confirmed":"boolean"}';
    optional_fields := '{"expectedRevision":"nullable_string"}';
  elsif p_action = 'qr_menu_reconcile' then
    required_fields := '{"targetRequestId":"string","mode":"string"}';
  elsif p_action = 'qr_menu_sync' then
    required_fields := '{}';
  elsif p_action = 'qr_menu_image' then
    required_fields := '{"expectedStamp":"string","id":"string","mime":"string"}';
    optional_fields := '{"storagePath":"string","base64":"string","sizeBytes":"integer","target":"string"}';
  else
    raise exception 'unsupported action' using errcode = '42501';
  end if;

  perform nohut_private.command_shape(p, required_fields, optional_fields);
  if p ? 'expectedRevision' and jsonb_typeof(p->'expectedRevision') = 'number' and (p->>'expectedRevision')::bigint < 0 then
    raise exception 'invalid revision' using errcode = '22023';
  end if;
  if p ? 'table' and p->'table' <> 'null'::jsonb and (p->>'table')::bigint not between 1 and 5 then raise exception 'invalid table' using errcode = '22023'; end if;
  if p ? 'orderId' and (p->>'orderId')::bigint < 1 then raise exception 'invalid order' using errcode = '22023'; end if;
  if p ? 'confirmed' and p->'confirmed' <> 'true'::jsonb then raise exception 'confirmation required' using errcode = '22023'; end if;

  if p_action in ('create_order', 'add_order_items') then
    if p->>'source' not in ('Masa','Gel-Al') or (p->>'source' = 'Masa' and (p->'table' is null or p->'table' = 'null'::jsonb))
      or (p->>'source' = 'Gel-Al' and p->'table' is not null and p->'table' <> 'null'::jsonb)
      or jsonb_array_length(p->'lines') not between 1 and 200 then raise exception 'invalid order' using errcode = '22023'; end if;
    if p ? 'pickupChannel' and p->>'pickupChannel' not in ('Tezgahtan','Telefon') then raise exception 'invalid pickup channel' using errcode = '22023'; end if;
    if p ? 'customer' then
      perform nohut_private.command_shape(p->'customer','{}','{"time":"string"}');
      if length(coalesce(p->'customer'->>'time','')) > 40 then raise exception 'invalid pickup time' using errcode = '22023'; end if;
    end if;
    for line in select * from jsonb_array_elements(p->'lines') loop perform nohut_private.command_line(line); end loop;
  elsif p_action = 'record_payment' then
    if (p->>'amountCents')::bigint not between 1 and 100000000000 or p->'confirmed' <> 'true'::jsonb then raise exception 'invalid payment' using errcode = '22023'; end if;
    if p ? 'method' and p->>'method' not in ('Nakit','Kart','Karışık') then raise exception 'invalid payment method' using errcode = '22023'; end if;
    if action = 'pay' and p->>'method' = 'Karışık' then raise exception 'mixed payment route required' using errcode = '22023'; end if;
    if action = 'payMixed' or p->>'method' = 'Karışık' then
      if p->>'cashCents' is null or (p->>'cashCents')::bigint <= 0 or (p->>'cashCents')::bigint >= (p->>'amountCents')::bigint then raise exception 'invalid mixed payment' using errcode = '22023'; end if;
    end if;
    if p ? 'receivedCents' and (p->>'receivedCents')::bigint < 0 then raise exception 'invalid received cash' using errcode = '22023'; end if;
    if action = 'payProducts' then
      if (select count(*) from jsonb_object_keys(p->'shares')) not between 1 and 200 then raise exception 'invalid shares' using errcode = '22023'; end if;
      for k, v in select * from jsonb_each(p->'shares') loop
        perform nohut_private.command_shape(jsonb_build_object('cents', v), '{"cents":"integer"}');
        if length(k) > 200 or (v::text)::bigint <= 0 then raise exception 'invalid product share' using errcode = '22023'; end if;
      end loop;
    end if;
  elsif p_action = 'split_bill' then
    if action = 'splitEqual' and (p->>'count')::bigint not between 2 and 100 then raise exception 'invalid split count' using errcode = '22023'; end if;
    if action = 'allocate' and (p->>'cents')::bigint < 0 then raise exception 'invalid allocation' using errcode = '22023'; end if;
    if action = 'addGuest' and length(p->>'name') > 100 then raise exception 'guest name too long' using errcode = '22023'; end if;
  elsif p_action = 'correct_shift' then
    if length(trim(p->>'reason')) not between 1 and 300 then raise exception 'correction reason required' using errcode = '22023'; end if;
    if p ? 'start' then perform nohut_private.shift_timestamp(p->'start'); end if;
    if p ? 'end' then perform nohut_private.shift_timestamp(p->'end'); end if;
  elsif p_action = 'retry_print' and p->'checked' <> 'true'::jsonb then
    raise exception 'printer check required' using errcode = '22023';
  elsif p_action = 'platform_action' then
    if length(trim(p->>'packageId')) not between 1 and 200 or
      (p ? 'preparationMinutes' and (p->>'preparationMinutes')::bigint not between 1 and 180) then raise exception 'invalid platform target' using errcode = '22023'; end if;
  elsif p_action = 'edit_order_line' then
    if (p->>'qty')::bigint not between 0 and 1000 or length(p->>'note') > 500 then raise exception 'invalid line edit' using errcode = '22023'; end if;
    perform nohut_private.command_removed(p->'removed');
    if p ? 'components' then
      perform nohut_private.command_line(jsonb_build_object('productId', 0, 'qty', 1, 'components', p->'components'));
    end if;
  elsif p_action = 'qr_menu_reconcile' then
    if (p->>'targetRequestId') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'invalid targetRequestId' using errcode = '22023';
    end if;
    if (p->>'mode') not in ('reconcile', 'cancel_before_attempt') then
      raise exception 'invalid reconcile mode' using errcode = '22023';
    end if;
  elsif p_action in ('qr_menu_write', 'qr_menu_publish', 'qr_menu_image') then
    stamp := p->>'expectedStamp';
    if stamp is null or stamp !~ '^[0-9a-f]{16}$' then
      raise exception 'invalid expectedStamp' using errcode = '22023';
    end if;
    if p_action = 'qr_menu_publish' then
      sha := p->>'draftSha256';
      if sha is null or sha !~ '^[0-9a-f]{64}$' or left(sha, 16) <> stamp then
        raise exception 'draftSha256 required and must match expectedStamp' using errcode = '22023';
      end if;
    elsif p_action = 'qr_menu_write' then
      if p ? 'priceCents' and (p->>'priceCents')::bigint not between 0 and 10000000 then
        raise exception 'invalid qr price' using errcode = '22023';
      end if;
      if p ? 'id' and length(trim(p->>'id')) not between 1 and 120 then
        raise exception 'invalid qr entity id' using errcode = '22023';
      end if;
      if action = 'set_image' then
        img_path := p->>'image';
        if img_path !~ '^assets/[A-Za-z0-9_./-]+\.(png|jpg|jpeg|webp)$' or position('..' in img_path) > 0 then
          raise exception 'invalid qr image path' using errcode = '22023';
        end if;
      end if;
    elsif p_action = 'qr_menu_image' then
      if p->>'mime' not in ('image/png', 'image/jpeg', 'image/webp') then
        raise exception 'unsupported image mime' using errcode = '22023';
      end if;
      if length(trim(p->>'id')) not between 1 and 120 then
        raise exception 'invalid qr entity id' using errcode = '22023';
      end if;
      if not (p ? 'storagePath' or p ? 'base64') then
        raise exception 'image payload required' using errcode = '22023';
      end if;
      if p ? 'storagePath' then
        img_path := p->>'storagePath';
        if img_path !~ '^qr-uploads/[A-Za-z0-9_-]+\.(png|jpg|jpeg|webp)$' or position('..' in img_path) > 0 then
          raise exception 'invalid image storagePath' using errcode = '22023';
        end if;
      end if;
      if p ? 'sizeBytes' and (p->>'sizeBytes')::bigint not between 1 and 6291456 then
        raise exception 'image exceeds 6MB limit' using errcode = '22023';
      end if;
    end if;
  end if;

  perform nohut_private.canonical_command_json(p);
end $$;

-- 2. Windows-only Initial Database Synchronization, Resumable Snapshot Upload & Recovery RPCs
create function public.nohut_agent_begin_initial_sync(
  p_token text,
  p_migration_id uuid,
  p_snapshot_revision bigint,
  p_snapshot_seq bigint,
  p_manifest_sha256 text,
  p_backup_verified boolean
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  a nohut_private.windows_agents;
  prior nohut_private.sync_migrations;
begin
  a := nohut_private.authenticate_windows_agent(p_token);
  if p_backup_verified is distinct from true then
    raise exception 'pre_sync_backup_required' using errcode = '42501';
  end if;
  if p_migration_id is null or p_snapshot_revision is null or p_snapshot_revision < 0
     or p_snapshot_seq is null or p_snapshot_seq < 0
     or p_manifest_sha256 is null or p_manifest_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid initial sync parameters' using errcode = '22023';
  end if;

  perform 1 from nohut_private.authority_epochs e
   where e.restaurant_id = a.restaurant_id and e.authority_epoch = a.authority_epoch
     and e.retired_at is null for update;
  if not found then
    raise exception 'inactive authority' using errcode = '42501';
  end if;

  select * into prior from nohut_private.sync_migrations m
   where m.restaurant_id = a.restaurant_id and m.migration_id = p_migration_id;
  if found then
    if prior.authority_epoch = a.authority_epoch
       and prior.snapshot_revision = p_snapshot_revision
       and prior.snapshot_seq = p_snapshot_seq
       and prior.manifest_sha256 = p_manifest_sha256 then
      return jsonb_build_object('status', 'duplicate', 'migration_status', prior.status, 'migration_id', p_migration_id);
    end if;
    return jsonb_build_object('status', 'conflict', 'migration_status', prior.status, 'migration_id', p_migration_id);
  end if;

  if exists(select 1 from nohut_private.sync_migrations m
    where m.restaurant_id = a.restaurant_id and m.authority_epoch = a.authority_epoch
      and m.status in ('active', 'uploading', 'paused', 'catching_up', 'verifying', 'verified_pending_activation')) then
    raise exception 'migration already in progress or active for epoch' using errcode = '42501';
  end if;

  insert into nohut_private.sync_migrations(
    restaurant_id, migration_id, authority_epoch, snapshot_revision, snapshot_seq,
    schema_version, manifest_sha256, status
  ) values (
    a.restaurant_id, p_migration_id, a.authority_epoch, p_snapshot_revision, p_snapshot_seq,
    1, p_manifest_sha256, 'uploading'
  );

  return jsonb_build_object('status', 'accepted', 'migration_status', 'uploading', 'migration_id', p_migration_id);
end $$;

create function public.nohut_agent_upload_snapshot_batch(
  p_token text,
  p_migration_id uuid,
  p_batch_id uuid,
  p_category text,
  p_item_count integer,
  p_body_sha256 text,
  p_events jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  a nohut_private.windows_agents;
  m nohut_private.sync_migrations;
  prior nohut_private.migration_batches;
  ev jsonb;
  rev bigint;
begin
  a := nohut_private.authenticate_windows_agent(p_token);
  if p_migration_id is null or p_batch_id is null or p_category is null or length(trim(p_category)) not between 1 and 64
     or p_item_count is null or p_item_count < 0
     or p_body_sha256 is null or p_body_sha256 !~ '^[0-9a-f]{64}$'
     or p_events is null or jsonb_typeof(p_events) <> 'array' then
    raise exception 'invalid snapshot batch' using errcode = '22023';
  end if;

  select * into m from nohut_private.sync_migrations sm
   where sm.restaurant_id = a.restaurant_id and sm.migration_id = p_migration_id
     and sm.authority_epoch = a.authority_epoch for update;
  if not found or m.status not in ('uploading', 'paused') then
    raise exception 'migration not accepting batches' using errcode = '42501';
  end if;

  select * into prior from nohut_private.migration_batches b
   where b.restaurant_id = a.restaurant_id and b.migration_id = p_migration_id and b.batch_id = p_batch_id;
  if found then
    if prior.category = p_category and prior.item_count = p_item_count and prior.body_sha256 = p_body_sha256 then
      return jsonb_build_object('status', 'duplicate', 'batch_id', p_batch_id);
    end if;
    return jsonb_build_object('status', 'conflict', 'batch_id', p_batch_id);
  end if;

  rev := greatest(m.snapshot_revision, 1);
  for ev in select value from jsonb_array_elements(p_events) order by case value->>'entity_type'
    when 'employees' then 0 when 'typed_catalog' then 10 when 'shiftPlans' then 15 when 'shifts' then 20
    when 'timesheetWeeks' then 25 when 'typed_order' then 30 when 'typed_platform' then 40 when 'typed_print' then 50
    when 'typed_finance' then 60 when 'typed_ledger' then 70 when 'workforceSummaries' then 80
    when 'qrMenuState' then 85 when 'dailyReports' then 88 when 'notifications' then 89 else 90 end loop
    case ev->>'entity_type'
      when 'employees' then perform nohut_private.apply_employee_projection(a.restaurant_id, rev, ev->'payload');
      when 'typed_catalog' then perform nohut_private.apply_typed_projection(a.restaurant_id, rev, ev->>'entity_id', ev->'payload');
      when 'typed_finance' then perform nohut_private.apply_typed_finance(a.restaurant_id, rev, ev->'payload');
      when 'typed_ledger' then perform nohut_private.apply_typed_ledger(a.restaurant_id, rev, ev->>'entity_id', ev->'payload');
      when 'typed_platform' then perform nohut_private.apply_typed_platform(a.restaurant_id, rev, ev->>'entity_id', ev->'payload');
      when 'typed_print' then perform nohut_private.apply_typed_print(a.restaurant_id, rev, ev->>'entity_id', ev->'payload');
      when 'typed_order' then perform nohut_private.apply_typed_order(a.restaurant_id, rev, ev->>'entity_id', ev->'payload');
      when 'shifts' then perform nohut_private.apply_shift_projection(a.restaurant_id, rev, ev->'payload');
      when 'timesheetWeeks' then perform nohut_private.apply_timesheet_projection(a.restaurant_id, rev, ev->'payload');
      when 'shiftPlans' then
        perform nohut_private.apply_plan_projection(a.restaurant_id, rev, ev->'payload');
        perform nohut_private.record_projection_watermark(a.restaurant_id, 'shift_plans', rev, clock_timestamp());
      when 'workforceSummaries' then perform nohut_private.apply_workforce_summary_projection(a.restaurant_id, rev, ev->'payload');
      when 'qrMenuState' then perform nohut_private.apply_qr_menu_projection(a.restaurant_id, rev, ev->'payload');
      when 'dailyReports' then perform nohut_private.apply_daily_report_projection(a.restaurant_id, rev, ev->'payload');
      when 'notifications' then perform nohut_private.apply_notifications_projection(a.restaurant_id, rev, ev->'payload');
      else raise exception 'unsupported snapshot entity type: %', ev->>'entity_type' using errcode = '22023';
    end case;
  end loop;

  insert into nohut_private.migration_batches(
    restaurant_id, migration_id, batch_id, category, item_count, body_sha256, committed_at
  ) values (
    a.restaurant_id, p_migration_id, p_batch_id, p_category, p_item_count, p_body_sha256, clock_timestamp()
  );

  if m.status = 'paused' then
    update nohut_private.sync_migrations set status = 'uploading'
     where restaurant_id = a.restaurant_id and migration_id = p_migration_id;
  end if;

  return jsonb_build_object('status', 'accepted', 'batch_id', p_batch_id);
end $$;

create function public.nohut_agent_activate_initial_sync(
  p_token text,
  p_migration_id uuid,
  p_expected_batches integer,
  p_expected_manifest_sha256 text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  a nohut_private.windows_agents;
  m nohut_private.sync_migrations;
  committed_cnt integer;
begin
  a := nohut_private.authenticate_windows_agent(p_token);
  select * into m from nohut_private.sync_migrations sm
   where sm.restaurant_id = a.restaurant_id and sm.migration_id = p_migration_id
     and sm.authority_epoch = a.authority_epoch for update;
  if not found then
    raise exception 'migration not found' using errcode = '42501';
  end if;
  if m.manifest_sha256 is distinct from p_expected_manifest_sha256 then
    raise exception 'manifest mismatch' using errcode = '22023';
  end if;
  if m.status = 'active' then
    return jsonb_build_object('status', 'duplicate', 'migration_status', 'active', 'snapshot_seq', m.snapshot_seq, 'snapshot_revision', m.snapshot_revision);
  end if;
  if m.status not in ('uploading', 'catching_up', 'verifying', 'verified_pending_activation') then
    raise exception 'migration cannot be activated from status %', m.status using errcode = '42501';
  end if;

  select count(*) into committed_cnt from nohut_private.migration_batches b
   where b.restaurant_id = a.restaurant_id and b.migration_id = p_migration_id;
  if committed_cnt <> p_expected_batches then
    raise exception 'incomplete_batches: expected %, got %', p_expected_batches, committed_cnt using errcode = '22023';
  end if;

  update nohut_private.sync_migrations set status = 'active'
   where restaurant_id = a.restaurant_id and migration_id = p_migration_id;

  insert into nohut_private.sync_checkpoints(
    restaurant_id, authority_epoch, last_acked_seq, last_acked_revision, updated_at
  ) values (
    a.restaurant_id, a.authority_epoch, m.snapshot_seq, m.snapshot_revision, clock_timestamp()
  )
  on conflict (restaurant_id, authority_epoch) do update set
    last_acked_seq = excluded.last_acked_seq,
    last_acked_revision = excluded.last_acked_revision,
    updated_at = clock_timestamp();

  return jsonb_build_object(
    'status', 'accepted',
    'migration_status', 'active',
    'authority_epoch', a.authority_epoch,
    'snapshot_seq', m.snapshot_seq,
    'snapshot_revision', m.snapshot_revision,
    'committed_batches', committed_cnt
  );
end $$;

create function public.nohut_agent_abort_initial_sync(
  p_token text,
  p_migration_id uuid,
  p_reason text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  a nohut_private.windows_agents;
  m nohut_private.sync_migrations;
begin
  a := nohut_private.authenticate_windows_agent(p_token);
  select * into m from nohut_private.sync_migrations sm
   where sm.restaurant_id = a.restaurant_id and sm.migration_id = p_migration_id
     and sm.authority_epoch = a.authority_epoch for update;
  if not found then
    raise exception 'migration not found' using errcode = '42501';
  end if;
  if m.status = 'active' then
    raise exception 'cannot abort active migration' using errcode = '42501';
  end if;
  update nohut_private.sync_migrations set status = 'safely_aborted'
   where restaurant_id = a.restaurant_id and migration_id = p_migration_id;
  return jsonb_build_object('status', 'safely_aborted', 'migration_id', p_migration_id);
end $$;

create function public.nohut_agent_migration_status(
  p_token text,
  p_migration_id uuid default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  a nohut_private.windows_agents;
  m nohut_private.sync_migrations;
  batches_json jsonb;
  cp nohut_private.sync_checkpoints;
begin
  a := nohut_private.authenticate_windows_agent(p_token);
  if p_migration_id is not null then
    select * into m from nohut_private.sync_migrations sm
     where sm.restaurant_id = a.restaurant_id and sm.migration_id = p_migration_id;
  else
    select * into m from nohut_private.sync_migrations sm
     where sm.restaurant_id = a.restaurant_id and sm.authority_epoch = a.authority_epoch
     order by sm.created_at desc limit 1;
  end if;

  select * into cp from nohut_private.sync_checkpoints c
   where c.restaurant_id = a.restaurant_id and c.authority_epoch = a.authority_epoch;

  if m.migration_id is null then
    return jsonb_build_object(
      'exists', false,
      'authority_epoch', a.authority_epoch,
      'checkpoint', case when cp.authority_epoch is null then null else jsonb_build_object(
        'last_acked_seq', cp.last_acked_seq, 'last_acked_revision', cp.last_acked_revision, 'updated_at', cp.updated_at
      ) end
    );
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'batch_id', b.batch_id, 'category', b.category, 'item_count', b.item_count,
    'body_sha256', b.body_sha256, 'committed_at', b.committed_at
  ) order by b.committed_at, b.batch_id), '[]'::jsonb)
  into batches_json
  from nohut_private.migration_batches b
  where b.restaurant_id = a.restaurant_id and b.migration_id = m.migration_id;

  return jsonb_build_object(
    'exists', true,
    'migration_id', m.migration_id,
    'authority_epoch', m.authority_epoch,
    'status', m.status,
    'snapshot_revision', m.snapshot_revision,
    'snapshot_seq', m.snapshot_seq,
    'manifest_sha256', m.manifest_sha256,
    'batches', batches_json,
    'checkpoint', case when cp.authority_epoch is null then null else jsonb_build_object(
      'last_acked_seq', cp.last_acked_seq, 'last_acked_revision', cp.last_acked_revision, 'updated_at', cp.updated_at
    ) end
  );
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in (
      'nohut_agent_begin_initial_sync', 'nohut_agent_upload_snapshot_batch',
      'nohut_agent_activate_initial_sync', 'nohut_agent_abort_initial_sync',
      'nohut_agent_migration_status'
    ) loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', f.signature);
    execute format('grant execute on function %s to anon, authenticated', f.signature);
  end loop;
end $$;

commit;
