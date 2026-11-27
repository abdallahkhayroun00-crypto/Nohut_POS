-- PR-05B: atomic incremental ingest for the first typed projection only.
-- Other entity categories fail closed, including mixed transactions.
-- Requires a provisioned checkpoint and active migration. No public RPC,
-- live data transfer, initial snapshot or credential grant in this slice.
begin;
create table nohut_private.employee_source_ids (
  restaurant_id uuid not null,
  local_id bigint not null check(local_id>0),
  employee_id uuid not null,
  local_role text,
  primary key(restaurant_id,local_id),
  unique(restaurant_id,employee_id),
  foreign key(restaurant_id,employee_id) references nohut_private.employees
);
alter table nohut_private.employee_source_ids enable row level security;
alter table nohut_private.employee_source_ids force row level security;
revoke all on nohut_private.employee_source_ids from public,anon,authenticated,service_role;

-- This is a business projection, never the authorization source.
create function nohut_private.apply_employee_projection(p_restaurant uuid,p_revision bigint,p_rows jsonb)
returns void language plpgsql security invoker set search_path=pg_catalog,nohut_private
as $$
declare row_data jsonb; local_ids bigint[]:=array[]::bigint[]; lid bigint; eid uuid;
begin
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'employees core must be an array' using errcode='22023';
  end if;
  -- An imported snapshot must have seeded the mapping; never silently
  -- create duplicates of pre-existing business identities.
  if exists(select 1 from nohut_private.employees e where e.restaurant_id=p_restaurant
    and not exists(select 1 from nohut_private.employee_source_ids m
      where m.restaurant_id=e.restaurant_id and m.employee_id=e.employee_id)) then
    raise exception 'employee mapping incomplete' using errcode='22023';
  end if;
  if exists(select 1 from nohut_private.employees e where e.restaurant_id=p_restaurant
      and e.source_revision>=p_revision) then
    raise exception 'employee revision conflict' using errcode='22023';
  end if;
  for row_data in select value from jsonb_array_elements(p_rows) loop
    if jsonb_typeof(row_data) is distinct from 'object' then
      raise exception 'invalid employee row' using errcode='22023';
    end if;
    if exists(select 1 from jsonb_object_keys(row_data) k(key) where key not in ('id','name','active','role'))
      or jsonb_typeof(row_data->'id') is distinct from 'number'
      or coalesce(row_data->>'id','') !~ '^[1-9][0-9]*$'
      or jsonb_typeof(row_data->'name') is distinct from 'string'
      or length(row_data->>'name') not between 1 and 256
      or jsonb_typeof(row_data->'active') is distinct from 'boolean'
      or (row_data ? 'role' and jsonb_typeof(row_data->'role') not in ('string','null')) then
      raise exception 'invalid employee fields' using errcode='22023';
    end if;
    lid:=(row_data->>'id')::bigint;
    if lid=any(local_ids) then raise exception 'duplicate employee id' using errcode='22023'; end if;
    local_ids:=array_append(local_ids,lid);
    select m.employee_id into eid from nohut_private.employee_source_ids m
      where m.restaurant_id=p_restaurant and m.local_id=lid;
    if not found then
      eid:=gen_random_uuid();
      insert into nohut_private.employees(restaurant_id,employee_id,display_name,active,entity_version,source_revision,updated_at)
      values(p_restaurant,eid,row_data->>'name',(row_data->>'active')::boolean,1,p_revision,clock_timestamp());
      insert into nohut_private.employee_source_ids(restaurant_id,local_id,employee_id,local_role)
      values(p_restaurant,lid,eid,row_data->>'role');
    else
      update nohut_private.employees e set display_name=row_data->>'name',active=(row_data->>'active')::boolean,
        entity_version=e.entity_version+1,source_revision=p_revision,updated_at=clock_timestamp(),deleted_at=null
      where e.restaurant_id=p_restaurant and e.employee_id=eid;
      update nohut_private.employee_source_ids m set local_role=row_data->>'role'
        where m.restaurant_id=p_restaurant and m.local_id=lid;
    end if;
  end loop;
  update nohut_private.employees e set active=false,deleted_at=clock_timestamp(),
    entity_version=e.entity_version+1,source_revision=p_revision,updated_at=clock_timestamp()
  from nohut_private.employee_source_ids m
  where e.restaurant_id=p_restaurant and m.restaurant_id=e.restaurant_id and m.employee_id=e.employee_id
    and not(m.local_id=any(local_ids)) and e.deleted_at is null;
end $$;

create function nohut_private.ingest_sync_transaction(p_restaurant uuid,p_epoch uuid,p_tx jsonb)
returns jsonb language plpgsql security invoker set search_path=pg_catalog,nohut_private
as $$
declare cp nohut_private.sync_checkpoints%rowtype; old_tx nohut_private.sync_transactions%rowtype;
  rev bigint; fst bigint; lst bigint; n integer; tid uuid; ev jsonb;
