\set ON_ERROR_STOP on
-- Review harness. Apply receipt-storage.review.sql ONLY to a disposable
-- database with #39/#46 migrations already installed; never production.
begin;
do $$
declare
 r uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); u uuid:=gen_random_uuid();
 d uuid:=gen_random_uuid(); s uuid:=gen_random_uuid(); wd uuid:=gen_random_uuid(); ws uuid:=gen_random_uuid();
 q uuid:=gen_random_uuid(); q2 uuid:=gen_random_uuid(); q3 uuid:=gen_random_uuid();
 token text; envhash text; envhash2 text; recovery_hash text; fence uuid; result jsonb;
 digest text:=repeat('a',64); revision text:=repeat('b',40);
 parent text:=repeat('c',40); gitcommit text:=repeat('d',40);
 tree text:=repeat('e',40); newrev text:=repeat('f',40);
begin
 insert into nohut_private.restaurants(restaurant_id) values(r);
 insert into nohut_private.authority_epochs(restaurant_id,authority_epoch) values(r,e);
 insert into nohut_private.sync_checkpoints(restaurant_id,authority_epoch) values(r,e);
 insert into nohut_private.sync_migrations(restaurant_id,migration_id,authority_epoch,snapshot_revision,snapshot_seq,schema_version,manifest_sha256,status)
 values(r,gen_random_uuid(),e,0,0,1,repeat('a',64),'active');
 insert into nohut_private.app_users(user_id,restaurant_id,username,pos_employee_id,role_template,is_owner)
 values(u,r,'syntheticqrreceiptowner',1,'Yönetici',true);
 perform nohut_private.enroll_device(u,d,s,'yonetici','Synthetic');
 perform nohut_private.enroll_device(u,wd,ws,'windows','Synthetic Windows');
 token:=nohut_private.enroll_windows_agent(u,ws,wd,'aal2',1,wd,e)->>'token';
 perform nohut_private.enqueue_command(u,s,d,'yonetici',1,q,'qr_menu_publish','{"confirmed":true,"expectedStamp":"0123456789abcdef"}');
 perform nohut_private.enqueue_command(u,s,d,'yonetici',1,q2,'qr_menu_publish','{"confirmed":true,"expectedStamp":"0123456789abcdef"}');
 perform public.nohut_agent_claim(token,20);
 select nohut_private.command_envelope_sha256(envelope) into strict envhash from nohut_private.commands where restaurant_id=r and request_id=q::text;
 select nohut_private.command_envelope_sha256(envelope) into strict envhash2 from nohut_private.commands where restaurant_id=r and request_id=q2::text;
 if has_table_privilege('anon','nohut_private.qr_publish_receipts','SELECT') or
 has_table_privilege('authenticated','nohut_private.qr_publish_receipts','INSERT') or
 has_table_privilege('service_role','nohut_private.qr_publish_receipts','UPDATE') then raise exception 'direct grants leaked'; end if;
 if has_function_privilege('anon','nohut_private.qr_publish_claim(text,text,bigint,text,text,text)','EXECUTE')
 or has_function_privilege('authenticated','nohut_private.qr_publish_transition(text,text,bigint,text,text,uuid,text,text,text,text,text)','EXECUTE')
 or has_function_privilege('service_role','nohut_private.qr_publish_claim(text,text,bigint,text,text,text)','EXECUTE') then raise exception 'private RPC exposed'; end if;
 result:=nohut_private.qr_publish_claim(token,q::text,1,envhash,digest,revision);
 if result->>'status' is distinct from 'new' then raise exception 'initial claim failed'; end if;
 fence:=(result->>'fence')::uuid;
 if (nohut_private.qr_publish_claim(token,q::text,1,envhash,digest,revision)->>'status') is distinct from 'busy' then raise exception 'duplicate new claim allowed'; end if;
 if (nohut_private.qr_publish_claim(token,q::text,1,envhash,repeat('1',64),revision)->>'status') is distinct from 'conflict' then raise exception 'changed digest accepted'; end if;
 if (nohut_private.qr_publish_claim(token,q2::text,1,envhash2,digest,revision)->>'status') is distinct from 'busy' then raise exception 'second publication allowed'; end if;
 begin
  perform nohut_private.qr_publish_transition(token,q::text,1,envhash,digest,fence,'attempt');
  raise exception 'attempt without preparation accepted';
 exception when invalid_parameter_value then null; end;
 begin
  perform nohut_private.qr_publish_transition(token,q::text,1,envhash,digest,gen_random_uuid(),'prepare',parent,gitcommit,tree,newrev);
  raise exception 'wrong fence accepted';
 exception when insufficient_privilege then null; end;
 perform nohut_private.qr_publish_transition(token,q::text,1,envhash,digest,fence,'prepare',parent,gitcommit,tree,newrev);
 result:=nohut_private.qr_publish_transition(token,q::text,1,envhash,digest,fence,'attempt');
 if result->>'commit' is distinct from gitcommit then raise exception 'prepared receipt changed'; end if;
 begin
  perform nohut_private.qr_publish_transition(token,q::text,1,envhash,digest,fence,'attempt');
  raise exception 'second attempt accepted';
 exception when invalid_parameter_value then null; end;
 begin
  perform nohut_private.qr_publish_transition(token,q::text,2,envhash,digest,fence,'committed',null,gitcommit,null,newrev);
  raise exception 'stale generation accepted';
 exception when insufficient_privilege then null; end;
 perform nohut_private.qr_publish_transition(token,q::text,1,envhash,digest,fence,'unknown');
 if (nohut_private.qr_publish_claim(token,q::text,1,envhash,digest,revision)->>'status') is distinct from 'unknown' then raise exception 'unknown receipt lost'; end if;
 if (nohut_private.qr_publish_claim(token,q2::text,1,envhash2,digest,revision)->>'status') is distinct from 'busy' then raise exception 'unresolved lock released'; end if;
 perform nohut_private.enqueue_command(u,s,d,'yonetici',1,q3,'qr_menu_reconcile','{}');
 perform public.nohut_agent_claim(token,20);
 select nohut_private.command_envelope_sha256(envelope) into strict recovery_hash from nohut_private.commands where restaurant_id=r and request_id=q3::text;
 update nohut_private.commands set lease_until=clock_timestamp()-interval '1 second' where restaurant_id=r and request_id=q::text;
 result:=nohut_private.qr_publish_recover(token,q3::text,1,recovery_hash,q::text,'inspect');
 if result->'prepared'->>'commit' is distinct from gitcommit then raise exception 'missing recovery evidence'; end if;
 begin
  perform nohut_private.qr_publish_recover(token,q3::text,1,recovery_hash,q::text,'cancel_before_attempt');
  raise exception 'ambiguous operation cancelled';
 exception when invalid_parameter_value then null; end;
 begin
  perform nohut_private.qr_publish_recover(token,q3::text,1,recovery_hash,q::text,'confirm_reachable',parent,newrev);
  raise exception 'wrong commit evidence accepted';
 exception when invalid_parameter_value then null; end;
 result:=nohut_private.qr_publish_recover(token,q3::text,1,recovery_hash,q::text,'confirm_reachable',gitcommit,newrev);
 if result->>'status' is distinct from 'committed' then raise exception 'recovery failed'; end if;
 if nohut_private.qr_publish_recover(token,q3::text,1,recovery_hash,q::text,'inspect')->'result'->>'status' is distinct from 'committed' then raise exception 'recovered receipt not durable'; end if;
 result:=nohut_private.qr_publish_claim(token,q2::text,1,envhash2,digest,revision);
 if result->>'status' is distinct from 'new' then raise exception 'confirmed recovery did not release lock'; end if;
 fence:=(result->>'fence')::uuid;
 perform nohut_private.qr_publish_transition(token,q2::text,1,envhash2,digest,fence,'prepare',parent,gitcommit,tree,newrev);
 if nohut_private.qr_publish_recover(token,q3::text,1,recovery_hash,q2::text,'cancel_before_attempt')->>'status' is distinct from 'busy' then raise exception 'active claim cancelled'; end if;
 update nohut_private.commands set lease_until=clock_timestamp()-interval '1 second' where restaurant_id=r and request_id=q2::text;
 if nohut_private.qr_publish_recover(token,q3::text,1,recovery_hash,q2::text,'cancel_before_attempt')->>'status' is distinct from 'cancelled_before_attempt' then raise exception 'abandoned claim not released'; end if;
 if has_function_privilege('anon','nohut_private.qr_publish_recover(text,text,bigint,text,text,text,text,text)','EXECUTE') or
 has_function_privilege('service_role','nohut_private.qr_publish_recover(text,text,bigint,text,text,text,text,text)','EXECUTE') then raise exception 'recovery exposed'; end if;
 update nohut_private.sessions set revoked_at=clock_timestamp() where session_id=s;
 begin
  perform nohut_private.qr_publish_recover(token,q3::text,1,recovery_hash,q::text,'inspect');
  raise exception 'revoked actor accepted';
 exception when insufficient_privilege then null; end;
end $$;
rollback;
-- Follow-up: two independent sessions with competing tenants and requests,
-- migration owner NOSUPERUSER/NOBYPASSRLS, successful committed/no_change
-- paths, crash/rollback and reconciliation after lease expiry must be tested
-- before this draft can be promoted to a numbered migration.
