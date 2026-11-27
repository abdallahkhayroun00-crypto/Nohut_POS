\set ON_ERROR_STOP on
begin;
do $$
declare a jsonb:='{"z":[true,null,3],"a":{"ö":"Türkçe","b":1250},"n":-2}'; b text;
begin
  b:=nohut_private.canonical_command_json(a);
  if b<>'{"a":{"b":1250,"ö":"Türkçe"},"n":-2,"z":[true,null,3]}' then raise exception 'canonical mismatch: %',b; end if;
  if nohut_private.canonical_command_json('{"b":1,"a":2}')<>nohut_private.canonical_command_json('{"a":2,"b":1}') then raise exception 'key order mismatch'; end if;
  if nohut_private.canonical_command_json('{"x":[]}')<>'{"x":[]}' or nohut_private.canonical_command_json('{}')<>'{}' then raise exception 'empty collection mismatch'; end if;
  begin perform nohut_private.canonical_command_json('{"x":1.1}'); raise exception 'fraction accepted'; exception when invalid_parameter_value then null; end;
  begin perform nohut_private.canonical_command_json('{"x":9007199254740992}'); raise exception 'unsafe integer accepted'; exception when invalid_parameter_value then null; end;
  if has_function_privilege('authenticated','nohut_private.canonical_command_json(jsonb)','EXECUTE') then raise exception 'client grant leaked'; end if;
end $$;
rollback;
