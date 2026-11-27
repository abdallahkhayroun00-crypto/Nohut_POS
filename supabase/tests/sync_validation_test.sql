\set ON_ERROR_STOP on
begin;
do $$
declare
  epoch uuid := '00000000-0000-4000-8000-000000000009';
  epoch_text text:=replace(epoch::text,'-','');
  body text:='{"active":true,"id":1,"name":"Synthetic"}';
  h text:=encode(sha256(convert_to(body,'UTF8')),'hex');
  th text:=encode(sha256(convert_to('nohut-tx:'||epoch_text||':1','UTF8')),'hex');
  tx jsonb;
  bad jsonb;
begin
  tx:=jsonb_build_object('authority_epoch',epoch_text,'schema_version',1,
    'source_revision',1,'first_seq',1,'last_seq',1,'event_count',1,
    'tx_id',substr(th,1,8)||'-'||substr(th,9,4)||'-5'||substr(th,14,3)||'-a'||substr(th,18,3)||'-'||substr(th,21,12),
    'body_sha256',encode(sha256(convert_to(h,'UTF8')),'hex'),
    'events',jsonb_build_array(jsonb_build_object('event_ordinal',0,'seq',1,
      'event_id',epoch_text||':1:employees:core','entity_type','employees','entity_id','core',
      'op','upsert','payload_json',body,'payload',body::jsonb,'body_sha256',h)));
  perform nohut_private.validate_sync_transaction(epoch,tx);
  foreach bad in array array[
    jsonb_set(tx,'{last_seq}','2'),
    jsonb_set(tx,'{events,0,seq}','2'),
    jsonb_set(tx,'{events,0,body_sha256}',to_jsonb(repeat('0',64))),
    jsonb_set(tx,'{events,0,payload,active}','false'),
    jsonb_set(tx,'{events,0,op}','"delete"'),
    jsonb_set(tx,'{tx_id}','"bad"'),
    tx-'authority_epoch'
  ] loop
    begin
      perform nohut_private.validate_sync_transaction(epoch,bad);
      raise exception 'invalid transaction accepted';
    exception when invalid_parameter_value then null;
    end;
  end loop;
  if has_function_privilege('authenticated','nohut_private.validate_sync_transaction(uuid,jsonb)','EXECUTE') then
    raise exception 'validator exposed';
  end if;
  if exists(select 1 from nohut_private.sync_transactions) then
    raise exception 'validation must not write a ledger or ACK';
  end if;
end $$;
rollback;
