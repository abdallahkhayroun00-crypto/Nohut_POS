\set ON_ERROR_STOP on
begin;
do $$
declare r uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); u uuid:=gen_random_uuid();
  d uuid:=gen_random_uuid(); s uuid:=gen_random_uuid(); q1 uuid:=gen_random_uuid(); q2 uuid:=gen_random_uuid();
  claimed record;
begin
  insert into nohut_private.restaurants(restaurant_id) values(r);
  insert into nohut_private.authority_epochs(restaurant_id,authority_epoch) values(r,e);
  insert into nohut_private.sync_migrations(restaurant_id,migration_id,authority_epoch,snapshot_revision,snapshot_seq,schema_version,manifest_sha256,status)
    values(r,gen_random_uuid(),e,0,0,1,repeat('a',64),'active');
  insert into nohut_private.app_users(user_id,restaurant_id,username,pos_employee_id,role_template)
    values(u,r,'synthetic',1,'Personel');
  insert into nohut_private.user_grants(user_id,operation_id) values(u,'orders.create');
  perform nohut_private.enroll_device(u,d,s,'personel','Synthetic');
  if nohut_private.enqueue_command(u,s,d,'personel',1,q1,'create_order','{}')<>'accepted' then raise exception 'enqueue 1'; end if;
  select * into strict claimed from nohut_private.claim_authorized_commands(r,e,1);
  if claimed.envelope->>'request_id'<>q1::text or claimed.lease_generation<>1 then raise exception 'claim failed'; end if;
  if nohut_private.enqueue_command(u,s,d,'personel',1,q2,'create_order','{}')<>'accepted' then raise exception 'enqueue 2'; end if;
  update nohut_private.commands set lease_until=clock_timestamp()-interval '1 second' where restaurant_id=r and request_id=q1::text;
  update nohut_private.sessions set revoked_at=clock_timestamp() where session_id=s;
  if exists(select 1 from nohut_private.claim_authorized_commands(r,e,20)) then raise exception 'revoked command dispatched'; end if;
  if (select state from nohut_private.commands where restaurant_id=r and request_id=q1::text)<>'reconciliation_required' then raise exception 'uncertain operation incorrectly rejected'; end if;
  if (select state from nohut_private.commands where restaurant_id=r and request_id=q2::text)<>'rejected' then raise exception 'pending revoked operation not rejected'; end if;
  if has_function_privilege('authenticated','nohut_private.claim_authorized_commands(uuid,uuid,integer)','EXECUTE') then raise exception 'client grant leaked'; end if;
end $$;
rollback;
