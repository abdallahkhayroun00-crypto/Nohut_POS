begin;
create function nohut_private.apply_typed_ledger(p_restaurant uuid,p_revision bigint,p_kind text,p jsonb)
returns void language plpgsql security invoker set search_path='' as $$
declare tables text[]; t text; r jsonb; ev jsonb; prior jsonb; ordered jsonb; gid uuid; aid uuid; oid uuid; members uuid[];
  amount numeric; cash numeric; card numeric; n bigint; ordinal bigint;
begin
  perform nohut_private.command_shape(p,'{"source_updated_at":"string","counts":"object","rows":"array"}');
  tables:=case p_kind when 'combinedPayments' then array['combined_payment_groups','combined_payment_members']
    when 'terminalAttempts' then array['terminal_attempts','terminal_attempt_events'] when 'cashBook' then array['cash_sessions','cash_movements'] else null end;
  if tables is null or (select array_agg(k order by k) from jsonb_object_keys(p->'counts') k) is distinct from
    (select array_agg(k order by k) from unnest(tables) k) then raise exception 'financial ledger manifest missing' using errcode='22023'; end if;
  if exists(select 1 from jsonb_array_elements(p->'rows') x where not(x->>'table'=any(tables))) then
    raise exception 'unexpected ledger table' using errcode='22023'; end if;
  foreach t in array tables loop
    if jsonb_typeof(p->'counts'->t) is distinct from 'number' or p->'counts'->>t !~ '^[0-9]+$'
      or (p->'counts'->>t)::numeric<>(select count(*) from jsonb_array_elements(p->'rows') x where x->>'table'=t) then
      raise exception 'financial ledger count mismatch' using errcode='22023'; end if;
  end loop;
  if p_kind='combinedPayments' then
    for r in select x->'data' from jsonb_array_elements(p->'rows') x where x->>'table'='combined_payment_groups' loop
      gid:=(r->>'group_id')::uuid;
      select array_agg((x->'data'->>'order_id')::uuid order by (x->'data'->>'ordinal')::bigint),count(*)
        into members,n from jsonb_array_elements(p->'rows') x where x->>'table'='combined_payment_members' and x->'data'->>'group_id'=gid::text;
      if n is distinct from (r->>'order_count')::bigint or n=0 or cardinality(members)<>(select count(distinct i) from unnest(members) i) then
        raise exception 'combined membership mismatch' using errcode='22023'; end if;
      ordinal:=0;
      for ev in select x->'data' from jsonb_array_elements(p->'rows') x where x->>'table'='combined_payment_members' and x->'data'->>'group_id'=gid::text order by (x->'data'->>'ordinal')::bigint loop
        if ev->'ordinal' is distinct from to_jsonb(ordinal) then raise exception 'combined ordinal mismatch' using errcode='22023'; end if;ordinal:=ordinal+1;
      end loop;
      select coalesce(sum(x.amount_kurus),0),coalesce(sum(x.amount_kurus) filter(where x.method='nakit'),0),
        coalesce(sum(x.amount_kurus) filter(where x.method='kart'),0),count(distinct x.order_id)
        into amount,cash,card,n from nohut_private.payments x where x.restaurant_id=p_restaurant and x.combined_payment_id=r->>'source_reference';
      if amount is distinct from (r->>'amount_kurus')::numeric or cash is distinct from (r->>'cash_kurus')::numeric
        or card is distinct from (r->>'card_kurus')::numeric or amount<>cash+card or n<>cardinality(members)
        or exists(select 1 from nohut_private.payments x where x.restaurant_id=p_restaurant and x.combined_payment_id=r->>'source_reference' and not(x.order_id=any(members)))
        or (cash>0 and (r->'received_kurus'='null'::jsonb or (r->>'received_kurus')::numeric<cash
          or (select sum(x.received_kurus) from nohut_private.payments x where x.restaurant_id=p_restaurant
            and x.combined_payment_id=r->>'source_reference' and x.method='nakit') is distinct from (r->>'received_kurus')::numeric))
        or (r->>'method'='cash' and card<>0) or (r->>'method'='card' and cash<>0)
        or (r->>'method'='mixed' and (cash<=0 or card<=0)) then raise exception 'combined payment facts mismatch' using errcode='22023'; end if;
    end loop;
  elsif p_kind='terminalAttempts' then
    for r in select x->'data' from jsonb_array_elements(p->'rows') x where x->>'table'='terminal_attempts' loop
      aid:=(r->>'attempt_id')::uuid;oid:=(r->>'order_id')::uuid;ordinal:=0;prior:=null;
      if not exists(select 1 from nohut_private.orders o where o.restaurant_id=p_restaurant and o.order_id=oid and o.local_order_id=r->>'local_order_id') then
        raise exception 'terminal order identity mismatch' using errcode='22023'; end if;
      for ev in select x->'data' from jsonb_array_elements(p->'rows') x where x->>'table'='terminal_attempt_events' and x->'data'->>'attempt_id'=aid::text order by (x->'data'->>'ordinal')::bigint loop
        if ev->'ordinal' is distinct from to_jsonb(ordinal) or (ordinal=0 and ev->>'origin' not in ('created','legacy_current'))
          or (ordinal>0 and (ev->>'origin'<>'transition' or (ev->>'observed_at')::timestamptz<(prior->>'observed_at')::timestamptz)) then
          raise exception 'terminal audit chain mismatch' using errcode='22023'; end if;
        if ordinal=0 and ev->'observed_at' is distinct from r->'first_observed_at' then raise exception 'terminal first observation mismatch' using errcode='22023'; end if;
        prior:=ev;ordinal:=ordinal+1;
      end loop;
      if ordinal=0 or ordinal is distinct from (r->>'event_count')::bigint or prior->'status' is distinct from r->'status'
        or prior->'dispatched' is distinct from r->'dispatched' or prior->'transaction_id' is distinct from r->'transaction_id'
        or prior->'observed_at' is distinct from r->'last_observed_at' then raise exception 'terminal current state not audited' using errcode='22023'; end if;
      select count(*),coalesce(sum(x.amount_kurus),0) into n,amount from nohut_private.payments x
        where x.restaurant_id=p_restaurant and x.terminal_reference=r->>'source_reference';
      if r->>'status'='approved' then
        if n<>1 or amount is distinct from (r->>'amount_kurus')::numeric or coalesce(r->>'transaction_id','')=''
          or not exists(select 1 from nohut_private.payments x where x.restaurant_id=p_restaurant and x.terminal_reference=r->>'source_reference'
            and x.order_id=oid and x.method='kart' and x.transaction_id=r->>'transaction_id') then raise exception 'terminal approval payment mismatch' using errcode='22023'; end if;
      elsif n<>0 then raise exception 'unapproved terminal has payment' using errcode='22023'; end if;
    end loop;
  else
    for r in select x->'data' from jsonb_array_elements(p->'rows') x where x->>'table'='cash_sessions' loop
      if r->'closed_at'='null'::jsonb then
        if r->'closed_by'<>'null'::jsonb or r->'counted_kurus'<>'null'::jsonb or r->'expected_kurus'<>'null'::jsonb or r->'difference_kurus'<>'null'::jsonb then
          raise exception 'open cash session has closure facts' using errcode='22023'; end if;
      elsif jsonb_typeof(r->'counted_kurus') is distinct from 'number' or jsonb_typeof(r->'expected_kurus') is distinct from 'number'
        or jsonb_typeof(r->'difference_kurus') is distinct from 'number' or jsonb_typeof(r->'closed_by') is distinct from 'string'
        or (r->>'counted_kurus')::numeric-(r->>'expected_kurus')::numeric is distinct from (r->>'difference_kurus')::numeric
        or (r->>'closed_at')::timestamptz<(r->>'opened_at')::timestamptz then raise exception 'cash closure facts mismatch' using errcode='22023'; end if;
    end loop;
  end if;
  select coalesce(jsonb_agg(x order by array_position(tables,x->>'table')),'[]'::jsonb) into ordered from jsonb_array_elements(p->'rows') x;
  perform nohut_private.apply_typed_projection(p_restaurant,p_revision,'ledger:'||p_kind,
    jsonb_build_object('source_updated_at',p->'source_updated_at','rows',ordered));
end $$;
revoke all on function nohut_private.apply_typed_ledger(uuid,bigint,text,jsonb) from public,anon,authenticated,service_role;
commit;
