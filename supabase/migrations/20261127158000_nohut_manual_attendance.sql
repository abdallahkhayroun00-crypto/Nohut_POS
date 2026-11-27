begin;
alter table nohut_private.shifts drop constraint shifts_source_check;
alter table nohut_private.shifts add constraint shifts_source_check check(source in ('pos','remote','manual'));
alter table nohut_private.shifts
  add column break_minutes integer not null default 0 check(break_minutes between 0 and 600),
  add column note text not null default '',
  add column created_at timestamptz,
  add column local_updated_at timestamptz,
  add column voided boolean not null default false,
  add column voided_at timestamptz,
  add column void_reason text,
  add constraint shift_void_facts check(not voided or (voided_at is not null and length(trim(void_reason))>0)),
  add constraint manual_shift_span check(source<>'manual' or (ended_at is not null and ended_at>started_at
    and ended_at-started_at<=interval '16 hours' and break_minutes<extract(epoch from ended_at-started_at)/60));
alter table nohut_private.shift_corrections
  add column before_break_minutes integer not null default 0 check(before_break_minutes between 0 and 600),
  add column after_break_minutes integer not null default 0 check(after_break_minutes between 0 and 600);
create function nohut_private.shift_break(v jsonb) returns integer
language plpgsql immutable set search_path='' as $$
begin
  if v is null then return 0; end if;
  if jsonb_typeof(v) is distinct from 'number' or v#>>'{}' !~ '^[0-9]+$'
    or (v#>>'{}')::numeric>600 then raise exception 'invalid break minutes' using errcode='22023'; end if;
  return (v#>>'{}')::integer;
end $$;
revoke all on function nohut_private.shift_break(jsonb) from public,anon,authenticated,service_role;
commit;
