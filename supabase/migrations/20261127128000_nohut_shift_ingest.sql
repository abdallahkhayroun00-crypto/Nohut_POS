-- PR-05B: typed shifts and append-only correction history.
-- Entire core list is a Windows-authored snapshot, not a mobile write API.
begin;
create table nohut_private.shifts (
  restaurant_id uuid not null references nohut_private.restaurants,
  shift_id text not null check(length(shift_id) between 1 and 160),
  employee_id uuid not null,
  employee_label text not null,
  started_at timestamptz not null,
  ended_at timestamptz,
  source text not null check(source in ('pos','remote')),
  source_revision bigint not null,
  primary key(restaurant_id,shift_id),
  foreign key(restaurant_id,employee_id) references nohut_private.employees,
  check(ended_at is null or ended_at>=started_at)
);
create table nohut_private.shift_corrections (
  restaurant_id uuid not null,
  shift_id text not null,
  ordinal integer not null check(ordinal>=0),
  corrected_at timestamptz not null,
  corrected_by uuid not null,
  actor_label text not null,
  before_start timestamptz not null,
  before_end timestamptz,
  after_start timestamptz not null,
  after_end timestamptz,
  reason text not null check(length(trim(reason)) between 1 and 300),
  primary key(restaurant_id,shift_id,ordinal),
  foreign key(restaurant_id,shift_id) references nohut_private.shifts,
  foreign key(restaurant_id,corrected_by) references nohut_private.employees,
  check(before_end is null or before_end>=before_start),
  check(after_end is null or after_end>=after_start)
);
do $$ declare t text; begin
  foreach t in array array['shifts','shift_corrections'] loop
    execute format('alter table nohut_private.%I enable row level security',t);
    execute format('alter table nohut_private.%I force row level security',t);
    execute format('create policy cloud_rpc_owner on nohut_private.%I for all to %I using (true) with check (true)',t,current_user);
    execute format('revoke all on nohut_private.%I from public,anon,authenticated,service_role',t);
  end loop;
end $$;

