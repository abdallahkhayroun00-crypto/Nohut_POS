-- Consume the authoritative manual Mesai model; never derive actual hours from plans.
begin;
create or replace function nohut_private.apply_shift_projection(p_restaurant uuid,p_revision bigint,p_rows jsonb)
returns void language plpgsql security invoker set search_path=pg_catalog,nohut_private
as $$
declare row_data jsonb; correction jsonb; sid text; seen text[]:=array[]::text[];
  eid uuid; aid uuid; st timestamptz; en timestamptz; bs timestamptz; be timestamptz;
  ast timestamptz; ae timestamptz; ca timestamptz; idx integer; old_count integer;
  bm integer; bb integer; ab integer; pv boolean; chain_start timestamptz; chain_end timestamptz; chain_break integer;
  old_shift nohut_private.shifts%rowtype; old_c nohut_private.shift_corrections%rowtype;
begin
  if jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'shifts must be array' using errcode='22023'; end if;
  for row_data in select value from jsonb_array_elements(p_rows) loop
    if jsonb_typeof(row_data) is distinct from 'object' then raise exception 'invalid shift' using errcode='22023'; end if;
    if exists(select 1 from jsonb_object_keys(row_data) k(key) where key not in ('id','employeeId','employeeName','start','end','source','corrections','breakMinutes','note','createdAt','updatedAt','voided','voidedAt','voidReason'))
      or jsonb_typeof(row_data->'id') is distinct from 'string'
      or coalesce(length(row_data->>'id'),0) not between 1 and 160
      or jsonb_typeof(row_data->'employeeId') is distinct from 'number'
      or coalesce(row_data->>'employeeId','') !~ '^[1-9][0-9]*$'
      or jsonb_typeof(row_data->'employeeName') is distinct from 'string'
      or coalesce(length(row_data->>'employeeName'),0) not between 1 and 256
      or coalesce(row_data->>'source','') not in ('pos','remote','manual')
      or jsonb_typeof(row_data->'corrections') is distinct from 'array' then
      raise exception 'invalid shift fields' using errcode='22023';
    end if;
    bm:=nohut_private.shift_break(row_data->'breakMinutes');
    pv:=coalesce((row_data->>'voided')::boolean,false);
    if (row_data ? 'voided' and jsonb_typeof(row_data->'voided')<>'boolean')
      or (row_data ? 'note' and jsonb_typeof(row_data->'note')<>'string')
      or (row_data->'voidReason'<>'null'::jsonb and jsonb_typeof(row_data->'voidReason')<>'string')
      or (row_data->>'source'='manual' and (nohut_private.shift_timestamp(row_data->'createdAt') is null
        or nohut_private.shift_timestamp(row_data->'updatedAt') is null)) then
      raise exception 'invalid attendance metadata' using errcode='22023'; end if;
    sid:=row_data->>'id';
    if sid=any(seen) then raise exception 'duplicate shift' using errcode='22023'; end if;
    seen:=array_append(seen,sid);
    select employee_id into eid from nohut_private.employee_source_ids where restaurant_id=p_restaurant and local_id=(row_data->>'employeeId')::bigint;
    if not found then raise exception 'unknown shift employee' using errcode='22023'; end if;
    st:=nohut_private.shift_timestamp(row_data->'start'); en:=nohut_private.shift_timestamp(row_data->'end');
    if st is null or (en is not null and en<st) then raise exception 'invalid shift interval' using errcode='22023'; end if;
    select * into old_shift from nohut_private.shifts where restaurant_id=p_restaurant and shift_id=sid;
    if found and (old_shift.employee_id<>eid or old_shift.source<>row_data->>'source'
      or old_shift.employee_label is distinct from row_data->>'employeeName' or old_shift.source_revision>=p_revision) then
      raise exception 'shift identity or revision conflict' using errcode='22023';
    end if;
    select count(*) into old_count from nohut_private.shift_corrections where restaurant_id=p_restaurant and shift_id=sid;
    if jsonb_array_length(row_data->'corrections')<old_count then raise exception 'correction history removed' using errcode='22023'; end if;
    if old_shift.shift_id is not null and (
      (old_shift.created_at is not null and old_shift.created_at is distinct from nohut_private.shift_timestamp(row_data->'createdAt'))
      or (old_shift.voided and (not pv or old_shift.voided_at is distinct from nohut_private.shift_timestamp(row_data->'voidedAt')
        or old_shift.void_reason is distinct from row_data->>'voidReason'))) then
      raise exception 'immutable attendance facts changed' using errcode='22023'; end if;
    if old_shift.shift_id is not null and jsonb_array_length(row_data->'corrections')=old_count
      and (st is distinct from old_shift.started_at or bm<>old_shift.break_minutes or pv<>old_shift.voided or coalesce(row_data->>'note','')<>old_shift.note or (old_shift.ended_at is not null and en is distinct from old_shift.ended_at)) then
      raise exception 'unaudited correction' using errcode='22023';
    end if;
    insert into nohut_private.shifts(restaurant_id,shift_id,employee_id,employee_label,started_at,ended_at,source,source_revision,break_minutes,note,created_at,local_updated_at,voided,voided_at,void_reason)
      values(p_restaurant,sid,eid,row_data->>'employeeName',st,en,row_data->>'source',p_revision,bm,coalesce(row_data->>'note',''),nohut_private.shift_timestamp(row_data->'createdAt'),nohut_private.shift_timestamp(row_data->'updatedAt'),pv,nohut_private.shift_timestamp(row_data->'voidedAt'),row_data->>'voidReason')
      on conflict(restaurant_id,shift_id) do update set started_at=excluded.started_at,ended_at=excluded.ended_at,source_revision=excluded.source_revision,break_minutes=excluded.break_minutes,note=excluded.note,created_at=excluded.created_at,local_updated_at=excluded.local_updated_at,voided=excluded.voided,voided_at=excluded.voided_at,void_reason=excluded.void_reason;
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
      if exists(select 1 from jsonb_object_keys(correction->'before') k(key) where key not in ('start','end','breakMinutes'))
        or exists(select 1 from jsonb_object_keys(correction->'after') k(key) where key not in ('start','end','breakMinutes')) then
        raise exception 'unknown correction interval field' using errcode='22023';
      end if;
      select employee_id into aid from nohut_private.employee_source_ids where restaurant_id=p_restaurant and local_id=(correction->>'byId')::bigint;
      if not found then raise exception 'unknown correction actor' using errcode='22023'; end if;
      bb:=nohut_private.shift_break(correction->'before'->'breakMinutes'); ab:=nohut_private.shift_break(correction->'after'->'breakMinutes');
      ca:=nohut_private.shift_timestamp(correction->'at');
      bs:=nohut_private.shift_timestamp(correction->'before'->'start'); be:=nohut_private.shift_timestamp(correction->'before'->'end');
      ast:=nohut_private.shift_timestamp(correction->'after'->'start'); ae:=nohut_private.shift_timestamp(correction->'after'->'end');
      if idx>0 and row(bs,be,bb) is distinct from row(chain_start,chain_end,chain_break) then
        raise exception 'broken correction chain' using errcode='22023'; end if;
      if ca is null or bs is null or ast is null or (be is not null and be<bs) or (ae is not null and ae<ast) then raise exception 'invalid correction interval' using errcode='22023'; end if;
      if idx=old_count and old_shift.shift_id is not null and
        (bb<>old_shift.break_minutes or bs is distinct from old_shift.started_at or (old_shift.ended_at is not null and be is distinct from old_shift.ended_at)) then
        raise exception 'correction does not match previous shift' using errcode='22023';
      end if;
      select * into old_c from nohut_private.shift_corrections where restaurant_id=p_restaurant and shift_id=sid and ordinal=idx;
      if found then
        if row(old_c.corrected_at,old_c.corrected_by,old_c.actor_label,old_c.before_start,old_c.before_end,old_c.after_start,old_c.after_end,old_c.reason,old_c.before_break_minutes,old_c.after_break_minutes)
          is distinct from row(ca,aid,correction->>'by',bs,be,ast,ae,correction->>'reason',bb,ab) then
          raise exception 'correction history changed' using errcode='22023';
        end if;
      else
        insert into nohut_private.shift_corrections values(p_restaurant,sid,idx,ca,aid,correction->>'by',bs,be,ast,ae,correction->>'reason',bb,ab);
      end if;
      chain_start:=ast; chain_end:=ae; chain_break:=ab;
      idx:=idx+1;
    end loop;
    if idx>0 and (bm<>ab or st is distinct from ast or (ae is not null and en is distinct from ae)) then
      raise exception 'shift differs from audited correction' using errcode='22023';
    end if;
    if pv and (idx=0 or row_data#>>'{corrections,-1,reason}' is distinct from 'İptal: '||(row_data->>'voidReason')) then
      raise exception 'void audit missing' using errcode='22023'; end if;
  end loop;
  if exists(select 1 from nohut_private.shifts where restaurant_id=p_restaurant and not(shift_id=any(seen))) then
    raise exception 'shift history cannot be removed' using errcode='22023';
  end if;
  if exists(select 1 from nohut_private.shifts where restaurant_id=p_restaurant and ended_at is null group by employee_id having count(*)>1) then
    raise exception 'multiple open shifts' using errcode='22023';
  end if;
end $$;
revoke all on function nohut_private.apply_shift_projection(uuid,bigint,jsonb) from public,anon,authenticated,service_role;
commit;
