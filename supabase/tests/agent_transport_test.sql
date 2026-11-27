\set ON_ERROR_STOP on
begin;
do $$
declare r uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); u uuid:=gen_random_uuid();
  d uuid:=gen_random_uuid(); s uuid:=gen_random_uuid(); wd uuid:=gen_random_uuid(); ws uuid:=gen_random_uuid(); q uuid:=gen_random_uuid(); info jsonb;
  token text; claimed jsonb; fingerprint text; status text;
  receipt jsonb:='{"state":"confirmed","code":"ok","ok":true,"revision":1}'::jsonb;
begin
  insert into nohut_private.restaurants(restaurant_id) values(r);
  insert into nohut_private.authority_epochs(restaurant_id,authority_epoch) values(r,e);
  insert into nohut_private.sync_checkpoints(restaurant_id,authority_epoch) values(r,e);
  insert into nohut_private.sync_migrations(restaurant_id,migration_id,authority_epoch,snapshot_revision,snapshot_seq,schema_version,manifest_sha256,status)
    values(r,gen_random_uuid(),e,0,0,1,repeat('a',64),'active');
  insert into nohut_private.app_users(user_id,restaurant_id,username,pos_employee_id,role_template,is_owner)
    values(u,r,'synthetictransportowner',1,'Yönetici',true);
  perform nohut_private.enroll_device(u,d,s,'yonetici','Synthetic');
  perform nohut_private.enroll_device(u,wd,ws,'windows','Synthetic Windows');
  info:=nohut_private.enroll_windows_agent(u,ws,wd,'aal2',1,wd,e);
  token:=info->>'token';
  perform nohut_private.enqueue_command(u,s,d,'yonetici',1,q,'create_order','{}');
  set local role anon;
  claimed:=public.nohut_agent_claim(token,20);
  if jsonb_array_length(claimed->'claims')<>1 or claimed->>'restaurant_id'<>r::text then raise exception 'scoped claim failed'; end if;
  begin perform public.nohut_agent_checkpoint(repeat('0',64)); raise exception 'invalid token allowed';
    exception when insufficient_privilege then null; end;
  begin perform 1 from nohut_private.commands; raise exception 'anon read private queue';
    exception when insufficient_privilege then null; end;
  reset role;
  fingerprint:=nohut_private.command_envelope_sha256(claimed->'claims'->0->'envelope');
  set local role anon;
  if not public.nohut_agent_validate_claim(token,q::text,1,fingerprint) then raise exception 'valid claim refused'; end if;
  if public.nohut_agent_validate_claim(token,q::text,2,fingerprint) then raise exception 'wrong generation accepted'; end if;
  reset role;
  update nohut_private.sessions set revoked_at=clock_timestamp() where session_id=s;
  set local role anon;
  if public.nohut_agent_validate_claim(token,q::text,1,fingerprint) then raise exception 'revoked user dispatched'; end if;
  reset role;
  update nohut_private.commands set lease_until=clock_timestamp()-interval '1 second' where restaurant_id=r and request_id=q::text;
  set local role anon;
  status:=public.nohut_agent_complete(token,q::text,1,fingerprint,receipt);
  if status<>'stale_claim' then raise exception 'expired lease completion accepted'; end if;
  -- A real local commit can still be reported without executing it again.
  if public.nohut_agent_report_receipt(token,q::text,repeat('0',64),receipt)<>'conflict' then raise exception 'wrong fingerprint accepted'; end if;
  if public.nohut_agent_report_receipt(token,q::text,fingerprint,receipt)<>'accepted' then raise exception 'receipt recovery failed'; end if;
  if public.nohut_agent_report_receipt(token,q::text,fingerprint,receipt)<>'duplicate' then raise exception 'lost report ACK failed'; end if;
  if public.nohut_agent_report_receipt(token,q::text,fingerprint,'{"state":"rejected"}')<>'conflict' then raise exception 'confirmed result overwritten'; end if;
  reset role;
  if (select state from nohut_private.commands where restaurant_id=r and request_id=q::text)<>'confirmed' then raise exception 'commit outcome lost'; end if;
  if has_function_privilege('service_role','public.nohut_agent_claim(text,integer)','EXECUTE') then raise exception 'unneeded service grant'; end if;
end $$;
rollback;