create function nohut_private.shift_timestamp(v jsonb) returns timestamptz
language plpgsql immutable set search_path=pg_catalog as $$
begin
  if v is null or v='null'::jsonb then return null; end if;
  if jsonb_typeof(v)<>'string' or (v#>>'{}') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?Z$' then
    raise exception 'shift timestamp must be UTC' using errcode='22023';
  end if;
  return (v#>>'{}')::timestamptz;
end $$;

create function nohut_private.apply_shift_projection(p_restaurant uuid,p_revision bigint,p_rows jsonb)
returns void language plpgsql security invoker set search_path=pg_catalog,nohut_private
as $$
declare row_data jsonb; correction jsonb; sid text; seen text[]:=array[]::text[];
  eid uuid; aid uuid; st timestamptz; en timestamptz; bs timestamptz; be timestamptz;
  ast timestamptz; ae timestamptz; ca timestamptz; idx integer; old_count integer;
  old_shift nohut_private.shifts%rowtype; old_c nohut_private.shift_corrections%rowtype;
begin
  if jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'shifts must be array' using errcode='22023'; end if;
  for row_data in select value from jsonb_array_elements(p_rows) loop
    if jsonb_typeof(row_data) is distinct from 'object' then raise exception 'invalid shift' using errcode='22023'; end if;
    if exists(select 1 from jsonb_object_keys(row_data) k(key) where key not in ('id','employeeId','employeeName','start','end','source','corrections'))
      or jsonb_typeof(row_data->'id') is distinct from 'string'
      or coalesce(length(row_data->>'id'),0) not between 1 and 160
      or jsonb_typeof(row_data->'employeeId') is distinct from 'number'
      or coalesce(row_data->>'employeeId','') !~ '^[1-9][0-9]*$'
      or jsonb_typeof(row_data->'employeeName') is distinct from 'string'
      or coalesce(length(row_data->>'employeeName'),0) not between 1 and 256
      or coalesce(row_data->>'source','') not in ('pos','remote')
      or jsonb_typeof(row_data->'corrections') is distinct from 'array' then
      raise exception 'invalid shift fields' using errcode='22023';
    end if;
    sid:=row_data->>'id';
    if sid=any(seen) then raise exception 'duplicate shift' using errcode='22023'; end if;
    seen:=array_append(seen,sid);
    select employee_id into eid from nohut_private.employee_source_ids where restaurant_id=p_restaurant and local_id=(row_data->>'employeeId')::bigint;
    if not found then raise exception 'unknown shift employee' using errcode='22023'; end if;
    st:=nohut_private.shift_timestamp(row_data->'start'); en:=nohut_private.shift_timestamp(row_data->'end');
    if st is null or (en is not null and en<st) then raise exception 'invalid shift interval' using errcode='22023'; end if;
    select * into old_shift from nohut_private.shifts where restaurant_id=p_restaurant and shift_id=sid;
    if found and (old_shift.employee_id<>eid or old_shift.source<>row_data->>'source' or old_shift.source_revision>=p_revision) then
      raise exception 'shift identity or revision conflict' using errcode='22023';
    end if;
    select count(*) into old_count from nohut_private.shift_corrections where restaurant_id=p_restaurant and shift_id=sid;
    if jsonb_array_length(row_data->'corrections')<old_count then raise exception 'correction history removed' using errcode='22023'; end if;
    if old_shift.shift_id is not null and jsonb_array_length(row_data->'corrections')=old_count
      and (st is distinct from old_shift.started_at or (old_shift.ended_at is not null and en is distinct from old_shift.ended_at)) then
      raise exception 'unaudited correction' using errcode='22023';
    end if;
    insert into nohut_private.shifts(restaurant_id,shift_id,employee_id,employee_label,started_at,ended_at,source,source_revision)
      values(p_restaurant,sid,eid,row_data->>'employeeName',st,en,row_data->>'source',p_revision)
      on conflict(restaurant_id,shift_id) do update set started_at=excluded.started_at,ended_at=excluded.ended_at,source_revision=excluded.source_revision;
    idx:=0;
    for correction in select value from jsonb_array_elements(row_data->'corrections') loop
      if jsonb_typeof(correction) is distinct from 'object' then raise exception 'invalid correction' using errcode='22023'; end if;
      if exists(select 1 from jsonb_object_keys(correction) k(key) where key not in ('at','byId','by','before','after','reason'))
        or jsonb_typeof(correction->'before') is distinct from 'object'
        or jsonb_typeof(correction->'after') is distinct from 'object'
        or jsonb_typeof(correction->'byId') is distinct from 'number'
        or coalesce(correction->>'byId','') !~ '^[1-9][0-9]*$'
        or jsonb_typeof(correction->'by') is distinct from 'string'
        or coalesce(length(correction->>'by'),0) not between 1 and 256
        or jsonb_typeof(correction->'reason') is distinct from 'string'
        or coalesce(length(trim(correction->>'reason')),0) not between 1 and 300 then
        raise exception 'invalid correction fields' using errcode='22023';
      end if;
      if exists(select 1 from jsonb_object_keys(correction->'before') k(key) where key not in ('start','end'))
        or exists(select 1 from jsonb_object_keys(correction->'after') k(key) where key not in ('start','end')) then
        raise exception 'unknown correction interval field' using errcode='22023';
      end if;
      select employee_id into aid from nohut_private.employee_source_ids where restaurant_id=p_restaurant and local_id=(correction->>'byId')::bigint;
      if not found then raise exception 'unknown correction actor' using errcode='22023'; end if;
      ca:=nohut_private.shift_timestamp(correction->'at');
      bs:=nohut_private.shift_timestamp(correction->'before'->'start'); be:=nohut_private.shift_timestamp(correction->'before'->'end');
      ast:=nohut_private.shift_timestamp(correction->'after'->'start'); ae:=nohut_private.shift_timestamp(correction->'after'->'end');
      if ca is null or bs is null or ast is null or (be is not null and be<bs) or (ae is not null and ae<ast) then raise exception 'invalid correction interval' using errcode='22023'; end if;
      if idx=old_count and old_shift.shift_id is not null and
        (bs is distinct from old_shift.started_at or (old_shift.ended_at is not null and be is distinct from old_shift.ended_at)) then
        raise exception 'correction does not match previous shift' using errcode='22023';
      end if;
      select * into old_c from nohut_private.shift_corrections where restaurant_id=p_restaurant and shift_id=sid and ordinal=idx;
      if found then
        if row(old_c.corrected_at,old_c.corrected_by,old_c.actor_label,old_c.before_start,old_c.before_end,old_c.after_start,old_c.after_end,old_c.reason)
          is distinct from row(ca,aid,correction->>'by',bs,be,ast,ae,correction->>'reason') then
          raise exception 'correction history changed' using errcode='22023';
        end if;
      else
        insert into nohut_private.shift_corrections values(p_restaurant,sid,idx,ca,aid,correction->>'by',bs,be,ast,ae,correction->>'reason');
      end if;
      idx:=idx+1;
    end loop;
    if idx>0 and (st is distinct from ast or (ae is not null and en is distinct from ae)) then
      raise exception 'shift differs from audited correction' using errcode='22023';
    end if;
  end loop;
  if exists(select 1 from nohut_private.shifts where restaurant_id=p_restaurant and not(shift_id=any(seen))) then
    raise exception 'shift history cannot be removed' using errcode='22023';
  end if;
  if exists(select 1 from nohut_private.shifts where restaurant_id=p_restaurant and ended_at is null group by employee_id having count(*)>1) then
    raise exception 'multiple open shifts' using errcode='22023';
  end if;
end $$;
revoke all on function nohut_private.shift_timestamp(jsonb),nohut_private.apply_shift_projection(uuid,bigint,jsonb) from public,anon,authenticated,service_role;
create or replace function nohut_private.ingest_sync_transaction(p_restaurant uuid,p_epoch uuid,p_tx jsonb)
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
  -- Prevalidate all categories; apply employees first for foreign keys.
  if n>2 or exists(select 1 from jsonb_array_elements(p_tx->'events') v(ev)
    where v.ev->>'entity_type' not in ('employees','shifts') or v.ev->>'entity_id'<>'core' or v.ev->>'op'<>'upsert')
    or (select count(distinct v.ev->>'entity_type') from jsonb_array_elements(p_tx->'events') v(ev))<>n then
    raise exception 'typed projection not supported yet' using errcode='22023';
  end if;
  for ev in select value from jsonb_array_elements(p_tx->'events') order by value->>'entity_type' loop
    case ev->>'entity_type'
      when 'employees' then perform nohut_private.apply_employee_projection(p_restaurant,rev,ev->'payload');
      when 'shifts' then perform nohut_private.apply_shift_projection(p_restaurant,rev,ev->'payload');
    end case;
  end loop;
  insert into nohut_private.sync_transactions(restaurant_id,authority_epoch,tx_id,source_revision,first_seq,last_seq,event_count,schema_version,body_sha256)
    values(p_restaurant,p_epoch,tid,rev,fst,lst,n,1,p_tx->>'body_sha256');
  insert into nohut_private.sync_event_ids(restaurant_id,authority_epoch,tx_id,event_id,event_ordinal,seq,entity_type,entity_id,op,body_sha256)
    select p_restaurant,p_epoch,tid,v.ev->>'event_id',(v.ev->>'event_ordinal')::integer,(v.ev->>'seq')::bigint,v.ev->>'entity_type',v.ev->>'entity_id',v.ev->>'op',v.ev->>'body_sha256'
    from jsonb_array_elements(p_tx->'events') v(ev);
  update nohut_private.sync_checkpoints c set last_acked_seq=lst,last_acked_revision=rev,updated_at=clock_timestamp()
    where c.restaurant_id=p_restaurant and c.authority_epoch=p_epoch;
  return jsonb_build_object('status','accepted','acked_through_seq',lst);
end $$;
commit;
