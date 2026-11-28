-- G1 Hızlı Gider for staff (§24.8): new operation `expenses.quick_add`,
-- mirrored from docs/contracts/v1/permissions.json. Catalogue row only: no
-- existing user receives it here. The owner grants it per person, and new
-- Müdür/Yönetici accounts get it from their template. Idempotent, so the same
-- row arriving from the backend branch (#46) does not conflict.
begin;

insert into nohut_private.operation_catalogue(operation_id, section, sensitivity, clients, default_roles) values
  ('expenses.quick_add', 'finance', 'normal', array['windows','personel','yonetici']::text[], array['Müdür','Yönetici']::text[])
on conflict (operation_id) do nothing;

commit;
