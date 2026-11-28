-- Extend the explicit typed ledger with immutable receipt and print event records.
begin;
create or replace function nohut_private.apply_typed_projection(p_restaurant uuid,p_revision bigint,p_category text,p_payload jsonb)
returns void language plpgsql security invoker set search_path='' set timezone='UTC' as $$
declare item jsonb; data jsonb; normalized jsonb; tab text; col record; keys text[]; pk jsonb; digest text;
  names text; selectors text; updates text; conflicts text; prior nohut_private.typed_record_versions;
  seen text[]:=array[]::text[]; identity_text text; employee uuid; stamp timestamptz; existing_record jsonb; component jsonb;
begin
  perform nohut_private.command_shape(p_payload,'{"rows":"array","source_updated_at":"string"}');
  stamp:=nohut_private.shift_timestamp(p_payload->'source_updated_at');
  if stamp is null or p_revision is null or p_revision<0 then raise exception 'invalid finance revision' using errcode='22023'; end if;
  for item in select value from jsonb_array_elements(p_payload->'rows') loop
    perform nohut_private.command_shape(item,'{"table":"string","data":"object"}','{"deleted":"boolean","removed_at":"string"}');
    tab:=item->>'table'; data:=item->'data';
    if (item ? 'deleted' or item ? 'removed_at') and (tab not in ('products','categories','campaigns','orders','guest_checks','guest_allocations','payment_guest_allocations')
      or item->'deleted' is distinct from 'true'::jsonb or nohut_private.shift_timestamp(item->'removed_at') is null) then
      raise exception 'invalid catalog tombstone' using errcode='22023'; end if;
    if not coalesce((p_category='finance' and tab in ('material_purchases','material_purchase_history','expenses','fixed_expenses',
      'fixed_expense_active_ranges','fixed_expense_amount_history','fixed_expense_payments','weekly_payroll','manual_platform_sales','manual_platform_sales_history'))
      or (p_category in ('localMenu','internalMenu') and tab in ('products','product_versions'))
      or (p_category='qrCategories' and tab in ('categories','category_versions'))
      or (p_category='qrCampaigns' and tab in ('campaigns','campaign_versions'))
      or (p_category ~ '^print:[0-9a-f-]{36}$' and tab in ('receipt_snapshots','print_jobs','print_job_events'))
      or (p_category ~ '^order:[0-9a-f-]{36}$' and tab in ('pos_tables','products','product_versions','orders','order_batches','order_items','payments','payment_refunds','guest_checks','guest_allocations','payment_guest_allocations','order_events','order_line_edits','order_voids','deleted_order_audit')),false) then
      raise exception 'unsupported typed table' using errcode='22023'; end if;
    if tab='products' and data->>'source_kind' is distinct from (case when p_category like 'order:%' then 'historical_sale' else p_category end) then
      raise exception 'catalog source mismatch' using errcode='22023'; end if;
    if tab in ('product_versions','category_versions','campaign_versions') and data->>'content_sha256' is distinct from
      encode(sha256(convert_to(nohut_private.canonical_command_json(data-array['product_id','product_version_id','category_id','category_version_id','campaign_id','campaign_version_id','content_sha256']),'UTF8')),'hex') then
      raise exception 'catalog version hash mismatch' using errcode='22023'; end if;
    if tab='receipt_snapshots' and data->>'content_sha256' is distinct from
      encode(sha256(convert_to(nohut_private.canonical_command_json(data-array['order_id','snapshot_id','content_sha256']),'UTF8')),'hex') then
      raise exception 'receipt hash mismatch' using errcode='22023'; end if;
    if tab='fixed_expense_payments' then data:=jsonb_build_object('reversed',false)||data; end if;
    if data ?| array['restaurant_id','source_revision','entity_version','updated_at','deleted_at'] then
      raise exception 'forged finance metadata' using errcode='22023'; end if;
    if tab in ('order_batches','payments') then
      if data ? 'employee_id' or not(data ? 'employee_local_id') then raise exception 'employee source identity required' using errcode='22023'; end if;
      employee:=null;
      if data->'employee_local_id'<>'null'::jsonb then
        if jsonb_typeof(data->'employee_local_id')<>'number' or data->>'employee_local_id' !~ '^[0-9]+$' then raise exception 'invalid sale employee' using errcode='22023'; end if;
        select x.employee_id into employee from nohut_private.employee_source_ids x where x.restaurant_id=p_restaurant and x.local_id=(data->>'employee_local_id')::bigint;
        if not found then raise exception 'unknown sale employee' using errcode='22023'; end if;
      end if;
      data:=(data-'employee_local_id')||jsonb_build_object('employee_id',employee);
    end if;
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
      elsif col.atttypid='jsonb'::regtype then
        if tab='campaign_versions' and col.attname='items' then
          if jsonb_typeof(data->col.attname)<>'array' or jsonb_array_length(data->col.attname)>100 then raise exception 'invalid campaign items' using errcode='22023'; end if;
          for component in select value from jsonb_array_elements(data->col.attname) loop
            perform nohut_private.command_shape(component,'{}','{"tr":"nullable_string","en":"nullable_string","ar":"nullable_string"}');
          end loop;
        elsif (tab='order_items' and col.attname='customizations') or (tab='order_line_edits' and col.attname='before_customizations') then
          perform nohut_private.validate_sale_customizations(data->col.attname);
        else raise exception 'unsupported typed JSON' using errcode='22023'; end if;
      elsif col.atttypid='int8[]'::regtype then
        if jsonb_typeof(data->col.attname)<>'array' then raise exception 'finance amounts array required' using errcode='22023'; end if;
        if exists(select 1 from jsonb_array_elements(data->col.attname) v where jsonb_typeof(v)<>'number'
          or v::text !~ '^[0-9]+$' or (v::text)::numeric>9007199254740991) then raise exception 'invalid finance amounts' using errcode='22023'; end if;
      elsif col.atttypid not in ('bool'::regtype) and (jsonb_typeof(data->col.attname)<>'string' or length(data->>col.attname)>case when tab='receipt_snapshots' and col.attname='body' then 65536 else 1000 end) then
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
      'source_revision',p_revision,'updated_at',stamp,'deleted_at',case when item->'deleted'='true'::jsonb
        then nohut_private.shift_timestamp(item->'removed_at') else null end);
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
      and v.category=p_category and v.table_name=tab and v.record_key=pk for update;
    if found then
      if prior.body=normalized then continue; end if;
      if prior.source_revision>=p_revision then raise exception 'finance version conflict' using errcode='22023'; end if;
      if tab in ('material_purchase_history','manual_platform_sales_history','product_versions','category_versions','campaign_versions','order_events','order_line_edits','order_voids','payment_refunds','deleted_order_audit','receipt_snapshots','print_job_events') then
        raise exception 'immutable finance history changed' using errcode='22023'; end if;
      if tab='print_jobs' and prior.body-array['status','attempts','spooled_at'] is distinct from normalized-array['status','attempts','spooled_at'] then
        raise exception 'print identity or snapshot changed' using errcode='22023'; end if;
      if tab='payments' and (prior.body-array['net_kurus','reversed','local_guest_id'] is distinct from normalized-array['net_kurus','reversed','local_guest_id']) then
        raise exception 'payment facts changed' using errcode='22023'; end if;
      if tab='order_items' and (prior.body->'original_qty' is distinct from normalized->'original_qty') then
        raise exception 'original sale quantity changed' using errcode='22023'; end if;
      if tab='weekly_payroll' and prior.body->'paid'='true'::jsonb then
        raise exception 'paid payroll is immutable' using errcode='22023'; end if;
      if tab='fixed_expense_payments' and not(prior.body->'reversed'='true'::jsonb and normalized->'reversed'='false'::jsonb)
        and (prior.body->'amount_kurus' is distinct from normalized->'amount_kurus'
          or (normalized->'reversed'='true'::jsonb and prior.body->'paid_at' is distinct from normalized->'paid_at')) then
        raise exception 'fixed payment facts changed without reversal' using errcode='22023'; end if;
      insert into nohut_private.typed_record_history values(p_restaurant,p_category,tab,pk,prior.source_revision,prior.body,prior.body_sha256);
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
    insert into nohut_private.typed_record_versions values(p_restaurant,p_category,tab,pk,p_revision,normalized,digest)
      on conflict(restaurant_id,category,table_name,record_key) do update set source_revision=excluded.source_revision,
        body=excluded.body,body_sha256=excluded.body_sha256;
  end loop;
  if exists(select 1 from nohut_private.typed_record_versions v where v.restaurant_id=p_restaurant and v.category=p_category
    and v.table_name not in ('product_versions','category_versions','campaign_versions','pos_tables')
    and not((v.table_name||':'||v.record_key::text)=any(seen))) then
    raise exception 'finance history omitted' using errcode='22023'; end if;
end $$;
commit;
