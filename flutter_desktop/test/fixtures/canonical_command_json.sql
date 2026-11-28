-- Copied verbatim from PR #46 (a77b072) supabase/migrations/20261127124000_nohut_authorized_enqueue.sql
-- for the Windows first-sync parity test. Keep identical to the server.
create schema if not exists nohut_private;
create or replace function nohut_private.canonical_command_json(p jsonb)
returns text language plpgsql immutable security invoker set search_path=pg_catalog,nohut_private
as $$
declare typ text:=jsonb_typeof(p); out_text text;
begin
  case typ
    when 'object' then
      if exists(select 1 from jsonb_object_keys(p) k(key)
        where octet_length(k.key)<>length(k.key) and exists(
          select 1 from generate_series(1,length(k.key)) i
          where ascii(substr(k.key,i,1))>65535)) then
        raise exception 'unsupported object key' using errcode='22023';
      end if;
      select '{'||coalesce(string_agg(to_jsonb(k.key)::text||':'||
        nohut_private.canonical_command_json(k.value),',' order by k.key collate "C"),'')||'}'
        into out_text from jsonb_each(p) k;
      return out_text;
    when 'array' then
      select '['||coalesce(string_agg(nohut_private.canonical_command_json(x.value),',' order by x.ord),'')||']'
        into out_text from jsonb_array_elements(p) with ordinality x(value,ord);
      return out_text;
    when 'number' then
      if p::text !~ '^-?(0|[1-9][0-9]*)$'
        or (p::text)::numeric not between -9007199254740991 and 9007199254740991 then
        raise exception 'only safe integer command numbers are supported' using errcode='22023';
      end if;
      return p::text;
    when 'string' then return p::text;
    when 'boolean' then return p::text;
    when 'null' then return 'null';
    else raise exception 'invalid command JSON' using errcode='22023';
  end case;
end $$;
