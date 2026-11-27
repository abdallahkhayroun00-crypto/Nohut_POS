-- Scoped Windows HTTP RPC surface. A publishable project key is NOT the
-- agent credential: every entrypoint authenticates the opaque scoped token.
-- No direct business-table or private-function grants; no service-role key.
begin;

create function nohut_private.command_envelope_sha256(p_envelope jsonb)
returns text language sql immutable set search_path='' as $$
  select encode(sha256(convert_to(nohut_private.canonical_command_json(p_envelope),'UTF8')),'hex')
$$;

create function public.nohut_agent_checkpoint(p_token text)
returns jsonb language sql security definer set search_path='' as $$
  select nohut_private.agent_checkpoint(p_token)
$$;

create function public.nohut_agent_ingest(p_token text,p_tx jsonb)
returns jsonb language sql security definer set search_path='' as $$
  select nohut_private.agent_ingest(p_token,p_tx)
$$;

-- Keep selected claims in the function's local JSON rather than querying
-- all processing rows (which could otherwise leak/reissue a prior claim).
create function public.nohut_agent_claim(p_token text,p_max integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a nohut_private.windows_agents; c record; deadline timestamptz; result jsonb:='[]'::jsonb;
begin
  a:=nohut_private.authenticate_windows_agent(p_token);
  for c in select * from nohut_private.claim_authorized_commands(a.restaurant_id,a.authority_epoch,p_max) loop
    select q.lease_until into strict deadline from nohut_private.commands q
      where q.restaurant_id=a.restaurant_id and q.request_id=c.envelope->>'request_id';
    result:=result||jsonb_build_array(jsonb_build_object('envelope',c.envelope,
      'lease_generation',c.lease_generation,'lease_until',deadline));
  end loop;
  return jsonb_build_object('claims',result,'server_now',clock_timestamp(),
    'restaurant_id',a.restaurant_id,'authority_epoch',a.authority_epoch);
end $$;

create function public.nohut_agent_validate_claim(p_token text,p_request text,p_generation bigint,p_envelope_sha256 text)
returns boolean language plpgsql security definer set search_path='' as $$
declare a nohut_private.windows_agents;
begin
  a:=nohut_private.authenticate_windows_agent(p_token);
  return exists(select 1 from nohut_private.commands q
    where q.restaurant_id=a.restaurant_id and q.authority_epoch=a.authority_epoch
      and q.request_id=p_request and q.state='processing' and q.lease_generation=p_generation
      and q.lease_until>clock_timestamp() and q.expires_at>clock_timestamp()
      and nohut_private.command_envelope_sha256(q.envelope)=p_envelope_sha256
      and nohut_private.command_still_authorized(a.restaurant_id,q.envelope));
end $$;

create function public.nohut_agent_complete(p_token text,p_request text,p_generation bigint,p_envelope_sha256 text,p_result jsonb)
returns text language plpgsql security definer set search_path='' as $$
declare a nohut_private.windows_agents;
begin
  a:=nohut_private.authenticate_windows_agent(p_token);
  if not exists(select 1 from nohut_private.commands q where q.restaurant_id=a.restaurant_id
    and q.authority_epoch=a.authority_epoch and q.request_id=p_request
    and nohut_private.command_envelope_sha256(q.envelope)=p_envelope_sha256) then
    return 'conflict';
  end if;
  if octet_length(p_result::text)>65536 then raise exception 'completion too large' using errcode='22023'; end if;
  return nohut_private.complete_command(a.restaurant_id,a.authority_epoch,p_request,p_generation,p_result);
end $$;

-- Reconciliation reports an existing Windows receipt/attempt; it never
-- dispatches business work. Revoked user access does not erase real outcomes.
create function public.nohut_agent_report_receipt(p_token text,p_request text,p_envelope_sha256 text,p_result jsonb)
returns text language plpgsql security definer set search_path='' as $$
declare a nohut_private.windows_agents; c nohut_private.commands; st text;
begin
  a:=nohut_private.authenticate_windows_agent(p_token);
  st:=p_result->>'state';
  if jsonb_typeof(p_result) is distinct from 'object' or st is null
    or st not in ('confirmed','rejected','reconciliation_required') or octet_length(p_result::text)>65536 then
    raise exception 'invalid receipt' using errcode='22023';
  end if;
  select * into c from nohut_private.commands q where q.restaurant_id=a.restaurant_id
    and q.authority_epoch=a.authority_epoch and q.request_id=p_request for update;
  if not found or c.lease_generation=0 or nohut_private.command_envelope_sha256(c.envelope) is distinct from p_envelope_sha256 then
    return 'conflict';
  end if;
  if c.result=p_result then return 'duplicate'; end if;
  if c.state not in ('processing','reconciliation_required') then return 'conflict'; end if;
  -- A reported uncertain result can later be replaced only by a durable
  -- confirmed/rejected receipt from this same fenced authority.
  update nohut_private.commands q set state=st,lease_until=null,result=p_result
    where q.restaurant_id=a.restaurant_id and q.request_id=p_request;
  return 'accepted';
end $$;

revoke all on function nohut_private.command_envelope_sha256(jsonb) from public,anon,authenticated,service_role;
do $$ declare f record; begin
  for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('nohut_agent_checkpoint','nohut_agent_ingest','nohut_agent_claim',
      'nohut_agent_validate_claim','nohut_agent_complete','nohut_agent_report_receipt') loop
    execute format('revoke all on function %s from public,anon,authenticated,service_role',f.signature);
    execute format('grant execute on function %s to anon,authenticated',f.signature);
  end loop;
end $$;
commit;
