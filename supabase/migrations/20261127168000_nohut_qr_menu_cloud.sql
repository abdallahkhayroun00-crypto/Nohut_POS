-- Increment B (QR Menu Management — Cloud Integration):
-- 1. Idempotent menu.* role parity for Personel, Müdür and Yönetici (owner decision #7226936601 / QA-18).
--    Matches Claude's 20261127221000_nohut_menu_parity.sql so both merge cleanly with zero drift.
-- 2. Private projection table nohut_private.qr_menu_state (FORCE RLS, zero direct client grants,
--    strict secret-key rejection so GitHub tokens / publisher keys can never enter the cloud).
-- 3. Atomic sync ingest support for entity_type = 'qrMenuState', entity_id = 'core'.
-- 4. JWT-authenticated public.nohut_qr_menu_view RPC matching Claude's #7228113217 contract + syncMeta.
begin;

-- 1. Idempotent menu.* role parity (only menu.* operations change).
update nohut_private.operation_catalogue
   set default_roles = case when operation_id = 'menu.view'
                            then array['Personel','Müdür','Yönetici','Muhasebe']::text[]
                            else array['Personel','Müdür','Yönetici']::text[] end
 where section = 'menu' and operation_id like 'menu.%';

with added as (
  insert into nohut_private.user_grants(user_id, operation_id, granted_by)
  select u.user_id, c.operation_id, null
    from nohut_private.app_users u
    join nohut_private.operation_catalogue c
      on c.section = 'menu' and u.role_template = any(c.default_roles)
   where u.active and not u.is_owner and c.sensitivity <> 'ownerOnly'
  on conflict (user_id, operation_id) do nothing
  returning user_id, operation_id
), per_user as (
  select a.user_id, array_agg(a.operation_id order by a.operation_id) ops
    from added a group by a.user_id
), bumped as (
  update nohut_private.app_users u
     set permission_version = u.permission_version + 1
    from per_user p
   where u.user_id = p.user_id
  returning u.user_id, u.restaurant_id
)
insert into nohut_private.security_audit(restaurant_id, actor_user_id, action, target_user_id, detail)
select b.restaurant_id, null, 'grant_added', b.user_id,
       jsonb_build_object('operations', to_jsonb(p.ops), 'reason', 'menu_parity_2026_11_27')
  from bumped b join per_user p using (user_id);

-- 2. Private QR menu state projection (Windows-authoritative draft + published diff + audit).
create table nohut_private.qr_menu_state (
  restaurant_id uuid primary key references nohut_private.restaurants,
  available boolean not null default false,
  draft_stamp text check (draft_stamp is null or draft_stamp ~ '^[0-9a-f]{16}$'),
  revision text check (revision is null or length(revision) <= 120),
  revision_label text check (revision_label is null or length(revision_label) <= 120),
  offline boolean not null default true,
  pending_publish boolean not null default false,
  link_status text check (link_status is null or link_status in ('ready', 'no_key', 'service_down')),
  changes jsonb not null default '[]'::jsonb check (jsonb_typeof(changes) = 'array'),
  catalog jsonb not null default '{"categories":[],"products":[],"campaigns":[]}'::jsonb
    check (jsonb_typeof(catalog) = 'object'),
  recent_audit jsonb not null default '[]'::jsonb
    check (jsonb_typeof(recent_audit) = 'array' and jsonb_array_length(recent_audit) <= 100),
  source_revision bigint not null check (source_revision > 0),
  calculated_at timestamptz not null,
  updated_at timestamptz not null default now(),
  check ((not available) or draft_stamp is not null)
);

alter table nohut_private.qr_menu_state enable row level security;
alter table nohut_private.qr_menu_state force row level security;
do $$ begin
  execute format(
    'create policy qr_menu_state_owner on nohut_private.qr_menu_state for all to %I using(true) with check(true)',
    current_user
  );
end $$;
revoke all on table nohut_private.qr_menu_state from public, anon, authenticated, service_role;

-- Defense-in-depth recursive check that no credential/token key ever enters cloud QR state or commands.
create function nohut_private.contains_forbidden_secret_key(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  with recursive walk(val) as (
    select p
    union all
    select case jsonb_typeof(w.val)
      when 'object' then e.value
      when 'array' then a.value
      else null
    end
    from walk w
    left join lateral jsonb_each(case when jsonb_typeof(w.val) = 'object' then w.val else '{}'::jsonb end) e on true
    left join lateral jsonb_array_elements(case when jsonb_typeof(w.val) = 'array' then w.val else '[]'::jsonb end) a on true
    where w.val is not null and jsonb_typeof(w.val) in ('object', 'array')
  ), keys as (
    select lower(k) as k
    from walk w, lateral jsonb_object_keys(case when jsonb_typeof(w.val) = 'object' then w.val else '{}'::jsonb end) k
  )
  select exists(
    select 1 from keys
    where k in (
      'token', 'githubtoken', 'github_token', 'publisherkey', 'publisher_key',
      'apikey', 'api_key', 'secret', 'password', 'authorization', 'cookie', 'bearer'
    )
  );
$$;
revoke all on function nohut_private.contains_forbidden_secret_key(jsonb)
  from public, anon, authenticated, service_role;

create function nohut_private.apply_qr_menu_projection(
  p_restaurant uuid,
  p_revision bigint,
  p_payload jsonb
) returns void language plpgsql security invoker set search_path = pg_catalog, nohut_private as $$
declare
  avail boolean;
  stamp text;
  rev text;
  rev_label text;
  is_off boolean;
  pend boolean;
  lnk text;
  chg jsonb;
  cat jsonb;
  aud jsonb;
  calc timestamptz;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'invalid qr menu payload' using errcode = '22023';
  end if;
  if nohut_private.contains_forbidden_secret_key(p_payload) then
    raise exception 'credentials forbidden in cloud qr menu' using errcode = '42501';
  end if;
  if jsonb_typeof(p_payload->'available') is distinct from 'boolean' then
    raise exception 'available boolean required' using errcode = '22023';
  end if;
  avail := (p_payload->>'available')::boolean;
  calc := coalesce(nullif(p_payload->>'calculated_at', '')::timestamptz, clock_timestamp());
  stamp := nullif(p_payload->>'stamp', '');
  rev := nullif(p_payload->>'revision', '');
  rev_label := nullif(p_payload->>'revisionLabel', '');
  is_off := coalesce((p_payload->>'offline')::boolean, rev is null);
  pend := coalesce((p_payload->>'pendingPublish')::boolean, false);
  lnk := nullif(p_payload->>'link', '');
  chg := coalesce(p_payload->'changes', '[]'::jsonb);
  cat := coalesce(p_payload->'catalog', '{"categories":[],"products":[],"campaigns":[]}'::jsonb);
  aud := coalesce(p_payload->'recentAudit', '[]'::jsonb);

  if avail and (stamp is null or stamp !~ '^[0-9a-f]{16}$') then
    raise exception 'valid draft stamp required' using errcode = '22023';
  end if;
  if lnk is not null and lnk not in ('ready', 'no_key', 'service_down') then
    raise exception 'invalid link status' using errcode = '22023';
  end if;
  if jsonb_typeof(chg) <> 'array' or jsonb_typeof(cat) <> 'object' or jsonb_typeof(aud) <> 'array' then
    raise exception 'invalid qr menu structure' using errcode = '22023';
  end if;
  if jsonb_array_length(aud) > 100 then
    raise exception 'qr menu audit slice too large' using errcode = '22023';
  end if;
  if avail and (
    jsonb_typeof(cat->'categories') <> 'array'
    or jsonb_typeof(cat->'products') <> 'array'
    or jsonb_typeof(cat->'campaigns') <> 'array'
  ) then
    raise exception 'qr menu catalog lists required' using errcode = '22023';
  end if;

  insert into nohut_private.qr_menu_state(
    restaurant_id, available, draft_stamp, revision, revision_label,
    offline, pending_publish, link_status, changes, catalog, recent_audit,
    source_revision, calculated_at, updated_at
  ) values (
    p_restaurant, avail, stamp, rev, rev_label,
    is_off, pend, lnk, chg, cat, aud,
    p_revision, calc, clock_timestamp()
  )
  on conflict (restaurant_id) do update set
    available = excluded.available,
    draft_stamp = excluded.draft_stamp,
    revision = excluded.revision,
    revision_label = excluded.revision_label,
    offline = excluded.offline,
    pending_publish = excluded.pending_publish,
    link_status = excluded.link_status,
    changes = excluded.changes,
    catalog = excluded.catalog,
    recent_audit = excluded.recent_audit,
    source_revision = excluded.source_revision,
    calculated_at = excluded.calculated_at,
    updated_at = clock_timestamp()
  where nohut_private.qr_menu_state.source_revision <= excluded.source_revision;
end $$;
revoke all on function nohut_private.apply_qr_menu_projection(uuid, bigint, jsonb)
  from public, anon, authenticated, service_role;

-- 3. Extend atomic sync ingest to accept qrMenuState alongside all prior typed projections.
create or replace function nohut_private.ingest_sync_transaction(p_restaurant uuid, p_epoch uuid, p_tx jsonb)
returns jsonb language plpgsql security invoker set search_path = pg_catalog, nohut_private
as $$
declare cp nohut_private.sync_checkpoints%rowtype; old_tx nohut_private.sync_transactions%rowtype;
  rev bigint; fst bigint; lst bigint; n integer; tid uuid; ev jsonb;
begin
  perform nohut_private.validate_sync_transaction(p_epoch, p_tx);
  perform 1 from nohut_private.authority_epochs a where a.restaurant_id = p_restaurant
    and a.authority_epoch = p_epoch and a.retired_at is null for share;
  if not found then raise exception 'inactive authority' using errcode = '42501'; end if;
  perform 1 from nohut_private.sync_migrations m where m.restaurant_id = p_restaurant
    and m.authority_epoch = p_epoch and m.status = 'active' for share;
  if not found then raise exception 'migration not active' using errcode = '42501'; end if;
  select * into cp from nohut_private.sync_checkpoints c where c.restaurant_id = p_restaurant
    and c.authority_epoch = p_epoch for update;
  if not found then raise exception 'checkpoint not provisioned' using errcode = '42501'; end if;
  rev := (p_tx->>'source_revision')::bigint; fst := (p_tx->>'first_seq')::bigint;
  lst := (p_tx->>'last_seq')::bigint; n := (p_tx->>'event_count')::integer; tid := (p_tx->>'tx_id')::uuid;
  select * into old_tx from nohut_private.sync_transactions t
    where t.restaurant_id = p_restaurant and t.authority_epoch = p_epoch and t.tx_id = tid;
  if found then
    if old_tx.source_revision <> rev or old_tx.first_seq <> fst or old_tx.last_seq <> lst
       or old_tx.event_count <> n or old_tx.body_sha256 <> p_tx->>'body_sha256'
       or cp.last_acked_seq < lst
       or (select count(*) from nohut_private.sync_event_ids i where i.restaurant_id = p_restaurant
          and i.authority_epoch = p_epoch and i.tx_id = tid) <> n
       or exists(select 1 from jsonb_array_elements(p_tx->'events') v(ev)
         where not exists(select 1 from nohut_private.sync_event_ids i
          where i.restaurant_id = p_restaurant and i.authority_epoch = p_epoch and i.tx_id = tid
          and i.event_id = v.ev->>'event_id' and i.event_ordinal = (v.ev->>'event_ordinal')::integer
          and i.seq = (v.ev->>'seq')::bigint and i.entity_type = v.ev->>'entity_type'
          and i.entity_id = v.ev->>'entity_id' and i.op = v.ev->>'op'
          and i.body_sha256 = v.ev->>'body_sha256')) then
      return jsonb_build_object('status', 'conflict', 'acked_through_seq', cp.last_acked_seq);
    end if;
    return jsonb_build_object('status', 'duplicate', 'acked_through_seq', cp.last_acked_seq);
  end if;
  if fst > cp.last_acked_seq + 1 then
    return jsonb_build_object('status', 'gap', 'acked_through_seq', cp.last_acked_seq);
  end if;
  if fst <> cp.last_acked_seq + 1 or rev <= cp.last_acked_revision then
    return jsonb_build_object('status', 'conflict', 'acked_through_seq', cp.last_acked_seq);
  end if;
  if exists(select 1 from jsonb_array_elements(p_tx->'events') v(ev)
    where not((v.ev->>'entity_type' in ('employees','shifts','timesheetWeeks','shiftPlans','typed_finance','workforceSummaries','qrMenuState') and v.ev->>'entity_id' = 'core')
      or (v.ev->>'entity_type' = 'typed_catalog' and v.ev->>'entity_id' in ('localMenu','internalMenu','qrCategories','qrCampaigns'))
      or (v.ev->>'entity_type' in ('typed_print','typed_platform'))
      or (v.ev->>'entity_type' = 'typed_ledger' and v.ev->>'entity_id' in ('combinedPayments','terminalAttempts','cashBook'))
      or (v.ev->>'entity_type' in ('typed_order','order_archive_marker') and v.ev->>'entity_id' ~ '^[0-9]+$'))
      or v.ev->>'op' <> 'upsert')
    or (select count(distinct (v.ev->>'entity_type', v.ev->>'entity_id')) from jsonb_array_elements(p_tx->'events') v(ev)) <> n then
    raise exception 'typed projection not supported yet' using errcode = '22023';
  end if;
  if exists(select 1 from jsonb_array_elements(p_tx->'events') marker where marker->>'entity_type' = 'order_archive_marker'
    and (marker->'payload' is distinct from jsonb_build_object('local_order_id', marker->>'entity_id', 'archive_required', true)
      or not exists(select 1 from jsonb_array_elements(p_tx->'events') archive where archive->>'entity_type' = 'typed_order'
        and archive->>'entity_id' = marker->>'entity_id' and archive->'payload'->'counts'->'deleted_order_audit' = '1'::jsonb))) then
    raise exception 'order deletion without full archive' using errcode = '22023'; end if;
  for ev in select value from jsonb_array_elements(p_tx->'events') order by case value->>'entity_type'
    when 'employees' then 0 when 'typed_catalog' then 10 when 'shiftPlans' then 15 when 'shifts' then 20
    when 'timesheetWeeks' then 25 when 'typed_order' then 30 when 'typed_platform' then 40 when 'typed_print' then 50
    when 'typed_finance' then 60 when 'typed_ledger' then 70 when 'workforceSummaries' then 80
    when 'qrMenuState' then 85 else 90 end loop
    case ev->>'entity_type'
      when 'employees' then perform nohut_private.apply_employee_projection(p_restaurant, rev, ev->'payload');
      when 'typed_catalog' then perform nohut_private.apply_typed_projection(p_restaurant, rev, ev->>'entity_id', ev->'payload');
      when 'typed_finance' then perform nohut_private.apply_typed_finance(p_restaurant, rev, ev->'payload');
      when 'typed_ledger' then perform nohut_private.apply_typed_ledger(p_restaurant, rev, ev->>'entity_id', ev->'payload');
      when 'typed_platform' then perform nohut_private.apply_typed_platform(p_restaurant, rev, ev->>'entity_id', ev->'payload');
      when 'typed_print' then perform nohut_private.apply_typed_print(p_restaurant, rev, ev->>'entity_id', ev->'payload');
      when 'typed_order' then perform nohut_private.apply_typed_order(p_restaurant, rev, ev->>'entity_id', ev->'payload');
      when 'order_archive_marker' then null;
      when 'shifts' then perform nohut_private.apply_shift_projection(p_restaurant, rev, ev->'payload');
      when 'timesheetWeeks' then perform nohut_private.apply_timesheet_projection(p_restaurant, rev, ev->'payload');
      when 'shiftPlans' then perform nohut_private.apply_plan_projection(p_restaurant, rev, ev->'payload');
      when 'workforceSummaries' then perform nohut_private.apply_workforce_summary_projection(p_restaurant, rev, ev->'payload');
      when 'qrMenuState' then perform nohut_private.apply_qr_menu_projection(p_restaurant, rev, ev->'payload');
    end case;
  end loop;
  insert into nohut_private.sync_transactions(restaurant_id, authority_epoch, tx_id, source_revision, first_seq, last_seq, event_count, schema_version, body_sha256)
    values(p_restaurant, p_epoch, tid, rev, fst, lst, n, 1, p_tx->>'body_sha256');
  insert into nohut_private.sync_event_ids(restaurant_id, authority_epoch, tx_id, event_id, event_ordinal, seq, entity_type, entity_id, op, body_sha256)
    select p_restaurant, p_epoch, tid, v.ev->>'event_id', (v.ev->>'event_ordinal')::integer, (v.ev->>'seq')::bigint,
      v.ev->>'entity_type', v.ev->>'entity_id', v.ev->>'op', v.ev->>'body_sha256'
    from jsonb_array_elements(p_tx->'events') v(ev);
  update nohut_private.sync_checkpoints c set last_acked_seq = lst, last_acked_revision = rev, updated_at = clock_timestamp()
    where c.restaurant_id = p_restaurant and c.authority_epoch = p_epoch;
  return jsonb_build_object('status', 'accepted', 'acked_through_seq', lst);
end $$;

-- 4. Authenticated QR menu cloud read RPC matching Claude's #7228113217 contract.
create function public.nohut_qr_menu_view(
  p_device_id uuid,
  p_client text,
  p_permission_version bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  sid uuid := public.nohut_jwt_claim('session_id')::uuid;
  u nohut_private.app_users;
  q nohut_private.qr_menu_state;
  can_map jsonb;
  fresh jsonb;
  out_obj jsonb;
begin
  if nohut_private.authorize(uid, sid, p_device_id, p_client, 'menu.view', p_permission_version) is distinct from 'ok' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into u from nohut_private.app_users where user_id = uid;
  if not found then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  can_map := jsonb_build_object(
    'menu.product.edit', nohut_private.authorize(uid, sid, p_device_id, p_client, 'menu.product.edit', p_permission_version) = 'ok',
    'menu.price.edit', nohut_private.authorize(uid, sid, p_device_id, p_client, 'menu.price.edit', p_permission_version) = 'ok',
    'menu.category.edit', nohut_private.authorize(uid, sid, p_device_id, p_client, 'menu.category.edit', p_permission_version) = 'ok',
    'menu.campaign.edit', nohut_private.authorize(uid, sid, p_device_id, p_client, 'menu.campaign.edit', p_permission_version) = 'ok',
    'menu.stock.toggle', nohut_private.authorize(uid, sid, p_device_id, p_client, 'menu.stock.toggle', p_permission_version) = 'ok',
    'menu.qr.publish', nohut_private.authorize(uid, sid, p_device_id, p_client, 'menu.qr.publish', p_permission_version) = 'ok'
  );

  select * into q from nohut_private.qr_menu_state where restaurant_id = u.restaurant_id;
  fresh := nohut_private.sync_freshness(u.restaurant_id, q.source_revision, q.calculated_at);

  if not found or not q.available then
    return jsonb_build_object(
      'available', false,
      'can', can_map,
      'message', 'Menü henüz Windows’ta yüklenmedi. Windows › QR Menü Yönetimi sayfasını açıp GitHub’a bağlanınca burada görünür.',
      'syncMeta', fresh
    );
  end if;

  out_obj := jsonb_build_object(
    'available', true,
    'stamp', q.draft_stamp,
    'revision', q.revision,
    'revisionLabel', q.revision_label,
    'offline', q.offline,
    'pendingPublish', q.pending_publish,
    'can', can_map,
    'publish', case when q.link_status is null then 'windows' else 'here' end,
    'changes', q.changes,
    'catalog', q.catalog,
    'recentAudit', q.recent_audit,
    'syncMeta', fresh
  );
  if q.link_status is not null then
    out_obj := out_obj || jsonb_build_object('link', q.link_status);
  end if;
  return out_obj;
end $$;

revoke all on function public.nohut_qr_menu_view(uuid, text, bigint)
  from public, anon, authenticated, service_role;
grant execute on function public.nohut_qr_menu_view(uuid, text, bigint) to authenticated;

commit;
