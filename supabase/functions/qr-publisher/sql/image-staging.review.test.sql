\set ON_ERROR_STOP on
-- Disposable fixtures only. Synthetic future command envelope, not real enqueue parity.
begin;
do $$
declare
 r uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); u uuid:=gen_random_uuid();
 d uuid:=gen_random_uuid(); s uuid:=gen_random_uuid(); wd uuid:=gen_random_uuid(); ws uuid:=gen_random_uuid();
 q uuid:=gen_random_uuid(); pub uuid:=gen_random_uuid(); tx uuid:=gen_random_uuid();
 token text; envhash text; result jsonb; payload jsonb;
 pubhash text; draft text; digest text; path text; fence uuid; revision text:=repeat('c',40);
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

 -- Bind the newly staged path to a fresh, confirmed publication draft.
 path:=result->>'path';
 draft:=jsonb_build_object('categories','[]'::jsonb,'products',jsonb_build_array(jsonb_build_object('id',1,'image',path)),'campaigns','[]'::jsonb)::text;
 digest:=encode(sha256(convert_to(draft,'UTF8')),'hex'); stamp:=left(digest,16);
 update nohut_private.qr_menu_state set draft_stamp=stamp,catalog=draft::jsonb where restaurant_id=r;
 perform nohut_private.enqueue_command(u,s,d,'yonetici',1,pub,'qr_menu_publish',jsonb_build_object('confirmed',true,'expectedStamp',stamp,'draftSha256',digest)::text);
 perform public.nohut_agent_claim(token,20);
 select nohut_private.command_envelope_sha256(envelope) into strict pubhash from nohut_private.commands where restaurant_id=r and request_id=pub::text;
 result:=nohut_private.qr_publish_claim(token,pub::text,1,pubhash,digest,revision);
 if result->>'status' is distinct from 'new' then raise exception 'publication claim failed'; end if;
 fence:=(result->>'fence')::uuid;
 begin
 perform nohut_private.qr_pin_image(token,pub::text,1,pubhash,stamp,revision,draft,gen_random_uuid(),'1',path);
 raise exception 'wrong pin fence accepted';
 exception when insufficient_privilege then null; end;
 begin
 perform nohut_private.qr_pin_image(token,pub::text,1,pubhash,stamp,revision,draft,fence,'2',path);
 raise exception 'wrong pin product accepted';
 exception when insufficient_privilege then null; end;
 result:=nohut_private.qr_pin_image(token,pub::text,1,pubhash,stamp,revision,draft,fence,'1',path);
 if result->>'path' is distinct from path or decode(result->>'base64','base64') is distinct from image then raise exception 'pin bytes mismatch'; end if;
 update nohut_private.qr_staged_images set expires_at=clock_timestamp()-interval '1 second' where restaurant_id=r;
 if nohut_private.qr_cleanup_expired_images()<>0 then raise exception 'unresolved pin deleted'; end if;
 if nohut_private.qr_pin_image(token,pub::text,1,pubhash,stamp,revision,draft,fence,'1',path) is distinct from result then raise exception 'pinned retry changed'; end if;
 -- Exercise terminal state with synthetic Git evidence only; no GitHub calls.
 perform nohut_private.qr_publish_transition(token,pub::text,1,pubhash,digest,fence,'prepare',repeat('1',40),repeat('2',40),repeat('3',40),repeat('4',40));
 perform nohut_private.qr_publish_transition(token,pub::text,1,pubhash,digest,fence,'attempt');
 perform nohut_private.qr_publish_transition(token,pub::text,1,pubhash,digest,fence,'unknown');
 if nohut_private.qr_cleanup_expired_images()<>0 then raise exception 'unknown outcome bytes deleted'; end if;
 -- A fixture-only terminal transition; trusted server proof is required in production.
 update nohut_private.qr_publish_receipts set state='completed',result=jsonb_build_object('requestId',pub::text,'status','committed','commit',repeat('2',40),'revision',repeat('4',40),'pages','unverified') where restaurant_id=r and request_id=pub::text;
 if nohut_private.qr_cleanup_expired_images()<>1 then raise exception 'terminal expired bytes not cleaned'; end if;
 if (select count(*) from nohut_private.qr_image_pins where restaurant_id=r and publish_request_id=pub::text)<>1 then raise exception 'pin audit lost'; end if;
 if has_function_privilege('nohut_qr_runtime','nohut_private.qr_pin_image(text,text,bigint,text,text,text,text,uuid,text,text)','EXECUTE') or has_function_privilege('service_role','nohut_private.qr_cleanup_expired_images()','EXECUTE') then raise exception 'private pin or cleanup exposed'; end if;
 if has_table_privilege('authenticated','nohut_private.qr_staged_images','SELECT') or has_table_privilege('nohut_qr_runtime','nohut_private.qr_staged_images','SELECT') or has_function_privilege('service_role','nohut_private.qr_stage_normalized_image(text,text,bigint,text,text,text,bytea)','EXECUTE') then raise exception 'image staging exposed'; end if;
end $$;
rollback;
