\set ON_ERROR_STOP on
begin;
do $$
declare r uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); v1 uuid:=gen_random_uuid(); v2 uuid:=gen_random_uuid();
  definition jsonb; payload jsonb; changed jsonb; bad jsonb; tombstone jsonb;
begin
  insert into nohut_private.restaurants(restaurant_id) values(r);
  definition:='{"label_tr":"Synthetic category","label_en":null,"label_ar":"فئة","description_tr":null,"description_en":null,"description_ar":null,"active":true,"sort_order":1}';
  payload:=jsonb_build_object('source_updated_at','2026-11-27T12:00:00Z','rows',jsonb_build_array(
    jsonb_build_object('table','categories','data',jsonb_build_object('category_id',c,'local_key','synthetic-category','current_version_id',v1)),
    jsonb_build_object('table','category_versions','data',definition||jsonb_build_object('category_id',c,'category_version_id',v1,
      'content_sha256',nohut_private.command_envelope_sha256(definition)))));
  perform nohut_private.apply_typed_projection(r,1,'qrCategories',payload);
  set constraints all immediate;
  set constraints all deferred;
  definition:=jsonb_set(definition,'{label_tr}','"Synthetic renamed category"');
  changed:=jsonb_set(payload,'{rows,0,data,current_version_id}',to_jsonb(v2));
  changed:=jsonb_set(changed,'{rows,1,data}',definition||jsonb_build_object('category_id',c,'category_version_id',v2,
    'content_sha256',nohut_private.command_envelope_sha256(definition)));
  perform nohut_private.apply_typed_projection(r,2,'qrCategories',changed);
  perform nohut_private.apply_typed_projection(r,2,'qrCategories',changed);
  set constraints all immediate;
  set constraints all deferred;
  if (select count(*) from nohut_private.category_versions where restaurant_id=r)<>2
    or (select label_tr from nohut_private.category_versions where restaurant_id=r and category_version_id=v1)<>'Synthetic category' then
    raise exception 'historical catalog label changed'; end if;
  foreach bad in array array[
    jsonb_set(changed,'{rows,1,data,label_tr}','"Tampered without hash"'),
    jsonb_set(changed,'{rows,1,data,customer_phone}','"synthetic"'),
    jsonb_set(changed,'{rows,0,data,restaurant_id}',to_jsonb(gen_random_uuid())),
    jsonb_set(changed,'{rows}',jsonb_build_array(changed->'rows'->1))
  ] loop
    begin perform nohut_private.apply_typed_projection(r,3,'qrCategories',bad); raise exception 'invalid catalog accepted';
      exception when invalid_parameter_value then null; end;
  end loop;
  -- A recomputed hash still cannot rewrite an already allocated version.
  definition:=jsonb_set(definition,'{label_tr}','"Synthetic forbidden rewrite"');
  bad:=jsonb_set(changed,'{rows,1,data}',definition||jsonb_build_object('category_id',c,'category_version_id',v2,
    'content_sha256',nohut_private.command_envelope_sha256(definition)));
  begin perform nohut_private.apply_typed_projection(r,3,'qrCategories',bad); raise exception 'immutable catalog version rewritten';
    exception when invalid_parameter_value then null; end;
  tombstone:=jsonb_set(changed,'{rows,0}',(changed->'rows'->0)||'{"deleted":true,"removed_at":"2026-11-27T13:00:00Z"}');
  perform nohut_private.apply_typed_projection(r,3,'qrCategories',tombstone);
  if not exists(select 1 from nohut_private.categories where restaurant_id=r and deleted_at is not null) then raise exception 'catalog tombstone missing'; end if;
  perform nohut_private.apply_typed_projection(r,4,'qrCategories',changed);
  if not exists(select 1 from nohut_private.categories where restaurant_id=r and deleted_at is null)
    or (select count(*) from nohut_private.category_versions where restaurant_id=r)<>2 then raise exception 'catalog reactivation lost history'; end if;
  begin perform nohut_private.apply_typed_projection(r,5,'finance',changed); raise exception 'cross-domain catalog write';
    exception when invalid_parameter_value then null; end;
end $$;
rollback;
