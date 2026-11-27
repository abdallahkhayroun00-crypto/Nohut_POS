begin;
create function nohut_private.apply_timesheet_projection(p_restaurant uuid,p_revision bigint,p_rows jsonb)
returns void language plpgsql security invoker set search_path='' as $$
declare w jsonb; h jsonb; entry jsonb; eid uuid; wid text; day date; submitted timestamptz;
  st timestamptz; en timestamptz; b integer; idx integer; entry_idx integer; total bigint; count_before integer; old_entries integer;
  seen text[]:=array[]::text[]; entry_seen text[]; prior nohut_private.timesheet_weeks;
  old_h nohut_private.timesheet_submissions; old_e nohut_private.timesheet_entries;
begin
  if jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'timesheet array required' using errcode='22023'; end if;
  for w in select value from jsonb_array_elements(p_rows) loop
    perform nohut_private.command_shape(w,'{"id":"string","employeeId":"integer","employeeName":"string","weekStart":"string","submittedAt":"string","noWork":"boolean","minutes":"integer","history":"array"}');
    wid:=w->>'id'; day:=(w->>'weekStart')::date; submitted:=nohut_private.shift_timestamp(w->'submittedAt');
    if wid is distinct from 'tw_'||(w->>'employeeId')||'_'||(w->>'weekStart') or extract(isodow from day)<>1
      or w->>'weekStart' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or submitted is null or (w->>'minutes')::bigint<0
      or jsonb_array_length(w->'history')=0 or wid=any(seen) then
      raise exception 'invalid timesheet identity or facts' using errcode='22023'; end if;
    seen:=array_append(seen,wid);
    select employee_id into eid from nohut_private.employee_source_ids where restaurant_id=p_restaurant and local_id=(w->>'employeeId')::bigint;
    if not found then raise exception 'unknown timesheet employee' using errcode='22023'; end if;
    select * into prior from nohut_private.timesheet_weeks where restaurant_id=p_restaurant and week_id=wid;
    if found and (prior.employee_id<>eid or prior.week_start<>day or prior.employee_label<>w->>'employeeName' or prior.source_revision>=p_revision) then
      raise exception 'timesheet identity or revision changed' using errcode='22023'; end if;
    select count(*) into count_before from nohut_private.timesheet_submissions where restaurant_id=p_restaurant and week_id=wid;
    if jsonb_array_length(w->'history')<count_before then raise exception 'submission history omitted' using errcode='22023'; end if;
    if prior.week_id is not null and jsonb_array_length(w->'history')=count_before and
      row(prior.submitted_at,prior.no_work,prior.minutes) is distinct from row(submitted,(w->>'noWork')::boolean,(w->>'minutes')::bigint) then
      raise exception 'unaudited timesheet change' using errcode='22023'; end if;
    insert into nohut_private.timesheet_weeks values(p_restaurant,wid,eid,w->>'employeeName',day,submitted,(w->>'noWork')::boolean,(w->>'minutes')::bigint,p_revision)
      on conflict(restaurant_id,week_id) do update set submitted_at=excluded.submitted_at,no_work=excluded.no_work,minutes=excluded.minutes,source_revision=p_revision;
    idx:=0;
    for h in select value from jsonb_array_elements(w->'history') loop
      perform nohut_private.command_shape(h,'{"at":"string","minutes":"integer","noWork":"boolean","entries":"array"}');
      submitted:=nohut_private.shift_timestamp(h->'at');
      if submitted is null or (h->>'minutes')::bigint<0 or ((h->>'noWork')::boolean and jsonb_array_length(h->'entries')<>0)
        or (not (h->>'noWork')::boolean and jsonb_array_length(h->'entries')=0) then
        raise exception 'invalid submission' using errcode='22023'; end if;
      select * into old_h from nohut_private.timesheet_submissions where restaurant_id=p_restaurant and week_id=wid and ordinal=idx;
      if found then
        if row(old_h.submitted_at,old_h.no_work,old_h.minutes) is distinct from row(submitted,(h->>'noWork')::boolean,(h->>'minutes')::bigint) then
          raise exception 'immutable submission changed' using errcode='22023'; end if;
        select count(*) into old_entries from nohut_private.timesheet_entries where restaurant_id=p_restaurant and week_id=wid and submission_ordinal=idx;
        if old_entries<>jsonb_array_length(h->'entries') then raise exception 'immutable submission entry set changed' using errcode='22023'; end if;
      else
        insert into nohut_private.timesheet_submissions values(p_restaurant,wid,idx,submitted,(h->>'noWork')::boolean,(h->>'minutes')::bigint);
      end if;
      total:=0; entry_idx:=0; entry_seen:=array[]::text[];
      for entry in select value from jsonb_array_elements(h->'entries') loop
        perform nohut_private.command_shape(entry,'{"id":"string","start":"string","end":"string","breakMinutes":"integer"}');
        st:=nohut_private.shift_timestamp(entry->'start'); en:=nohut_private.shift_timestamp(entry->'end'); b:=nohut_private.shift_break(entry->'breakMinutes');
        if st is null or en is null or en<st or b>floor(extract(epoch from en-st)/60)
          or (st at time zone 'Europe/Istanbul')::date<day or (st at time zone 'Europe/Istanbul')::date>=day+7
          or entry->>'id'=any(entry_seen) or not exists(select 1 from nohut_private.shifts s where s.restaurant_id=p_restaurant and s.shift_id=entry->>'id' and s.employee_id=eid
            and (row(s.started_at,s.ended_at,s.break_minutes)=row(st,en,b) or exists(
              select 1 from nohut_private.shift_corrections c where c.restaurant_id=s.restaurant_id and c.shift_id=s.shift_id
                and (row(c.before_start,c.before_end,c.before_break_minutes)=row(st,en,b)
                  or row(c.after_start,c.after_end,c.after_break_minutes)=row(st,en,b))))) then
          raise exception 'invalid submission entry' using errcode='22023'; end if;
        entry_seen:=array_append(entry_seen,entry->>'id');
        total:=total+floor(extract(epoch from en-st)/60)::bigint-b;
        select * into old_e from nohut_private.timesheet_entries where restaurant_id=p_restaurant and week_id=wid and submission_ordinal=idx and shift_id=entry->>'id';
        if found then
          if row(old_e.entry_ordinal,old_e.started_at,old_e.ended_at,old_e.break_minutes) is distinct from row(entry_idx,st,en,b) then
            raise exception 'immutable submitted entry changed' using errcode='22023'; end if;
        else
          insert into nohut_private.timesheet_entries values(p_restaurant,wid,idx,entry_idx,entry->>'id',st,en,b);
        end if;
        entry_idx:=entry_idx+1;
      end loop;
      if total<>(h->>'minutes')::bigint or exists(select 1 from nohut_private.timesheet_entries where restaurant_id=p_restaurant and week_id=wid and submission_ordinal=idx and not(shift_id=any(entry_seen))) then
        raise exception 'submission totals or retained entries mismatch' using errcode='22023'; end if;
      idx:=idx+1;
    end loop;
    if row(submitted,(h->>'noWork')::boolean,(h->>'minutes')::bigint) is distinct from row(nohut_private.shift_timestamp(w->'submittedAt'),(w->>'noWork')::boolean,(w->>'minutes')::bigint) then
      raise exception 'current week differs from last submission' using errcode='22023'; end if;
  end loop;
  if exists(select 1 from nohut_private.timesheet_weeks where restaurant_id=p_restaurant and not(week_id=any(seen))) then
    raise exception 'timesheet history removed' using errcode='22023'; end if;
end $$;
revoke all on function nohut_private.apply_timesheet_projection(uuid,bigint,jsonb) from public,anon,authenticated,service_role;
commit;
