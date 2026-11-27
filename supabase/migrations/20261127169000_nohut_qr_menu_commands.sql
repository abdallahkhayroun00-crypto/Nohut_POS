-- Increment B (QR Menu Management — Cloud Remote Commands):
-- Extends nohut_private.validate_command_payload and nohut_private.enqueue_command
-- to support remote QR Menu management from Android/PWA clients through Windows:
--   * qr_menu_write     -> per-sub-action menu.* grant (set_price, set_stock, set_visible,
--                          save_product, save_category, save_campaign, set_image)
--   * qr_menu_publish   -> menu.qr.publish (requires expectedStamp + confirmed:true, 5m TTL)
--   * qr_menu_reconcile -> menu.qr.publish (unknown-publish-outcome reconciliation, 5m TTL)
--   * qr_menu_image     -> menu.product.edit (MIME + size/path guard, 10m TTL)
--   * qr_menu_sync      -> menu.product.edit (POS catalog sync request, 5m TTL)
-- Preserves revision/stamp checks, requestId idempotency, actor binding, and zero credentials in cloud.
begin;

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
    required_fields := '{"expectedStamp":"string","confirmed":"boolean"}';
  elsif p_action in ('qr_menu_reconcile', 'qr_menu_sync') then
    required_fields := '{}';
  elsif p_action = 'qr_menu_image' then
    required_fields := '{"expectedStamp":"string","id":"string","mime":"string"}';
    optional_fields := '{"storagePath":"string","base64":"string","sizeBytes":"integer","target":"string"}';
  else
    raise exception 'unsupported action' using errcode = '42501';
  end if;

  perform nohut_private.command_shape(p, required_fields, optional_fields);
  if p ? 'expectedRevision' and (p->>'expectedRevision')::bigint < 0 then raise exception 'invalid revision' using errcode = '22023'; end if;
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
  elsif p_action in ('qr_menu_write', 'qr_menu_publish', 'qr_menu_image') then
    stamp := p->>'expectedStamp';
    if stamp is null or stamp !~ '^[0-9a-f]{16}$' then
      raise exception 'invalid expectedStamp' using errcode = '22023';
    end if;
    if p_action = 'qr_menu_write' then
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

  -- Enforce cross-runtime canonical numeric/Unicode restrictions as well.
  perform nohut_private.canonical_command_json(p);
end $$;

create or replace function nohut_private.enqueue_command(
  p_user uuid, p_session uuid, p_device uuid, p_client text, p_version bigint,
  p_request uuid, p_action text, p_payload_json text
) returns text language plpgsql security invoker set search_path = pg_catalog, nohut_private
as $$
declare
  op text;
  ttl interval := interval '15 minutes';
  v_restaurant uuid;
  v_epoch uuid;
  a jsonb;
  body jsonb;
  h text;
  issued timestamptz;
  prior nohut_private.commands%rowtype;
  sub_action text;
