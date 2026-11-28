-- Disposable CI fixtures only; never run against restaurant DB.
create schema qr_concurrency_test;
revoke all on schema qr_concurrency_test from public;
create table qr_concurrency_test.fixture(
 label text primary key, restaurant uuid, request_id text, token text,
 envelope_hash text, digest text, stamp text, revision text, draft_json text,
 reconcile_id text, reconcile_hash text
);
do $$
declare
 r uuid; e uuid; u uuid; d uuid; s uuid; wd uuid; ws uuid; q uuid; rec uuid; tx uuid;
 token text; envhash text; rhash text;
 draft_json text:='{"categories":[],"products":[],"campaigns":[]}';
 digest text; stamp text; revision text:=repeat('b',40); label text;
begin
 digest:=encode(sha256(convert_to(draft_json,'UTF8')),'hex'); stamp:=left(digest,16);
 foreach label in array array['A','B'] loop
  r:=gen_random_uuid(); e:=gen_random_uuid(); u:=gen_random_uuid();
  d:=gen_random_uuid(); s:=gen_random_uuid(); wd:=gen_random_uuid(); ws:=gen_random_uuid();
  q:=gen_random_uuid(); rec:=gen_random_uuid(); tx:=gen_random_uuid();
  insert into nohut_private.restaurants(restaurant_id) values(r);
  insert into nohut_private.authority_epochs(restaurant_id,authority_epoch) values(r,e);
  insert into nohut_private.sync_checkpoints(restaurant_id,authority_epoch) values(r,e);
  insert into nohut_private.sync_migrations(restaurant_id,migration_id,authority_epoch,snapshot_revision,snapshot_seq,schema_version,manifest_sha256,status)
  values(r,gen_random_uuid(),e,0,0,1,repeat('a',64),'active');
  insert into nohut_private.app_users(user_id,restaurant_id,username,pos_employee_id,role_template,is_owner)
  values(u,r,'qrconcurrency'||lower(label),1,'Yönetici',true);
  perform nohut_private.enroll_device(u,d,s,'yonetici','Synthetic');
  perform nohut_private.enroll_device(u,wd,ws,'windows','Synthetic Windows');
  token:=nohut_private.enroll_windows_agent(u,ws,wd,'aal2',1,wd,e)->>'token';
  perform nohut_private.enqueue_command(u,s,d,'yonetici',1,q,'qr_menu_publish',jsonb_build_object('confirmed',true,'expectedStamp',stamp,'draftSha256',digest)::text);
  perform nohut_private.enqueue_command(u,s,d,'yonetici',1,rec,'qr_menu_reconcile',jsonb_build_object('targetRequestId',q::text,'mode','reconcile')::text);
  perform nohut_private.apply_qr_menu_projection(r,1,jsonb_build_object('available',true,'stamp',stamp,'revision',revision,'offline',false,'catalog',draft_json::jsonb));
  insert into nohut_private.sync_transactions(restaurant_id,authority_epoch,tx_id,source_revision,first_seq,last_seq,event_count,schema_version,body_sha256)
  values(r,e,tx,1,1,1,1,1,repeat('a',64));
  insert into nohut_private.sync_event_ids(restaurant_id,authority_epoch,tx_id,event_id,event_ordinal,seq,entity_type,entity_id,op,body_sha256)
  values(r,e,tx,gen_random_uuid()::text,1,1,'qrMenuState','core','upsert',repeat('b',64));
  perform public.nohut_agent_claim(token,20);
  select nohut_private.command_envelope_sha256(envelope) into strict envhash from nohut_private.commands where restaurant_id=r and request_id=q::text;
  select nohut_private.command_envelope_sha256(envelope) into strict rhash from nohut_private.commands where restaurant_id=r and request_id=rec::text;
  insert into qr_concurrency_test.fixture values(label,r,q::text,token,envhash,digest,stamp,revision,draft_json,rec::text,rhash);
 end loop;
end $$;
-- Synthetic future recovery command scope. Tenant B is deliberately given
-- an envelope targeting A's ID to verify the separate tenant boundary.
with payloads as (
 select f.restaurant,f.reconcile_id,jsonb_build_object('targetRequestId',a.request_id,'mode','reconcile') as payload
 from qr_concurrency_test.fixture f cross join qr_concurrency_test.fixture a where a.label='A'
)
update nohut_private.commands c set envelope=c.envelope||jsonb_build_object('payload',p.payload,'payload_sha256',
 encode(sha256(convert_to(nohut_private.canonical_command_json(p.payload),'UTF8')),'hex'))
 from payloads p where c.restaurant_id=p.restaurant and c.request_id=p.reconcile_id;
update qr_concurrency_test.fixture f set reconcile_hash=nohut_private.command_envelope_sha256(c.envelope)
 from nohut_private.commands c where c.restaurant_id=f.restaurant and c.request_id=f.reconcile_id;
create function qr_concurrency_test.claim(p_label text) returns text language sql set search_path=''
as $$ select nohut_qr_edge.qr_publish_claim(token,request_id,1,envelope_hash,digest,revision,stamp,draft_json)->>'status' from qr_concurrency_test.fixture where label=p_label $$;
