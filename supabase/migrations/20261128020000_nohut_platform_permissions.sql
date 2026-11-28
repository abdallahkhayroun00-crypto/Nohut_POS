-- Platform Yönetimi (owner decisions #7236316817, #7236345438): operation ids
-- agreed with the backend on #51 (7236393410), mirrored from
-- docs/contracts/v1/permissions.json. Catalogue rows only: nobody receives a
-- grant here; Yönetici/Müdür templates carry the defaults for new accounts.
-- Provider command persistence and the proxy extension land separately.
-- Idempotent, so the same rows arriving from #46/#50 do not conflict.
begin;

insert into nohut_private.operation_catalogue(operation_id, section, sensitivity, clients, default_roles) values
  ('platform.view', 'platform', 'normal', array['windows','personel','yonetici']::text[], array['Müdür','Yönetici']::text[]),
  ('platform.store.toggle', 'platform', 'elevated', array['windows','personel','yonetici']::text[], array['Yönetici']::text[]),
  ('platform.schedule.edit', 'platform', 'elevated', array['windows','personel','yonetici']::text[], array['Yönetici']::text[]),
  ('platform.catalog.toggle', 'platform', 'elevated', array['windows','personel','yonetici']::text[], array['Yönetici']::text[])
on conflict (operation_id) do nothing;

commit;
