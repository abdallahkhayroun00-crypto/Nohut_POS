-- Typed finance projection. Financial record updates keep immutable prior
-- versions; absence from a full finance projection never deletes history.
begin;
alter table nohut_private.material_purchases
  add column market text, add column market_key text, add column market_unit text,
  add column reference_price_kurus bigint, add column discount_type text,
  add column discount_value bigint, add column amounts_kurus bigint[],
  add column note text, add column voided_at timestamptz, add column void_reason text;
alter table nohut_private.material_purchase_history
  add column previous_day date, add column previous_store_brand text,
  add column previous_market text, add column previous_amounts_kurus bigint[],
  add column previous_payment_method text, add column previous_note text;
alter table nohut_private.manual_platform_sales add column note text;
alter table nohut_private.fixed_expense_payments add column reversed boolean not null default false,
  add column reversed_at timestamptz,
  add constraint fixed_payment_reversal_state check(reversed=(reversed_at is not null));

create table nohut_private.typed_record_versions(
  restaurant_id uuid not null references nohut_private.restaurants,
  category text not null, table_name text not null, record_key jsonb not null,
  source_revision bigint not null, body jsonb not null, body_sha256 text not null,
  primary key(restaurant_id,category,table_name,record_key)
);
create table nohut_private.typed_record_history(
  restaurant_id uuid not null references nohut_private.restaurants,
  category text not null, table_name text not null, record_key jsonb not null,
  source_revision bigint not null, body jsonb not null, body_sha256 text not null,
  primary key(restaurant_id,category,table_name,record_key,source_revision)
);
do $$ declare t text; begin
  foreach t in array array['typed_record_versions','typed_record_history'] loop
    execute format('alter table nohut_private.%I enable row level security',t);
    execute format('alter table nohut_private.%I force row level security',t);
    execute format('create policy typed_rpc_owner on nohut_private.%I for all to %I using (true) with check (true)',t,current_user);
  end loop;
end $$;
revoke all on nohut_private.typed_record_versions,nohut_private.typed_record_history from public,anon,authenticated,service_role;

create function nohut_private.apply_typed_finance(p_restaurant uuid,p_revision bigint,p_payload jsonb)
returns void language plpgsql security invoker set search_path='' as $$
declare item jsonb; data jsonb; normalized jsonb; tab text; col record; keys text[]; pk jsonb; digest text;
  names text; selectors text; updates text; conflicts text; prior nohut_private.typed_record_versions;
  seen text[]:=array[]::text[]; identity_text text; employee uuid; stamp timestamptz; existing_record jsonb;
