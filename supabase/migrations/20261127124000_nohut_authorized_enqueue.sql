-- PR-05B / 5B: private authorization-aware enqueue boundary.
-- Inputs identifying the user, session and device MUST come from a future
-- verified BFF, never an unauthenticated phone. No caller grants here.
-- Claim-time reauthorization, payload privacy rules and scoped transport
-- remain mandatory before enabling remote commands.
begin;
create function nohut_private.enqueue_command(
  p_user uuid,p_session uuid,p_device uuid,p_client text,p_version bigint,
  p_request uuid,p_action text,p_payload_json text
) returns text language plpgsql security invoker set search_path=pg_catalog,nohut_private
as $$
declare
  op text; ttl interval:=interval '15 minutes'; v_restaurant uuid; v_epoch uuid;
  a jsonb; body jsonb; h text; issued timestamptz; prior nohut_private.commands%rowtype;
begin
  if p_client is null or p_client not in ('personel','yonetici') then
    raise exception 'remote client required' using errcode='42501';
  end if;
  op:=case p_action
    when 'create_order' then 'orders.create' when 'add_order_items' then 'orders.create'
    when 'record_payment' then 'payments.take' when 'split_bill' then 'payments.take'
    when 'move_order' then 'orders.move' when 'close_order' then 'orders.release'
    when 'mark_delivered' then 'orders.release' when 'edit_order_line' then 'orders.edit'
    when 'delete_order' then 'orders.edit' when 'clock_in_out' then 'shifts.self'
    when 'correct_shift' then 'shifts.manage' when 'retry_print' then 'receipts.print'
    when 'set_product_sale' then 'menu.stock.toggle' when 'platform_action' then 'online.act'
    when 'print_payment_receipt' then 'receipts.print' else null end;
  if op is null then raise exception 'unsupported action' using errcode='42501'; end if;
  if nohut_private.authorize(p_user,p_session,p_device,p_client,op,p_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if p_request is null or p_payload_json is null or octet_length(p_payload_json)>65536 then
    raise exception 'invalid command' using errcode='22023';
  end if;
  body:=p_payload_json::jsonb;
  if jsonb_typeof(body) is distinct from 'object'
    or body ?| array['staffId','requestId','actor','restaurant_id','authority_epoch','grants','is_owner'] then
    raise exception 'invalid payload identity fields' using errcode='22023';
  end if;
  if p_action in ('clock_in_out','retry_print','platform_action','print_payment_receipt') then ttl:=interval '5 minutes'; end if;
  select u.restaurant_id into v_restaurant from nohut_private.app_users u where u.user_id=p_user;
  select e.authority_epoch into v_epoch from nohut_private.authority_epochs e
    where e.restaurant_id=v_restaurant and e.retired_at is null for update;
  if not found then raise exception 'no active authority' using errcode='42501'; end if;
  if not exists(select 1 from nohut_private.sync_migrations m where m.restaurant_id=v_restaurant
    and m.authority_epoch=v_epoch and m.status='active') then
    raise exception 'sync not activated' using errcode='42501';
  end if;
  -- Revalidate after waiting for the authority lock.
  if nohut_private.authorize(p_user,p_session,p_device,p_client,op,p_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode='42501';
  end if;
  a:=nohut_private.command_actor(p_user);
  if a is null or jsonb_typeof(a->'employee_id') is distinct from 'number'
    or (a->>'permission_version')::bigint is distinct from p_version then
    raise exception 'actor not linked' using errcode='42501';
  end if;
  h:=encode(sha256(convert_to(p_payload_json,'UTF8')),'hex');
  select * into prior from nohut_private.commands q where q.restaurant_id=v_restaurant and q.request_id=p_request::text;
  if found then
    if prior.authority_epoch=v_epoch and prior.envelope->>'actor_user_id'=p_user::text
      and prior.envelope->>'device_session_id'=p_session::text and prior.envelope->>'device_id'=p_device::text
      and prior.envelope->>'client'=p_client and prior.envelope->>'action_type'=p_action
      and prior.envelope->>'payload_sha256'=h and prior.envelope->'payload'=body then return 'duplicate'; end if;
    return 'conflict';
  end if;
  issued:=clock_timestamp();
  insert into nohut_private.commands(restaurant_id,request_id,authority_epoch,envelope,issued_at,expires_at)
    values(v_restaurant,p_request::text,v_epoch,jsonb_build_object(
      'restaurant_id',v_restaurant,'request_id',p_request,'authority_epoch',v_epoch,'schema_version',1,
      'actor_user_id',p_user,'device_session_id',p_session,'device_id',p_device,'actor',a,
      'client',p_client,'action_type',p_action,'operation',op,'payload',body,'payload_sha256',h,
      'issued_at',issued,'expires_at',issued+ttl),issued,issued+ttl);
  return 'accepted';
end $$;
revoke all on function nohut_private.enqueue_command(uuid,uuid,uuid,text,bigint,uuid,text,text)
  from public,anon,authenticated,service_role;
commit;
