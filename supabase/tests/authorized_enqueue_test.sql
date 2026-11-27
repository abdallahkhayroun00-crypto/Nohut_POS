\set ON_ERROR_STOP on
begin;
do $$
declare r uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); u uuid:=gen_random_uuid();
  d uuid:=gen_random_uuid(); s uuid:=gen_random_uuid(); q uuid:=gen_random_uuid(); env jsonb;
begin
  insert into nohut_private.restaurants(restaurant_id) values(r);
  insert into nohut_private.authority_epochs(restaurant_id,authority_epoch) values(r,e);
  insert into nohut_private.sync_migrations(restaurant_id,migration_id,authority_epoch,snapshot_revision,snapshot_seq,schema_version,manifest_sha256,status)
    values(r,gen_random_uuid(),e,0,0,1,repeat('a',64),'active');
  insert into nohut_private.app_users(user_id,restaurant_id,username,pos_employee_id,role_template)
    values(u,r,'synthetic',1,'Personel');
  insert into nohut_private.user_grants(user_id,operation_id) values(u,'orders.create');
  perform nohut_private.enroll_device(u,d,s,'personel','Synthetic');
  if nohut_private.enqueue_command(u,s,d,'personel',1,q,'create_order','{}')<>'accepted' then raise exception 'not queued'; end if;
  select envelope into strict env from nohut_private.commands where restaurant_id=r and request_id=q::text;
  if env->'actor'->>'employee_id'<>'1' or env->>'actor_user_id'<>u::text or env->>'restaurant_id'<>r::text then raise exception 'wrong server actor'; end if;
  if nohut_private.enqueue_command(u,s,d,'personel',1,q,'create_order','{}')<>'duplicate' then raise exception 'duplicate not recognized'; end if;
  if nohut_private.enqueue_command(u,s,d,'personel',1,q,'create_order','{"x":1}')<>'conflict' then raise exception 'different payload accepted'; end if;
  begin
    perform nohut_private.enqueue_command(u,s,d,'personel',1,gen_random_uuid(),'record_payment','{}');
    raise exception 'ungranted payment accepted';
  exception when insufficient_privilege then null;
  end;
  begin
    perform nohut_private.enqueue_command(u,s,d,'personel',1,gen_random_uuid(),'create_order','{"staffId":999}');
    raise exception 'forged identity accepted';
  exception when invalid_parameter_value then null;
  end;
  update nohut_private.sessions set revoked_at=clock_timestamp() where session_id=s;
  begin
    perform nohut_private.enqueue_command(u,s,d,'personel',1,q,'create_order','{}');
    raise exception 'revoked session received cached response';
  exception when insufficient_privilege then null;
  end;
  if (select count(*) from nohut_private.commands where restaurant_id=r)<>1 then raise exception 'unexpected command persisted'; end if;
  if has_function_privilege('authenticated','nohut_private.enqueue_command(uuid,uuid,uuid,text,bigint,uuid,text,text)','EXECUTE') then raise exception 'client grant leaked'; end if;
end $$;
rollback;
