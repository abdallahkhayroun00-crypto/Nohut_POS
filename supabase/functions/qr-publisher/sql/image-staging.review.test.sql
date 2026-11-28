\set ON_ERROR_STOP on
-- Disposable fixtures only. Synthetic future command envelope, not real enqueue parity.
begin;
do $$
declare
 r uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); u uuid:=gen_random_uuid();
 d uuid:=gen_random_uuid(); s uuid:=gen_random_uuid(); wd uuid:=gen_random_uuid(); ws uuid:=gen_random_uuid();
 q uuid:=gen_random_uuid(); tx uuid:=gen_random_uuid();
 token text; envhash text; result jsonb; payload jsonb;
 stamp text:=repeat('a',16); source_hash text:=repeat('b',64);
 image bytea:=decode('89504e470d0a1a0a00000000','hex');
begin
 insert into nohut_private.restaurants(restaurant_id) values(r);
 insert into nohut_private.authority_epochs(restaurant_id,authority_epoch) values(r,e);
 insert into nohut_private.sync_checkpoints(restaurant_id,authority_epoch) values(r,e);
 insert into nohut_private.sync_migrations(restaurant_id,migration_id,authority_epoch,snapshot_revision,snapshot_seq,schema_version,manifest_sha256,status)
 values(r,gen_random_uuid(),e,0,0,1,repeat('a',64),'active');
 insert into nohut_private.app_users(user_id,restaurant_id,username,pos_employee_id,role_template,is_owner)
 values(u,r,'syntheticqrimageowner',1,'Yönetici',true);
 perform nohut_private.enroll_device(u,d,s,'yonetici','Synthetic');
 perform nohut_private.enroll_device(u,wd,ws,'windows','Synthetic Windows');
 token:=nohut_private.enroll_windows_agent(u,ws,wd,'aal2',1,wd,e)->>'token';
 payload:=jsonb_build_object('expectedStamp',stamp,'id','1','mime','image/png','storagePath','qr-uploads/synthetic.png','target','product');
 perform nohut_private.enqueue_command(u,s,d,'yonetici',1,q,'qr_menu_image',payload::text);
 -- This fixture directly installs the projected row, not a tested serializer.
 insert into nohut_private.qr_menu_state(restaurant_id,available,draft_stamp,revision,offline,catalog,source_revision,calculated_at)
 values(r,true,stamp,repeat('c',40),false,'{"categories":[],"products":[{"id":1}],"campaigns":[]}',1,clock_timestamp());
 insert into nohut_private.sync_transactions(restaurant_id,authority_epoch,tx_id,source_revision,first_seq,last_seq,event_count,schema_version,body_sha256)
 values(r,e,tx,1,1,1,1,1,repeat('a',64));
 insert into nohut_private.sync_event_ids(restaurant_id,authority_epoch,tx_id,event_id,event_ordinal,seq,entity_type,entity_id,op,body_sha256)
 values(r,e,tx,gen_random_uuid()::text,1,1,'qrMenuState','core','upsert',repeat('b',64));
 perform public.nohut_agent_claim(token,20);
 select nohut_private.command_envelope_sha256(envelope) into strict envhash from nohut_private.commands where restaurant_id=r and request_id=q::text;
 begin
 perform nohut_private.qr_stage_normalized_image(token,q::text,1,envhash,source_hash,'image/png',image);
 raise exception 'legacy source accepted';
 exception when insufficient_privilege then null; end;
 payload:=payload||jsonb_build_object('sourceSha256',source_hash);
 update nohut_private.commands set envelope=envelope||jsonb_build_object('payload',payload,'payload_sha256',encode(sha256(convert_to(nohut_private.canonical_command_json(payload),'UTF8')),'hex')) where restaurant_id=r and request_id=q::text;
 select nohut_private.command_envelope_sha256(envelope) into strict envhash from nohut_private.commands where restaurant_id=r and request_id=q::text;
 begin
 perform nohut_private.qr_stage_normalized_image(token,q::text,1,envhash,repeat('f',64),'image/png',image);
 raise exception 'wrong source accepted';
 exception when insufficient_privilege then null; end;
 begin
 perform nohut_private.qr_stage_normalized_image(token,q::text,1,envhash,source_hash,'image/png',decode(repeat('00',12),'hex'));
 raise exception 'wrong signature accepted';
 exception when invalid_parameter_value then null; end;
 result:=nohut_private.qr_stage_normalized_image(token,q::text,1,envhash,source_hash,'image/png',image);
 if result->>'status' is distinct from 'staged' or result->>'sha256' is distinct from encode(sha256(image),'hex') or result ? 'image_bytes' then raise exception 'stage failed'; end if;
 if nohut_private.qr_stage_normalized_image(token,q::text,1,envhash,source_hash,'image/png',image) is distinct from result then raise exception 'duplicate result changed'; end if;
 if nohut_private.qr_stage_normalized_image(token,q::text,1,envhash,source_hash,'image/png',image||decode('01','hex'))->>'status' is distinct from 'conflict' then raise exception 'changed bytes accepted'; end if;
 update nohut_private.qr_menu_state set draft_stamp=repeat('d',16) where restaurant_id=r;
 begin
 perform nohut_private.qr_stage_normalized_image(token,q::text,1,envhash,source_hash,'image/png',image);
 raise exception 'stale draft accepted';
 exception when insufficient_privilege then null; end;
 if has_table_privilege('authenticated','nohut_private.qr_staged_images','SELECT') or has_table_privilege('nohut_qr_runtime','nohut_private.qr_staged_images','SELECT') or has_function_privilege('service_role','nohut_private.qr_stage_normalized_image(text,text,bigint,text,text,text,bytea)','EXECUTE') then raise exception 'image staging exposed'; end if;
end $$;
rollback;
