\set ON_ERROR_STOP on
begin;
do $$
declare example jsonb; bad jsonb;
begin
  for example in select * from jsonb_array_elements('[
    {"a":"create_order","p":{"expectedRevision":1,"source":"Masa","table":1,"lines":[{"productId":0,"qty":2,"expectedPriceCents":14000}]}},
    {"a":"add_order_items","p":{"expectedRevision":1,"source":"Masa","table":1,"orderId":1,"lines":[{"customItem":true,"name":"Synthetic","unitPriceCents":1234,"qty":1}]}},
    {"a":"record_payment","p":{"expectedRevision":1,"orderId":1,"action":"pay","method":"Nakit","amountCents":100,"confirmed":true,"printReceipt":false}},
    {"a":"record_payment","p":{"expectedRevision":1,"orderId":1,"action":"payMixed","amountCents":100,"cashCents":40,"confirmed":true,"printReceipt":false}},
    {"a":"record_payment","p":{"expectedRevision":1,"orderId":1,"action":"payProducts","method":"Kart","amountCents":100,"confirmed":true,"shares":{"1:0":100}}},
    {"a":"split_bill","p":{"expectedRevision":1,"orderId":1,"action":"splitEqual","count":2}},
    {"a":"move_order","p":{"expectedRevision":1,"orderId":1,"action":"move","table":2}},
    {"a":"close_order","p":{"expectedRevision":1,"orderId":1,"action":"close"}},
    {"a":"clock_in_out","p":{"action":"clockIn"}},
    {"a":"correct_shift","p":{"shiftId":"synthetic","reason":"Synthetic correction","end":null}},
    {"a":"retry_print","p":{"target":"kitchen","orderId":1,"batchId":1,"checked":true}},
    {"a":"set_product_sale","p":{"productId":0,"active":false}},
    {"a":"platform_action","p":{"action":"accept","packageId":"synthetic-package","preparationMinutes":20}},
    {"a":"platform_action","p":{"action":"ready","packageId":"synthetic-package"}}
  ]') loop
    perform nohut_private.validate_command_payload(example->>'a',example->'p');
  end loop;
  for example in select * from jsonb_array_elements('[
    {"a":"create_order","p":{}},
    {"a":"create_order","p":{"expectedRevision":1,"source":"Masa","table":1,"staffId":99,"lines":[{"productId":0,"qty":1}]}},
    {"a":"create_order","p":{"expectedRevision":1,"source":"Gel-Al","customer":{"phone":"synthetic"},"lines":[{"productId":0,"qty":1}]}},
    {"a":"create_order","p":{"expectedRevision":1,"source":"Masa","table":1,"lines":[{"productId":0,"qty":1.5}]}},
    {"a":"record_payment","p":{"expectedRevision":1,"orderId":1,"action":"close","amountCents":1,"confirmed":true}},
    {"a":"record_payment","p":{"expectedRevision":1,"orderId":1,"action":"payMixed","amountCents":100,"cashCents":100,"confirmed":true,"printReceipt":false}},
    {"a":"retry_print","p":{"target":"kitchen","orderId":1,"batchId":1,"checked":false}},
    {"a":"clock_in_out","p":{"action":"clockIn","employeeId":99}},
    {"a":"platform_action","p":{"action":"cancel","packageId":"synthetic"}}
  ]') loop
    begin
      perform nohut_private.validate_command_payload(example->>'a',example->'p');
      raise exception 'invalid payload accepted: %',example;
    exception when invalid_parameter_value then null; end;
  end loop;
end $$;

do $$
declare r uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); u uuid:=gen_random_uuid(); other_user uuid:=gen_random_uuid();
  d uuid:=gen_random_uuid(); s uuid:=gen_random_uuid(); od uuid:=gen_random_uuid(); os uuid:=gen_random_uuid(); q uuid:=gen_random_uuid(); result jsonb;
  payload jsonb:='{"expectedRevision":1,"source":"Masa","table":1,"lines":[{"productId":0,"qty":1}]}';
begin
  insert into nohut_private.restaurants(restaurant_id) values(r);
  insert into nohut_private.authority_epochs(restaurant_id,authority_epoch) values(r,e);
  insert into nohut_private.sync_migrations(restaurant_id,migration_id,authority_epoch,snapshot_revision,snapshot_seq,schema_version,manifest_sha256,status)
    values(r,gen_random_uuid(),e,0,0,1,repeat('a',64),'active');
  insert into nohut_private.app_users(user_id,restaurant_id,username,pos_employee_id,role_template)
    values(u,r,'syntheticcommandstaff',1,'Personel'),(other_user,r,'syntheticotherstaff',2,'Personel');
  insert into nohut_private.user_grants(user_id,operation_id) values(u,'orders.create'),(other_user,'orders.create');
  perform nohut_private.enroll_device(u,d,s,'personel','Synthetic');
  perform nohut_private.enroll_device(other_user,od,os,'personel','Synthetic');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'session_id',s,'aal','aal1')::text,true);
  set local role authenticated;
  result:=public.nohut_enqueue_command(d,'personel',1,q,'create_order',payload);
  if result->>'status'<>'accepted' then raise exception 'JWT enqueue failed'; end if;
  if public.nohut_enqueue_command(d,'personel',1,q,'create_order',payload)->>'status'<>'duplicate' then raise exception 'lost enqueue ACK'; end if;
  if public.nohut_command_status(d,'personel',1,q)->>'state'<>'pending' then raise exception 'premature success'; end if;
  begin perform public.nohut_enqueue_command(d,'personel',1,gen_random_uuid(),'sync_manual','{}'); raise exception 'remote sync allowed';
    exception when insufficient_privilege then null; end;
  reset role;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',other_user,'session_id',os,'aal','aal1')::text,true);
  set local role authenticated;
  begin perform public.nohut_command_status(od,'personel',1,q); raise exception 'other actor receipt leaked';
    exception when insufficient_privilege then null; end;
  reset role;
  delete from nohut_private.user_grants where user_id=u;
  update nohut_private.app_users set permission_version=2 where user_id=u;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'session_id',s,'aal','aal1')::text,true);
  set local role authenticated;
  begin perform public.nohut_enqueue_command(d,'personel',1,q,'create_order',payload); raise exception 'revoked cached enqueue';
    exception when insufficient_privilege then null; end;
  begin perform public.nohut_command_status(d,'personel',2,q); raise exception 'revoked receipt access';
    exception when insufficient_privilege then null; end;
  reset role;
  if has_function_privilege('anon','public.nohut_enqueue_command(uuid,text,bigint,uuid,text,jsonb)','EXECUTE') then raise exception 'anonymous app RPC'; end if;
end $$;
rollback;