begin
  perform nohut_private.validate_sync_transaction(p_epoch,p_tx);
  -- Epoch lock fences authority rotation and serializes against retirement.
  perform 1 from nohut_private.authority_epochs a where a.restaurant_id=p_restaurant
    and a.authority_epoch=p_epoch and a.retired_at is null for share;
  if not found then raise exception 'inactive authority' using errcode='42501'; end if;
  perform 1 from nohut_private.sync_migrations m where m.restaurant_id=p_restaurant
    and m.authority_epoch=p_epoch and m.status='active' for share;
  if not found then raise exception 'migration not active' using errcode='42501'; end if;
  select * into cp from nohut_private.sync_checkpoints c where c.restaurant_id=p_restaurant
    and c.authority_epoch=p_epoch for update;
  if not found then raise exception 'checkpoint not provisioned' using errcode='42501'; end if;
  rev:=(p_tx->>'source_revision')::bigint; fst:=(p_tx->>'first_seq')::bigint;
  lst:=(p_tx->>'last_seq')::bigint; n:=(p_tx->>'event_count')::integer; tid:=(p_tx->>'tx_id')::uuid;
  select * into old_tx from nohut_private.sync_transactions t
    where t.restaurant_id=p_restaurant and t.authority_epoch=p_epoch and t.tx_id=tid;
  if found then
    if old_tx.source_revision<>rev or old_tx.first_seq<>fst or old_tx.last_seq<>lst
       or old_tx.event_count<>n or old_tx.body_sha256<>p_tx->>'body_sha256'
       or cp.last_acked_seq<lst
       or (select count(*) from nohut_private.sync_event_ids i where i.restaurant_id=p_restaurant
          and i.authority_epoch=p_epoch and i.tx_id=tid)<>n
       or exists(select 1 from jsonb_array_elements(p_tx->'events') v(ev)
         where not exists(select 1 from nohut_private.sync_event_ids i
          where i.restaurant_id=p_restaurant and i.authority_epoch=p_epoch and i.tx_id=tid
          and i.event_id=v.ev->>'event_id' and i.event_ordinal=(v.ev->>'event_ordinal')::integer
          and i.seq=(v.ev->>'seq')::bigint and i.entity_type=v.ev->>'entity_type'
          and i.entity_id=v.ev->>'entity_id' and i.op=v.ev->>'op'
          and i.body_sha256=v.ev->>'body_sha256')) then
      return jsonb_build_object('status','conflict','acked_through_seq',cp.last_acked_seq);
    end if;
    return jsonb_build_object('status','duplicate','acked_through_seq',cp.last_acked_seq);
  end if;
  if fst>cp.last_acked_seq+1 then
    return jsonb_build_object('status','gap','acked_through_seq',cp.last_acked_seq);
  end if;
  if fst<>cp.last_acked_seq+1 or rev<=cp.last_acked_revision then
    return jsonb_build_object('status','conflict','acked_through_seq',cp.last_acked_seq);
  end if;
  -- Never ACK an unsupported or partial group.
  ev:=p_tx->'events'->0;
  if n<>1 or ev->>'entity_type'<>'employees' or ev->>'entity_id'<>'core' or ev->>'op'<>'upsert' then
    raise exception 'typed projection not supported yet' using errcode='22023';
  end if;
  perform nohut_private.apply_employee_projection(p_restaurant,rev,ev->'payload');
  insert into nohut_private.sync_transactions(restaurant_id,authority_epoch,tx_id,source_revision,first_seq,last_seq,event_count,schema_version,body_sha256)
    values(p_restaurant,p_epoch,tid,rev,fst,lst,n,1,p_tx->>'body_sha256');
  insert into nohut_private.sync_event_ids(restaurant_id,authority_epoch,tx_id,event_id,event_ordinal,seq,entity_type,entity_id,op,body_sha256)
    values(p_restaurant,p_epoch,tid,ev->>'event_id',0,fst,ev->>'entity_type',ev->>'entity_id',ev->>'op',ev->>'body_sha256');
  update nohut_private.sync_checkpoints c set last_acked_seq=lst,last_acked_revision=rev,updated_at=clock_timestamp()
    where c.restaurant_id=p_restaurant and c.authority_epoch=p_epoch;
  return jsonb_build_object('status','accepted','acked_through_seq',lst);
end $$;
revoke all on function nohut_private.apply_employee_projection(uuid,bigint,jsonb) from public,anon,authenticated,service_role;
revoke all on function nohut_private.ingest_sync_transaction(uuid,uuid,jsonb) from public,anon,authenticated,service_role;
commit;
