-- PR-05B validation boundary; does not persist or acknowledge business data.
-- Typed projection + atomic checkpoint write must follow in one transaction.
begin;
create function nohut_private.validate_sync_transaction(p_epoch uuid,p_tx jsonb)
returns void language plpgsql security invoker set search_path=pg_catalog,nohut_private
as $$
declare
  epoch_text text:=replace(p_epoch::text,'-','');
  rev bigint; first_seq bigint; last_seq bigint; n integer;
  ev jsonb; ordinal integer:=0; h text; hashes text[]:=array[]::text[];
  tx_hash text; expected_tx uuid; ids text[]:=array[]::text[];
begin
  if p_epoch is null or jsonb_typeof(p_tx) is distinct from 'object'
    or pg_column_size(p_tx)>8388608
    or jsonb_typeof(p_tx->'events') is distinct from 'array'
    or (p_tx->>'authority_epoch') is distinct from epoch_text
    or (p_tx->>'schema_version') is distinct from '1' then
    raise exception 'invalid transaction envelope' using errcode='22023';
  end if;
  rev:=(p_tx->>'source_revision')::bigint;
  first_seq:=(p_tx->>'first_seq')::bigint;
  last_seq:=(p_tx->>'last_seq')::bigint;
  n:=jsonb_array_length(p_tx->'events');
  if rev is null or rev<0 or first_seq is null or first_seq<1
    or last_seq is null or last_seq<first_seq or last_seq-first_seq+1<>n
    or n<1 or (p_tx->>'event_count')::integer is distinct from n then
    raise exception 'invalid transaction range' using errcode='22023';
  end if;
  tx_hash:=encode(sha256(convert_to('nohut-tx:'||epoch_text||':'||rev,'UTF8')),'hex');
  expected_tx:=(substr(tx_hash,1,8)||'-'||substr(tx_hash,9,4)||'-5'||substr(tx_hash,14,3)||'-a'||substr(tx_hash,18,3)||'-'||substr(tx_hash,21,12))::uuid;
  if (p_tx->>'tx_id') is distinct from expected_tx::text then
    raise exception 'transaction identity mismatch' using errcode='22023';
  end if;
  for ev in select value from jsonb_array_elements(p_tx->'events') loop
    if jsonb_typeof(ev) is distinct from 'object'
      or (ev->>'event_ordinal')::integer is distinct from ordinal
      or (ev->>'seq')::bigint is distinct from first_seq+ordinal
      or coalesce(length(ev->>'entity_type'),0) not between 1 and 64
      or coalesce(length(ev->>'entity_id'),0) not between 1 and 256
      or coalesce(ev->>'op','') not in ('upsert','delete')
      or jsonb_typeof(ev->'payload_json') is distinct from 'string'
      or not (ev ? 'payload') then
      raise exception 'invalid event' using errcode='22023';
    end if;
    if (ev->>'event_id') is distinct from
       (epoch_text||':'||rev||':'||(ev->>'entity_type')||':'||(ev->>'entity_id'))
      or ev->>'event_id'=any(ids) then
      raise exception 'event identity mismatch' using errcode='22023';
    end if;
    if (ev->>'payload_json')::jsonb is distinct from ev->'payload'
      or ((ev->>'op'='delete') is distinct from (ev->'payload'='null'::jsonb)) then
      raise exception 'payload mismatch' using errcode='22023';
    end if;
    h:=encode(sha256(convert_to(ev->>'payload_json','UTF8')),'hex');
    if (ev->>'body_sha256') is distinct from h then
      raise exception 'payload hash mismatch' using errcode='22023';
    end if;
    hashes:=array_append(hashes,h);
    ids:=array_append(ids,ev->>'event_id');
    ordinal:=ordinal+1;
  end loop;
  if (p_tx->>'body_sha256') is distinct from
     encode(sha256(convert_to(array_to_string(hashes,E'\n'),'UTF8')),'hex') then
    raise exception 'transaction hash mismatch' using errcode='22023';
  end if;
end $$;
revoke all on function nohut_private.validate_sync_transaction(uuid,jsonb) from public,anon,authenticated,service_role;
commit;
