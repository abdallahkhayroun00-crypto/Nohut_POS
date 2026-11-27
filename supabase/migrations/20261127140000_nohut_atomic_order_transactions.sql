-- Extend the existing atomic ingest; unsupported groups still fail before ACK.
begin;
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
  if exists(select 1 from jsonb_array_elements(p_tx->'events') v(ev)
    where not((v.ev->>'entity_type' in ('employees','shifts','typed_finance') and v.ev->>'entity_id'='core')
      or (v.ev->>'entity_type'='typed_catalog' and v.ev->>'entity_id' in ('localMenu','internalMenu','qrCategories','qrCampaigns'))
      or (v.ev->>'entity_type' in ('typed_order','order_archive_marker') and v.ev->>'entity_id' ~ '^[0-9]+$'))
      or v.ev->>'op'<>'upsert')
    or (select count(distinct (v.ev->>'entity_type',v.ev->>'entity_id')) from jsonb_array_elements(p_tx->'events') v(ev))<>n then
    raise exception 'typed projection not supported yet' using errcode='22023';
  end if;
  if exists(select 1 from jsonb_array_elements(p_tx->'events') marker where marker->>'entity_type'='order_archive_marker'
    and (marker->'payload' is distinct from jsonb_build_object('local_order_id',marker->>'entity_id','archive_required',true)
      or not exists(select 1 from jsonb_array_elements(p_tx->'events') archive where archive->>'entity_type'='typed_order'
        and archive->>'entity_id'=marker->>'entity_id' and archive->'payload'->'counts'->'deleted_order_audit'='1'::jsonb))) then
    raise exception 'order deletion without full archive' using errcode='22023'; end if;
  for ev in select value from jsonb_array_elements(p_tx->'events') order by value->>'entity_type' loop
    case ev->>'entity_type'
      when 'employees' then perform nohut_private.apply_employee_projection(p_restaurant,rev,ev->'payload');
      when 'typed_catalog' then perform nohut_private.apply_typed_projection(p_restaurant,rev,ev->>'entity_id',ev->'payload');
      when 'typed_finance' then perform nohut_private.apply_typed_finance(p_restaurant,rev,ev->'payload');
      when 'typed_order' then perform nohut_private.apply_typed_order(p_restaurant,rev,ev->>'entity_id',ev->'payload');
      when 'order_archive_marker' then null;
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