begin
  perform nohut_private.command_shape(p_payload,'{"rows":"array","source_updated_at":"string"}');
  stamp:=nohut_private.shift_timestamp(p_payload->'source_updated_at');
  if stamp is null or p_revision is null or p_revision<0 then raise exception 'invalid finance revision' using errcode='22023'; end if;
  for item in select value from jsonb_array_elements(p_payload->'rows') loop
    perform nohut_private.command_shape(item,'{"table":"string","data":"object"}');
    tab:=item->>'table'; data:=item->'data';
    if tab not in ('material_purchases','material_purchase_history','expenses','fixed_expenses',
      'fixed_expense_active_ranges','fixed_expense_amount_history','fixed_expense_payments',
      'weekly_payroll','manual_platform_sales','manual_platform_sales_history') then
      raise exception 'unsupported finance table' using errcode='22023'; end if;
    if tab='fixed_expense_payments' then data:=jsonb_build_object('reversed',false)||data; end if;
    if data ?| array['restaurant_id','source_revision','entity_version','updated_at','deleted_at'] then
      raise exception 'forged finance metadata' using errcode='22023'; end if;
    if tab='weekly_payroll' then
      if data ? 'employee_id' or jsonb_typeof(data->'employee_local_id') is distinct from 'number'
        or data->>'employee_local_id' !~ '^[0-9]+$' then raise exception 'invalid payroll employee' using errcode='22023'; end if;
      select x.employee_id into employee from nohut_private.employee_source_ids x
        where x.restaurant_id=p_restaurant and x.local_id=(data->>'employee_local_id')::bigint;
      if not found then raise exception 'unknown payroll employee' using errcode='22023'; end if;
      data:=(data-'employee_local_id')||jsonb_build_object('employee_id',employee);
    end if;
    if exists(select 1 from jsonb_object_keys(data) k(key) where not exists(
      select 1 from pg_attribute a where a.attrelid=('nohut_private.'||tab)::regclass
        and a.attname=k.key and a.attnum>0 and not a.attisdropped)) then
      raise exception 'unknown finance field' using errcode='22023'; end if;
    -- Reject numeric strings/fractions before PostgreSQL could coerce them.
    for col in select a.attname,a.atttypid,a.attnotnull from pg_attribute a
      where a.attrelid=('nohut_private.'||tab)::regclass and a.attnum>0 and not a.attisdropped
        and a.attname not in ('restaurant_id','source_revision','entity_version','updated_at','deleted_at') loop
      if col.attnotnull and (not(data ? col.attname) or data->col.attname='null'::jsonb) then
        raise exception 'missing finance field' using errcode='22023'; end if;
      if not(data ? col.attname) or data->col.attname='null'::jsonb then continue; end if;
      if col.atttypid in ('int2'::regtype,'int4'::regtype,'int8'::regtype) then
        if jsonb_typeof(data->col.attname)<>'number' or data->>col.attname !~ '^-?[0-9]+$'
          or abs((data->>col.attname)::numeric)>9007199254740991 then raise exception 'finance integer required' using errcode='22023'; end if;
      elsif col.atttypid='bool'::regtype and jsonb_typeof(data->col.attname)<>'boolean' then
        raise exception 'finance boolean required' using errcode='22023';
      elsif col.atttypid='int8[]'::regtype then
        if jsonb_typeof(data->col.attname)<>'array' then raise exception 'finance amounts array required' using errcode='22023'; end if;
        if exists(select 1 from jsonb_array_elements(data->col.attname) v where jsonb_typeof(v)<>'number'
          or v::text !~ '^[0-9]+$' or (v::text)::numeric>9007199254740991) then raise exception 'invalid finance amounts' using errcode='22023'; end if;
      elsif col.atttypid not in ('bool'::regtype) and (jsonb_typeof(data->col.attname)<>'string' or length(data->>col.attname)>1000) then
        raise exception 'finance string required' using errcode='22023';
      end if;
      if col.atttypid='date'::regtype and data->>col.attname !~ '^\d{4}-\d{2}-\d{2}$' then
        raise exception 'absolute finance date required' using errcode='22023'; end if;
      if col.atttypid='timestamptz'::regtype then perform nohut_private.shift_timestamp(data->col.attname); end if;
    end loop;
    if tab='material_purchases' then
      if data->>'record_type'='quick' then
        if jsonb_typeof(data->'amounts_kurus') is distinct from 'array' or jsonb_array_length(data->'amounts_kurus')=0
          or (select sum((v#>>'{}')::numeric) from jsonb_array_elements(data->'amounts_kurus') v) is distinct from (data->>'total_kurus')::numeric then
          raise exception 'quick purchase total mismatch' using errcode='22023'; end if;
      elsif (data->>'subtotal_kurus')::numeric is distinct from round((data->>'quantity_milli')::numeric*(data->>'unit_price_kurus')::numeric/1000)
        or (data->>'total_kurus')::numeric is distinct from (data->>'subtotal_kurus')::numeric-coalesce((data->>'discount_kurus')::numeric,0) then
        raise exception 'purchase total mismatch' using errcode='22023'; end if;
    end if;
    if tab='weekly_payroll' and ((data->>'base_kurus')::numeric is distinct from
      case when data->>'pay_type'='hourly' then round((data->>'rate_kurus')::numeric*(data->>'worked_minutes')::numeric/60)
      else (data->>'rate_kurus')::numeric end or extract(isodow from (data->>'week_start')::date)<>1) then
      raise exception 'payroll base mismatch' using errcode='22023'; end if;
    data:=data||jsonb_build_object('restaurant_id',p_restaurant,'entity_version',p_revision+1,
      'source_revision',p_revision,'updated_at',stamp);
    execute format('select to_jsonb(jsonb_populate_record(null::nohut_private.%I,$1))',tab) into normalized using data;
    select array_agg(a.attname order by k.ordinality) into keys
      from pg_constraint c cross join lateral unnest(c.conkey) with ordinality k(attnum,ordinality)
      join pg_attribute a on a.attrelid=c.conrelid and a.attnum=k.attnum
      where c.conrelid=('nohut_private.'||tab)::regclass and c.contype='p';
    select jsonb_object_agg(k,normalized->k) into pk from unnest(keys) k;
    if exists(select 1 from jsonb_each(pk) v where v.value='null'::jsonb) then raise exception 'finance primary key missing' using errcode='22023'; end if;
    identity_text:=tab||':'||pk::text;
    if identity_text=any(seen) then raise exception 'duplicate finance identity' using errcode='22023'; end if;
    seen:=array_append(seen,identity_text);
    normalized:=normalized-array['entity_version','source_revision','updated_at'];
    digest:=encode(sha256(convert_to(normalized::text,'UTF8')),'hex');
    select * into prior from nohut_private.typed_record_versions v where v.restaurant_id=p_restaurant
      and v.category='finance' and v.table_name=tab and v.record_key=pk for update;
    if found then
      if prior.body=normalized then continue; end if;
      if prior.source_revision>=p_revision then raise exception 'finance version conflict' using errcode='22023'; end if;
      if tab in ('material_purchase_history','manual_platform_sales_history') then
        raise exception 'immutable finance history changed' using errcode='22023'; end if;
      if tab='weekly_payroll' and prior.body->'paid'='true'::jsonb then
        raise exception 'paid payroll is immutable' using errcode='22023'; end if;
      if tab='fixed_expense_payments' and not(prior.body->'reversed'='true'::jsonb and normalized->'reversed'='false'::jsonb)
        and (prior.body->'amount_kurus' is distinct from normalized->'amount_kurus'
          or (normalized->'reversed'='true'::jsonb and prior.body->'paid_at' is distinct from normalized->'paid_at')) then
        raise exception 'fixed payment facts changed without reversal' using errcode='22023'; end if;
      insert into nohut_private.typed_record_history values(p_restaurant,'finance',tab,pk,prior.source_revision,prior.body,prior.body_sha256);
    else
      execute format('select to_jsonb(t) from nohut_private.%I t where to_jsonb(t) @> $1',tab) into existing_record using pk;
      if existing_record is not null and ((existing_record->>'source_revision')::bigint>p_revision
        or existing_record-array['entity_version','source_revision','updated_at'] is distinct from normalized) then
        raise exception 'existing finance destination conflict' using errcode='22023'; end if;
    end if;
    select string_agg(format('%I',k),','),string_agg(format('(jsonb_populate_record(null::nohut_private.%I,$1)).%I',tab,k),','),
      string_agg(format('%I=excluded.%I',k,k),',') into names,selectors,updates from jsonb_object_keys(data) k;
    select string_agg(format('%I',k),',') into conflicts from unnest(keys) k;
    execute format('insert into nohut_private.%I(%s) select %s on conflict(%s) do update set %s',tab,names,selectors,conflicts,updates) using data;
    insert into nohut_private.typed_record_versions values(p_restaurant,'finance',tab,pk,p_revision,normalized,digest)
      on conflict(restaurant_id,category,table_name,record_key) do update set source_revision=excluded.source_revision,
        body=excluded.body,body_sha256=excluded.body_sha256;
  end loop;
  if exists(select 1 from nohut_private.typed_record_versions v where v.restaurant_id=p_restaurant and v.category='finance'
    and not((v.table_name||':'||v.record_key::text)=any(seen))) then
    raise exception 'finance history omitted' using errcode='22023'; end if;
end $$;
revoke all on function nohut_private.apply_typed_finance(uuid,bigint,jsonb) from public,anon,authenticated,service_role;
commit;
