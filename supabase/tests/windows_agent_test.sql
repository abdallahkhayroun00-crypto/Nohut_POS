\set ON_ERROR_STOP on
begin;
do $$
declare r uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); u uuid:=gen_random_uuid();
  d uuid:=gen_random_uuid(); s uuid:=gen_random_uuid(); pc uuid:=gen_random_uuid(); info jsonb; info2 jsonb; token text; token2 text;
begin
  insert into nohut_private.restaurants(restaurant_id) values(r);
  insert into nohut_private.authority_epochs(restaurant_id,authority_epoch) values(r,e);
  insert into nohut_private.sync_checkpoints(restaurant_id,authority_epoch,last_acked_seq,last_acked_revision) values(r,e,10,2);
  insert into nohut_private.app_users(user_id,restaurant_id,username,pos_employee_id,role_template,is_owner)
    values(u,r,'syntheticowner',1,'Yönetici',true);
  perform nohut_private.enroll_device(u,d,s,'windows','Synthetic');
  begin
    perform nohut_private.enroll_windows_agent(u,s,d,'aal1',1,pc,e);
    raise exception 'enrollment without MFA';
  exception when insufficient_privilege then null; end;
  pc:=d;
  info:=nohut_private.enroll_windows_agent(u,s,d,'aal2',1,pc,e);
  token:=info->>'token';
  if length(token)<>64 or (nohut_private.agent_checkpoint(token)->>'last_acked_seq')::bigint<>10 then raise exception 'agent auth/checkpoint failed'; end if;
  if exists(select 1 from nohut_private.windows_agents where token_sha256=convert_to(token,'UTF8')) then raise exception 'plaintext token persisted'; end if;
  begin
    perform nohut_private.enroll_windows_agent(u,s,d,'aal2',1,gen_random_uuid(),e);
    raise exception 'replacement PC on same epoch accepted';
  exception when insufficient_privilege then null; end;
  info2:=nohut_private.enroll_windows_agent(u,s,d,'aal2',1,pc,e);
  token2:=info2->>'token';
  if token2=token then raise exception 'token did not rotate'; end if;
  begin perform nohut_private.agent_checkpoint(token); raise exception 'old token accepted'; exception when insufficient_privilege then null; end;
  if not nohut_private.revoke_windows_agent(u,s,d,'aal2',1,(info2->>'agent_id')::uuid) then raise exception 'revoke failed'; end if;
  begin perform nohut_private.agent_checkpoint(token2); raise exception 'revoked token accepted'; exception when insufficient_privilege then null; end;
  if has_function_privilege('authenticated','nohut_private.agent_checkpoint(text)','EXECUTE') or
    has_function_privilege('anon','nohut_private.agent_claim(text,integer)','EXECUTE') then raise exception 'agent grants leaked'; end if;
end $$;
rollback;