begin
  if p_client is null or p_client not in ('personel', 'yonetici') then
    raise exception 'remote client required' using errcode = '42501';
  end if;
  if p_request is null or p_payload_json is null or octet_length(p_payload_json) > 65536 then
    raise exception 'invalid command' using errcode = '22023';
  end if;
  body := p_payload_json::jsonb;
  if jsonb_typeof(body) is distinct from 'object'
    or body ?| array['staffId','requestId','actor','restaurant_id','authority_epoch','grants','is_owner'] then
    raise exception 'invalid payload identity fields' using errcode = '22023';
  end if;
  if nohut_private.contains_forbidden_secret_key(body) then
    raise exception 'credentials forbidden in command' using errcode = '42501';
  end if;

  sub_action := body->>'action';
  op := case p_action
    when 'create_order' then 'orders.create'
    when 'add_order_items' then 'orders.create'
    when 'record_payment' then 'payments.take'
    when 'split_bill' then 'payments.take'
    when 'move_order' then 'orders.move'
    when 'close_order' then 'orders.release'
    when 'mark_delivered' then 'orders.release'
    when 'edit_order_line' then 'orders.edit'
    when 'delete_order' then 'orders.edit'
    when 'clock_in_out' then 'shifts.self'
    when 'correct_shift' then 'shifts.manage'
    when 'retry_print' then 'receipts.print'
    when 'set_product_sale' then 'menu.stock.toggle'
    when 'platform_action' then 'online.act'
    when 'print_payment_receipt' then 'receipts.print'
    when 'qr_menu_write' then case sub_action
      when 'set_price' then 'menu.price.edit'
      when 'set_stock' then 'menu.stock.toggle'
      when 'set_visible' then 'menu.product.edit'
      when 'set_image' then 'menu.product.edit'
      when 'save_product' then 'menu.product.edit'
      when 'save_category' then 'menu.category.edit'
      when 'save_campaign' then 'menu.campaign.edit'
      else null end
    when 'qr_menu_publish' then 'menu.qr.publish'
    when 'qr_menu_reconcile' then 'menu.qr.publish'
    when 'qr_menu_image' then 'menu.product.edit'
    when 'qr_menu_sync' then 'menu.product.edit'
    else null end;

  if op is null then raise exception 'unsupported action' using errcode = '42501'; end if;
  if nohut_private.authorize(p_user, p_session, p_device, p_client, op, p_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Only pickup time, not contact fields, may cross the cloud queue.
  if body ? 'customer' and (jsonb_typeof(body->'customer') is distinct from 'object'
    or exists(select 1 from jsonb_object_keys(case when jsonb_typeof(body->'customer') = 'object' then body->'customer' else '{}'::jsonb end) k(key) where key <> 'time')
    or (body->'customer' ? 'time' and (jsonb_typeof(body->'customer'->'time') not in ('string','null')
      or length(body->'customer'->>'time') > 40))) then
    raise exception 'customer contact is local only' using errcode = '22023';
  end if;

  if p_action in ('clock_in_out','retry_print','platform_action','print_payment_receipt','qr_menu_publish','qr_menu_reconcile','qr_menu_sync') then
    ttl := interval '5 minutes';
  elsif p_action = 'qr_menu_image' then
    ttl := interval '10 minutes';
  end if;

  select u.restaurant_id into v_restaurant from nohut_private.app_users u where u.user_id = p_user;
  select e.authority_epoch into v_epoch from nohut_private.authority_epochs e
    where e.restaurant_id = v_restaurant and e.retired_at is null for update;
  if not found then raise exception 'no active authority' using errcode = '42501'; end if;
  if not exists(select 1 from nohut_private.sync_migrations m where m.restaurant_id = v_restaurant
    and m.authority_epoch = v_epoch and m.status = 'active') then
    raise exception 'sync not activated' using errcode = '42501';
  end if;
  -- Revalidate after waiting for the authority lock.
  if nohut_private.authorize(p_user, p_session, p_device, p_client, op, p_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  a := nohut_private.command_actor(p_user);
  if a is null or jsonb_typeof(a->'employee_id') is distinct from 'number'
    or (a->>'permission_version')::bigint is distinct from p_version then
    raise exception 'actor not linked' using errcode = '42501';
  end if;
  h := encode(sha256(convert_to(nohut_private.canonical_command_json(body), 'UTF8')), 'hex');
  select * into prior from nohut_private.commands q where q.restaurant_id = v_restaurant and q.request_id = p_request::text;
  if found then
    if prior.authority_epoch = v_epoch and prior.envelope->>'actor_user_id' = p_user::text
      and prior.envelope->>'device_session_id' = p_session::text and prior.envelope->>'device_id' = p_device::text
      and prior.envelope->>'client' = p_client and prior.envelope->>'action_type' = p_action
      and prior.envelope->>'payload_sha256' = h and prior.envelope->'payload' = body then
      return 'duplicate';
    end if;
    return 'conflict';
  end if;
  issued := clock_timestamp();
  insert into nohut_private.commands(restaurant_id, request_id, authority_epoch, envelope, issued_at, expires_at)
    values(v_restaurant, p_request::text, v_epoch, jsonb_build_object(
      'restaurant_id', v_restaurant, 'request_id', p_request, 'authority_epoch', v_epoch, 'schema_version', 1,
      'actor_user_id', p_user, 'device_session_id', p_session, 'device_id', p_device, 'actor', a,
      'client', p_client, 'action_type', p_action, 'operation', op, 'payload', body, 'payload_sha256', h,
      'issued_at', issued, 'expires_at', issued + ttl), issued, issued + ttl);
  return 'accepted';
end $$;

commit;
