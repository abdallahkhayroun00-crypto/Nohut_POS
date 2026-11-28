-- QR Menü Yönetimi parity (owner decision 2026-11-27, relay 7226936601 / QA-18):
-- Personel and Yönetici (and Müdür) get every menu.* operation by default,
-- including menu.qr.publish. Only menu.* rows change; financial, employee,
-- system, backup and cloud-admin operations keep their templates.
-- Additive: role templates are updated in place, and existing active users of
-- those templates receive the missing menu.* grants once, audited. A grant the
-- owner removes later stays removed (this migration runs once).
begin;

update nohut_private.operation_catalogue
   set default_roles = case when operation_id = 'menu.view'
                            then array['Personel','Müdür','Yönetici','Muhasebe']::text[]
                            else array['Personel','Müdür','Yönetici']::text[] end
 where section = 'menu' and operation_id like 'menu.%';

with added as (
  insert into nohut_private.user_grants(user_id, operation_id, granted_by)
  select u.user_id, c.operation_id, null
    from nohut_private.app_users u
    join nohut_private.operation_catalogue c on c.section = 'menu' and u.role_template = any(c.default_roles)
   where u.active and not u.is_owner and c.sensitivity <> 'ownerOnly'
  on conflict (user_id, operation_id) do nothing
  returning user_id, operation_id
), per_user as (
  select a.user_id, array_agg(a.operation_id order by a.operation_id) ops from added a group by a.user_id
), bumped as (
  update nohut_private.app_users u set permission_version = u.permission_version + 1
    from per_user p where u.user_id = p.user_id
  returning u.user_id, u.restaurant_id
)
insert into nohut_private.security_audit(restaurant_id, actor_user_id, action, target_user_id, detail)
select b.restaurant_id, null, 'grant_added', b.user_id,
       jsonb_build_object('operations', to_jsonb(p.ops), 'reason', 'menu_parity_2026_11_27')
  from bumped b join per_user p using (user_id);

commit;
