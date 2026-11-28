-- JWT-scoped app command API. No app writes authoritative business rows.
begin;
create function nohut_private.command_shape(p jsonb, required_fields jsonb, optional_fields jsonb default '{}')
returns void language plpgsql immutable set search_path='' as $$
declare k text; ty text; v jsonb; shape jsonb:=required_fields||optional_fields;
begin
  if jsonb_typeof(p) is distinct from 'object' or not(p ?& array(select jsonb_object_keys(required_fields))) then
    raise exception 'invalid command fields' using errcode='22023';
  end if;
  for k,v in select * from jsonb_each(p) loop
    ty:=shape->>k;
    if ty is null then raise exception 'unknown command field' using errcode='22023'; end if;
    if ty like 'nullable_%' and v='null'::jsonb then continue; end if;
    ty:=replace(ty,'nullable_','');
    if ty='integer' then
      if jsonb_typeof(v) is distinct from 'number' or v::text !~ '^-?[0-9]+$'
        or abs((v::text)::numeric)>9007199254740991 then raise exception 'invalid command integer' using errcode='22023'; end if;
    elsif jsonb_typeof(v) is distinct from ty then
      raise exception 'invalid command field type' using errcode='22023';
    elsif ty='string' and length(v#>>'{}')>1000 then
      raise exception 'command text too long' using errcode='22023';
    end if;
  end loop;
end $$;

create function nohut_private.command_removed(p jsonb)
returns void language plpgsql immutable set search_path='' as $$
begin
  if p is null then return; end if;
  if jsonb_typeof(p) is distinct from 'array' or jsonb_array_length(p)>50
    or exists(select 1 from jsonb_array_elements(p) x where jsonb_typeof(x)<>'string' or length(x#>>'{}')>100) then
    raise exception 'invalid removed ingredients' using errcode='22023';
  end if;
end $$;

create function nohut_private.command_line(p jsonb)
returns void language plpgsql immutable set search_path='' as $$
declare c jsonb;
begin
  perform nohut_private.command_shape(p,'{"qty":"integer"}',
    '{"productId":"integer","customItem":"boolean","name":"string","unitPriceCents":"integer","expectedPriceCents":"integer","note":"string","removed":"array","adjustmentCents":"integer","components":"array"}');
  if (p->>'qty')::bigint not between 1 and 1000 or length(coalesce(p->>'note',''))>500
    or abs(coalesce((p->>'adjustmentCents')::bigint,0))>10000000 then
    raise exception 'invalid order line' using errcode='22023'; end if;
  if p->'customItem'='true'::jsonb then
    if not(p ?& array['name','unitPriceCents']) or length(trim(p->>'name')) not between 1 and 100
      or (p->>'unitPriceCents')::bigint not between 1 and 9999999 then
      raise exception 'invalid custom item' using errcode='22023'; end if;
  elsif not(p ? 'productId') or (p->>'productId')::bigint<0 or p ?| array['name','unitPriceCents'] then
    raise exception 'invalid product identity' using errcode='22023';
  end if;
  if p ? 'expectedPriceCents' and (p->>'expectedPriceCents')::bigint<0 then raise exception 'invalid expected price' using errcode='22023'; end if;
  perform nohut_private.command_removed(p->'removed');
  if p ? 'components' then
    if jsonb_array_length(p->'components')>100 then raise exception 'too many components' using errcode='22023'; end if;
    for c in select * from jsonb_array_elements(p->'components') loop
      perform nohut_private.command_shape(c,'{"slot":"integer","productId":"integer","qty":"integer","removed":"array"}',
        '{"note":"string","adjustmentCents":"integer"}');
      if c->'qty'<>'1'::jsonb or length(coalesce(c->>'note',''))>500
        or abs(coalesce((c->>'adjustmentCents')::bigint,0))>10000000 then
        raise exception 'invalid campaign component' using errcode='22023'; end if;
      perform nohut_private.command_removed(c->'removed');
    end loop;
  end if;
end $$;

create function nohut_private.validate_command_payload(p_action text,p jsonb)
returns void language plpgsql immutable set search_path='' as $$
declare line jsonb; action text:=p->>'action'; required_fields jsonb; optional_fields jsonb:='{}'; k text; v jsonb;
begin
  if p is null or octet_length(p::text)>65536 then raise exception 'invalid command size' using errcode='22023'; end if;
  if p_action ~ '^(sync_|backup_|restore_)' or p_action in ('first_sync','full_resync') then
    raise exception 'windows_only' using errcode='42501'; end if;
  if p_action in ('create_order','add_order_items') then
    required_fields:='{"expectedRevision":"integer","source":"string","lines":"array"}';
    if p_action='add_order_items' then required_fields:=required_fields||'{"orderId":"integer"}'; end if;
    optional_fields:='{"table":"nullable_integer","pickupChannel":"string","customer":"object","expectedTableOrderId":"nullable_integer"}';
  elsif p_action in ('record_payment','split_bill','move_order','close_order','mark_delivered','edit_order_line','delete_order','print_payment_receipt') then
    required_fields:='{"expectedRevision":"integer","orderId":"integer","action":"string"}';
    case p_action
      when 'record_payment' then
        if action not in ('pay','payMixed','payProducts') or action is null then raise exception 'action mismatch' using errcode='22023'; end if;
        required_fields:=required_fields||'{"amountCents":"integer","confirmed":"boolean"}';
        optional_fields:='{"guestId":"nullable_integer","receivedCents":"nullable_integer"}';
        if action='payMixed' then required_fields:=required_fields||'{"cashCents":"integer","printReceipt":"boolean"}';
        else required_fields:=required_fields||'{"method":"string"}'; end if;
        if action='pay' then required_fields:=required_fields||'{"printReceipt":"boolean"}'; end if;
        if action='payProducts' then required_fields:=required_fields||'{"shares":"object"}'; optional_fields:=optional_fields||'{"cashCents":"nullable_integer"}'; end if;
      when 'split_bill' then
        case action
          when 'splitEqual' then required_fields:=required_fields||'{"count":"integer"}';
          when 'addGuest' then required_fields:=required_fields||'{"name":"string"}';
          when 'allocate' then required_fields:=required_fields||'{"guestId":"integer","key":"string","cents":"integer"}';
          when 'resetGuests' then null;
          else raise exception 'action mismatch' using errcode='22023';
        end case;
      when 'move_order' then
        if action is distinct from 'move' then raise exception 'action mismatch' using errcode='22023'; end if;
        required_fields:=required_fields||'{"table":"integer"}';
      when 'close_order' then if action is distinct from 'close' then raise exception 'action mismatch' using errcode='22023'; end if;
      when 'mark_delivered' then if action is distinct from 'status' then raise exception 'action mismatch' using errcode='22023'; end if;
      when 'edit_order_line' then
        if action is distinct from 'editLine' then raise exception 'action mismatch' using errcode='22023'; end if;
        required_fields:=required_fields||'{"key":"string","qty":"integer","note":"string","removed":"array"}';
        optional_fields:='{"adjustmentCents":"integer","components":"array"}';
      when 'delete_order' then
        if action is distinct from 'delete' then raise exception 'action mismatch' using errcode='22023'; end if;
        required_fields:=required_fields||'{"confirmed":"boolean","reason":"string"}';
      when 'print_payment_receipt' then
        if action is distinct from 'printProductPayment' then raise exception 'action mismatch' using errcode='22023'; end if;
        required_fields:=required_fields||'{"paymentId":"string"}';
    end case;
  elsif p_action='clock_in_out' then
    required_fields:='{"action":"string"}';
    if action is null or action not in ('clockIn','clockOut') then raise exception 'action mismatch' using errcode='22023'; end if;
  elsif p_action='correct_shift' then
    required_fields:='{"shiftId":"string","reason":"string"}';
    optional_fields:='{"start":"string","end":"nullable_string"}';
  elsif p_action='retry_print' then
    required_fields:='{"target":"string","checked":"boolean"}';
    case p->>'target'
      when 'kitchen' then required_fields:=required_fields||'{"orderId":"integer","batchId":"integer"}';
      when 'payment' then required_fields:=required_fields||'{"receiptRequestId":"string"}';
      when 'platform' then required_fields:=required_fields||'{"orderKey":"string"}';
      else raise exception 'invalid print target' using errcode='22023';
    end case;
  elsif p_action='set_product_sale' then required_fields:='{"productId":"integer","active":"boolean"}';
  elsif p_action='platform_action' then
    required_fields:='{"action":"string","packageId":"string"}'; optional_fields:='{"preparationMinutes":"integer"}';
    if action is null or action not in ('accept','ready') then raise exception 'action mismatch' using errcode='22023'; end if;
  else raise exception 'unsupported action' using errcode='42501';
  end if;
  perform nohut_private.command_shape(p,required_fields,optional_fields);
  if p ? 'expectedRevision' and (p->>'expectedRevision')::bigint<0 then raise exception 'invalid revision' using errcode='22023'; end if;
  if p ? 'table' and p->'table'<>'null'::jsonb and (p->>'table')::bigint not between 1 and 5 then raise exception 'invalid table' using errcode='22023'; end if;
  if p ? 'orderId' and (p->>'orderId')::bigint<1 then raise exception 'invalid order' using errcode='22023'; end if;
  if p ? 'confirmed' and p->'confirmed'<>'true'::jsonb then raise exception 'confirmation required' using errcode='22023'; end if;
  if p_action in ('create_order','add_order_items') then
    if p->>'source' not in ('Masa','Gel-Al') or (p->>'source'='Masa' and (p->'table' is null or p->'table'='null'::jsonb))
      or (p->>'source'='Gel-Al' and p->'table' is not null and p->'table'<>'null'::jsonb)
      or jsonb_array_length(p->'lines') not between 1 and 200 then raise exception 'invalid order' using errcode='22023'; end if;
    if p ? 'pickupChannel' and p->>'pickupChannel' not in ('Tezgahtan','Telefon') then raise exception 'invalid pickup channel' using errcode='22023'; end if;
    if p ? 'customer' then
      perform nohut_private.command_shape(p->'customer','{}','{"time":"string"}');
      if length(coalesce(p->'customer'->>'time',''))>40 then raise exception 'invalid pickup time' using errcode='22023'; end if;
    end if;
    for line in select * from jsonb_array_elements(p->'lines') loop perform nohut_private.command_line(line); end loop;
  elsif p_action='record_payment' then
    if (p->>'amountCents')::bigint not between 1 and 100000000000 or p->'confirmed'<>'true'::jsonb then raise exception 'invalid payment' using errcode='22023'; end if;
    if p ? 'method' and p->>'method' not in ('Nakit','Kart','Karışık') then raise exception 'invalid payment method' using errcode='22023'; end if;
    if action='pay' and p->>'method'='Karışık' then raise exception 'mixed payment route required' using errcode='22023'; end if;
    if action='payMixed' or p->>'method'='Karışık' then
      if p->>'cashCents' is null or (p->>'cashCents')::bigint<=0 or (p->>'cashCents')::bigint>=(p->>'amountCents')::bigint then raise exception 'invalid mixed payment' using errcode='22023'; end if;
    end if;
    if p ? 'receivedCents' and (p->>'receivedCents')::bigint<0 then raise exception 'invalid received cash' using errcode='22023'; end if;
    if action='payProducts' then
      if (select count(*) from jsonb_object_keys(p->'shares')) not between 1 and 200 then raise exception 'invalid shares' using errcode='22023'; end if;
      for k,v in select * from jsonb_each(p->'shares') loop
        perform nohut_private.command_shape(jsonb_build_object('cents',v),'{"cents":"integer"}');
        if length(k)>200 or (v::text)::bigint<=0 then raise exception 'invalid product share' using errcode='22023'; end if;
      end loop;
    end if;
  elsif p_action='split_bill' then
    if action='splitEqual' and (p->>'count')::bigint not between 2 and 100 then raise exception 'invalid split count' using errcode='22023'; end if;
    if action='allocate' and (p->>'cents')::bigint<0 then raise exception 'invalid allocation' using errcode='22023'; end if;
    if action='addGuest' and length(p->>'name')>100 then raise exception 'guest name too long' using errcode='22023'; end if;
  elsif p_action='correct_shift' then
    if length(trim(p->>'reason')) not between 1 and 300 then raise exception 'correction reason required' using errcode='22023'; end if;
    if p ? 'start' then perform nohut_private.shift_timestamp(p->'start'); end if;
    if p ? 'end' then perform nohut_private.shift_timestamp(p->'end'); end if;
  elsif p_action='retry_print' and p->'checked'<>'true'::jsonb then raise exception 'printer check required' using errcode='22023';
  elsif p_action='platform_action' then
    if length(trim(p->>'packageId')) not between 1 and 200 or
      (p ? 'preparationMinutes' and (p->>'preparationMinutes')::bigint not between 1 and 180) then raise exception 'invalid platform target' using errcode='22023'; end if;
  elsif p_action='edit_order_line' then
    if (p->>'qty')::bigint not between 0 and 1000 or length(p->>'note')>500 then raise exception 'invalid line edit' using errcode='22023'; end if;
    perform nohut_private.command_removed(p->'removed');
    if p ? 'components' then
      perform nohut_private.command_line(jsonb_build_object('productId',0,'qty',1,'components',p->'components'));
    end if;
  end if;
  -- Enforce cross-runtime canonical numeric/Unicode restrictions as well.
  perform nohut_private.canonical_command_json(p);
end $$;

create function public.nohut_enqueue_command(p_device_id uuid,p_client text,p_permission_version bigint,p_request_id uuid,p_action text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare status text;
begin
  perform nohut_private.validate_command_payload(p_action,p_payload);
  status:=nohut_private.enqueue_command(auth.uid(),public.nohut_jwt_claim('session_id')::uuid,
    p_device_id,p_client,p_permission_version,p_request_id,p_action,p_payload::text);
  return jsonb_build_object('status',status,'request_id',p_request_id);
end $$;

create function public.nohut_command_status(p_device_id uuid,p_client text,p_permission_version bigint,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c nohut_private.commands; u nohut_private.app_users;
begin
  select * into u from nohut_private.app_users where user_id=auth.uid();
  select * into c from nohut_private.commands where restaurant_id=u.restaurant_id and request_id=p_request_id::text;
  if not found or c.envelope->>'actor_user_id' is distinct from auth.uid()::text
    or nohut_private.authorize(auth.uid(),public.nohut_jwt_claim('session_id')::uuid,
      p_device_id,p_client,c.envelope->>'operation',p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode='42501';
  end if;
  return jsonb_build_object('request_id',p_request_id,'state',c.state,'result',c.result);
end $$;
revoke all on function nohut_private.command_shape(jsonb,jsonb,jsonb),nohut_private.command_removed(jsonb),
  nohut_private.command_line(jsonb),nohut_private.validate_command_payload(text,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.nohut_enqueue_command(uuid,text,bigint,uuid,text,jsonb),
  public.nohut_command_status(uuid,text,bigint,uuid) from public,anon,authenticated,service_role;
grant execute on function public.nohut_enqueue_command(uuid,text,bigint,uuid,text,jsonb),
  public.nohut_command_status(uuid,text,bigint,uuid) to authenticated;
commit;
