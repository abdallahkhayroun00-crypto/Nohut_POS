begin;
create function nohut_private.plan_facts(p jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare a integer; b integer; span integer; d date;
begin
  perform nohut_private.command_shape(p,'{"date":"string","start":"string","end":"string","endsNextDay":"boolean","dayOff":"boolean","breakMinutes":"integer","note":"string"}');
  if p->>'date' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or p->>'start' !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
    or p->>'end' !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or length(p->>'note')>200 then
    raise exception 'invalid planned shift values' using errcode='22023'; end if;
  d:=(p->>'date')::date;
  a:=split_part(p->>'start',':',1)::integer*60+split_part(p->>'start',':',2)::integer;
  b:=split_part(p->>'end',':',1)::integer*60+split_part(p->>'end',':',2)::integer;
  span:=b-a+case when (p->>'endsNextDay')::boolean then 1440 else 0 end;
  if (p->>'dayOff')::boolean then
    if a<>0 or b<>0 or (p->>'endsNextDay')::boolean or (p->>'breakMinutes')::integer<>0 then raise exception 'invalid day off' using errcode='22023'; end if;
  elsif (p->>'endsNextDay')::boolean is distinct from (b<=a) or span not between 1 and 960
    or (p->>'breakMinutes')::integer not between 0 and 600 or (p->>'breakMinutes')::integer>=span then
    raise exception 'invalid planned interval' using errcode='22023';
  end if;
  return jsonb_build_object('planned_day',d,'start_minute',a,'end_minute',b,'ends_next_day',(p->>'endsNextDay')::boolean,
    'day_off',(p->>'dayOff')::boolean,'break_minutes',(p->>'breakMinutes')::integer,'note',p->>'note');
end $$;
create function nohut_private.apply_plan_projection(p_restaurant uuid,p_revision bigint,p_rows jsonb)
returns void language plpgsql security invoker set search_path='' as $$
declare p jsonb; h jsonb; f jsonb; bf jsonb; old_f jsonb; seen text[]:=array[]::text[]; pid text; eid uuid; aid uuid;
  created timestamptz; updated timestamptz; stamp timestamptz; count_before integer; idx integer;
  prior nohut_private.shift_plans; old_h nohut_private.shift_plan_history;
begin
  if jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'plans array required' using errcode='22023'; end if;
  for p in select value from jsonb_array_elements(p_rows) loop
    perform nohut_private.command_shape(p,'{"id":"string","employeeId":"integer","employeeName":"string","date":"string","start":"string","end":"string","endsNextDay":"boolean","dayOff":"boolean","breakMinutes":"integer","note":"string","cancelled":"boolean","createdAt":"string","createdBy":"string","updatedAt":"string","updatedBy":"string","history":"array"}');
    pid:=p->>'id';
    if length(pid) not between 1 and 160 or pid=any(seen) then raise exception 'duplicate or invalid plan identity' using errcode='22023'; end if;
    seen:=array_append(seen,pid);
    f:=nohut_private.plan_facts(p-array['id','employeeId','employeeName','cancelled','createdAt','createdBy','updatedAt','updatedBy','history']);
    select employee_id into eid from nohut_private.employee_source_ids where restaurant_id=p_restaurant and local_id=(p->>'employeeId')::bigint;
    if not found then raise exception 'unknown planned employee' using errcode='22023'; end if;
    created:=nohut_private.shift_timestamp(p->'createdAt');updated:=nohut_private.shift_timestamp(p->'updatedAt');
    if created is null or updated is null or updated<created then raise exception 'invalid plan timestamp' using errcode='22023'; end if;
    select * into prior from nohut_private.shift_plans where restaurant_id=p_restaurant and plan_id=pid;
    if found and (prior.employee_id<>eid or prior.employee_label<>p->>'employeeName' or prior.created_at<>created
      or prior.created_by_label<>p->>'createdBy' or prior.source_revision>=p_revision or updated<prior.local_updated_at
      or (prior.cancelled and not(p->>'cancelled')::boolean)) then
      raise exception 'immutable plan identity or stale revision' using errcode='22023'; end if;
    select count(*) into count_before from nohut_private.shift_plan_history where restaurant_id=p_restaurant and plan_id=pid;
    old_f:=jsonb_build_object('planned_day',prior.planned_day,'start_minute',prior.start_minute,'end_minute',prior.end_minute,
      'ends_next_day',prior.ends_next_day,'day_off',prior.day_off,'break_minutes',prior.break_minutes,'note',prior.note);
    if prior.cancelled and (f is distinct from old_f or updated<>prior.local_updated_at or p->>'updatedBy'<>prior.updated_by_label) then
      raise exception 'cancelled plan changed' using errcode='22023'; end if;
    if jsonb_array_length(p->'history')<count_before or (prior.plan_id is not null and jsonb_array_length(p->'history')=count_before
      and (old_f is distinct from f or prior.cancelled<>(p->>'cancelled')::boolean or prior.updated_by_label<>p->>'updatedBy')) then
      raise exception 'plan audit missing' using errcode='22023'; end if;
    insert into nohut_private.shift_plans values(p_restaurant,pid,eid,p->>'employeeName',(f->>'planned_day')::date,
      (f->>'start_minute')::integer,(f->>'end_minute')::integer,(f->>'ends_next_day')::boolean,(f->>'day_off')::boolean,
      (f->>'break_minutes')::integer,f->>'note',(p->>'cancelled')::boolean,created,p->>'createdBy',updated,p->>'updatedBy',p_revision)
      on conflict(restaurant_id,plan_id) do update set planned_day=excluded.planned_day,start_minute=excluded.start_minute,end_minute=excluded.end_minute,
        ends_next_day=excluded.ends_next_day,day_off=excluded.day_off,break_minutes=excluded.break_minutes,note=excluded.note,cancelled=excluded.cancelled,
        local_updated_at=excluded.local_updated_at,updated_by_label=excluded.updated_by_label,source_revision=p_revision;
    idx:=0;
    for h in select value from jsonb_array_elements(p->'history') loop
      perform nohut_private.command_shape(h,'{"at":"string","by":"string","byId":"nullable_integer","action":"string"}','{"before":"object"}');
      stamp:=nohut_private.shift_timestamp(h->'at'); aid:=null;bf:=null;
      if stamp is null or h->>'action' not in ('düzenlendi','iptal') then raise exception 'invalid plan audit' using errcode='22023'; end if;
      if h->>'byId' is not null then
        select employee_id into aid from nohut_private.employee_source_ids where restaurant_id=p_restaurant and local_id=(h->>'byId')::bigint;
        if not found then raise exception 'unknown plan actor' using errcode='22023'; end if;
      end if;
      if h->>'action'='düzenlendi' then
        bf:=nohut_private.plan_facts(h->'before');
        if idx=count_before and prior.plan_id is not null and bf is distinct from old_f then raise exception 'plan correction previous facts mismatch' using errcode='22023'; end if;
      elsif h ? 'before' then raise exception 'unexpected cancellation snapshot' using errcode='22023'; end if;
      select * into old_h from nohut_private.shift_plan_history where restaurant_id=p_restaurant and plan_id=pid and ordinal=idx;
      if found then
        if row(old_h.recorded_at,old_h.actor_employee_id,old_h.actor_label,old_h.action,old_h.before_day,old_h.before_start_minute,
          old_h.before_end_minute,old_h.before_ends_next_day,old_h.before_day_off,old_h.before_break_minutes,old_h.before_note) is distinct from
          row(stamp,aid,h->>'by',h->>'action',(bf->>'planned_day')::date,(bf->>'start_minute')::integer,(bf->>'end_minute')::integer,
            (bf->>'ends_next_day')::boolean,(bf->>'day_off')::boolean,(bf->>'break_minutes')::integer,bf->>'note') then
          raise exception 'immutable planned history changed' using errcode='22023'; end if;
      else
        insert into nohut_private.shift_plan_history values(p_restaurant,pid,idx,stamp,aid,h->>'by',h->>'action',
          (bf->>'planned_day')::date,(bf->>'start_minute')::integer,(bf->>'end_minute')::integer,
          (bf->>'ends_next_day')::boolean,(bf->>'day_off')::boolean,(bf->>'break_minutes')::integer,bf->>'note');
      end if;
      idx:=idx+1;
    end loop;
    if (p->>'cancelled')::boolean and (idx=0 or h->>'action'<>'iptal') then raise exception 'cancellation audit missing' using errcode='22023'; end if;
  end loop;
  if exists(select 1 from nohut_private.shift_plans where restaurant_id=p_restaurant and not(plan_id=any(seen))) then
    raise exception 'planned history cannot be removed' using errcode='22023'; end if;
end $$;
revoke all on function nohut_private.plan_facts(jsonb),nohut_private.apply_plan_projection(uuid,bigint,jsonb) from public,anon,authenticated,service_role;
commit;
