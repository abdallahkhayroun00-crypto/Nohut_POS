\set ON_ERROR_STOP on
begin;
do $$
declare
 r uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); u uuid:=gen_random_uuid();
 d uuid:=gen_random_uuid(); s uuid:=gen_random_uuid(); wd uuid:=gen_random_uuid(); ws uuid:=gen_random_uuid();
 q uuid:=gen_random_uuid(); tx uuid:=gen_random_uuid();
 token text; envhash text; fence uuid; result jsonb;
 draft_json text:='{"categories":[],"products":[],"campaigns":[]}';
 digest text; stamp text; revision text:=repeat('b',40);
begin
 insert into nohut_private.restaurants(restaurant_id) values(r);
 insert into nohut_private.authority_epochs(restaurant_id,authority_epoch) values(r,e);
 insert into nohut_private.sync_checkpoints(restaurant_id,authority_epoch) values(r,e);
 insert into nohut_private.sync_migrations(restaurant_id,migration_id,authority_epoch,snapshot_revision,snapshot_seq,schema_version,manifest_sha256,status)
 values(r,gen_random_uuid(),e,0,0,1,repeat('a',64),'active');
 insert into nohut_private.app_users(user_id,restaurant_id,username,pos_employee_id,role_template,is_owner)
 values(u,r,'syntheticqrruntimeowner',1,'Yönetici',true);
 perform nohut_private.enroll_device(u,d,s,'yonetici','Synthetic');
 perform nohut_private.enroll_device(u,wd,ws,'windows','Synthetic Windows');
 token:=nohut_private.enroll_windows_agent(u,ws,wd,'aal2',1,wd,e)->>'token';
 digest:=encode(sha256(convert_to(draft_json,'UTF8')),'hex'); stamp:=left(digest,16);
 perform nohut_private.enqueue_command(u,s,d,'yonetici',1,q,'qr_menu_publish',jsonb_build_object('confirmed',true,'expectedStamp',stamp,'draftSha256',digest)::text);
 perform nohut_private.apply_qr_menu_projection(r,1,jsonb_build_object('available',true,'stamp',stamp,'revision',revision,'offline',false,'catalog',draft_json::jsonb));
 insert into nohut_private.sync_transactions(restaurant_id,authority_epoch,tx_id,source_revision,first_seq,last_seq,event_count,schema_version,body_sha256)
 values(r,e,tx,1,1,1,1,1,repeat('a',64));
 insert into nohut_private.sync_event_ids(restaurant_id,authority_epoch,tx_id,event_id,event_ordinal,seq,entity_type,entity_id,op,body_sha256)
 values(r,e,tx,gen_random_uuid()::text,1,1,'qrMenuState','core','upsert',repeat('b',64));
 perform public.nohut_agent_claim(token,20);
 select nohut_private.command_envelope_sha256(envelope) into strict envhash from nohut_private.commands where restaurant_id=r and request_id=q::text;
 if has_schema_privilege('nohut_qr_runtime','nohut_private','USAGE') then raise exception 'private schema exposed'; end if;
 if has_table_privilege('nohut_qr_runtime','nohut_private.qr_publish_receipts','SELECT') or
    has_table_privilege('nohut_qr_runtime','nohut_private.app_users','SELECT') or
    has_table_privilege('nohut_qr_runtime','nohut_private.commands','UPDATE') then raise exception 'runtime direct table access'; end if;
 if has_schema_privilege('anon','nohut_qr_edge','USAGE') or
    has_schema_privilege('authenticated','nohut_qr_edge','USAGE') or
    has_schema_privilege('service_role','nohut_qr_edge','USAGE') then raise exception 'client schema exposure'; end if;
 if has_function_privilege('service_role','nohut_qr_edge.qr_publish_claim(text,text,bigint,text,text,text,text,text)','EXECUTE') then raise exception 'privileged API key can call runtime wrapper'; end if;
 set local role nohut_qr_runtime;
 result:=nohut_qr_edge.qr_publish_bind_draft(token,q::text,1,envhash,stamp,revision,draft_json);
 if result->>'digest' is distinct from digest then raise exception 'scoped binding failed'; end if;
 begin
  perform nohut_qr_edge.qr_publish_claim(token,q::text,1,envhash,repeat('0',64),revision,stamp,draft_json);
  raise exception 'forged digest accepted';
 exception when insufficient_privilege then null; end;
 result:=nohut_qr_edge.qr_publish_claim(token,q::text,1,envhash,digest,revision,stamp,draft_json);
 if result->>'status' is distinct from 'new' then raise exception 'scoped claim failed'; end if;
 fence:=(result->>'fence')::uuid;
 begin
  perform nohut_qr_edge.qr_publish_transition(token,q::text,1,envhash,digest,fence,'no_change',null,null,null,revision,stamp,revision,draft_json||' ');
  raise exception 'modified raw draft accepted on transition';
 exception when insufficient_privilege then null; end;
 result:=nohut_qr_edge.qr_publish_transition(token,q::text,1,envhash,digest,fence,'no_change',null,null,null,revision,stamp,revision,draft_json);
 if result->>'status' is distinct from 'no_change' then raise exception 'scoped transition failed'; end if;
 reset role;
 if (select state from nohut_private.qr_publish_receipts where restaurant_id=r and request_id=q::text) is distinct from 'completed' then raise exception 'terminal receipt lost'; end if;
end $$;
rollback;
