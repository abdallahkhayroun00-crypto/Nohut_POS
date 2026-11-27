-- Task A1 follow-up (requested by ChatGPT Codex on #42/#39): a Windows
-- device binding is no longer minted by any owner aal2 JWT. It needs a
-- single-use installation approval ticket:
--   * bootstrap (no active Windows installation in the restaurant): issued
--     only through the service role (trusted setup channel: the owner's
--     Supabase console / installer provisioning), never by a phone session;
--   * approval (a further Windows installation): issued by the owner from a
--     live aal2 session on an already approved, unrevoked 'windows' device.
-- Tickets: 160-bit random, SHA-256 stored, 10-minute TTL, one use, bound to
-- the restaurant. Nothing here proves the physical OS (no UA-string proof):
-- the guarantee is "only an approved installation", not "only Windows".

create table nohut_private.windows_enrollment_tickets (
  ticket_sha256 text primary key check (ticket_sha256 ~ '^[0-9a-f]{64}$'),
  restaurant_id uuid not null references nohut_private.restaurants,
  kind text not null check (kind in ('bootstrap', 'approval')),
  issued_by uuid references nohut_private.app_users,
  issued_from_device uuid references nohut_private.devices,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  consumed_device uuid,
  check (expires_at > created_at and expires_at <= created_at + interval '10 minutes'),
  check (kind = 'bootstrap' or (issued_by is not null and issued_from_device is not null))
);
alter table nohut_private.windows_enrollment_tickets enable row level security;
alter table nohut_private.windows_enrollment_tickets force row level security;
-- Same pattern as the control plane: only the migration owner (who owns
-- the security-definer functions) may touch rows.
do $$ begin
  execute format('create policy control_plane_owner on nohut_private.windows_enrollment_tickets for all to %I using (true) with check (true)', current_user);
end $$;
revoke all on nohut_private.windows_enrollment_tickets from public, anon, authenticated;

create function nohut_private.new_windows_ticket(p_restaurant uuid, p_kind text, p_by uuid, p_device uuid)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare t text := translate(encode(extensions.gen_random_bytes(20), 'base64'), '+/=', '-_');
begin
  insert into nohut_private.windows_enrollment_tickets(ticket_sha256, restaurant_id, kind, issued_by, issued_from_device, expires_at)
  values (encode(extensions.digest(t, 'sha256'), 'hex'), p_restaurant, p_kind, p_by, p_device, now() + interval '10 minutes');
  insert into nohut_private.security_audit(restaurant_id, actor_user_id, action, detail)
  values (p_restaurant, p_by, 'windows.ticket.issue', jsonb_build_object('kind', p_kind, 'device', p_device));
  return t;
end $$;

-- Trusted setup channel only (service role). Refused while an approved
-- Windows installation exists: further ones are approved from it.
create function public.nohut_issue_windows_bootstrap(p_restaurant_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from nohut_private.devices d join nohut_private.app_users u using (user_id)
             where u.restaurant_id = p_restaurant_id and d.client = 'windows' and d.revoked_at is null) then
    raise exception 'windows_installation_exists' using errcode = '42501';
  end if;
  return nohut_private.new_windows_ticket(p_restaurant_id, 'bootstrap', null, null);
end $$;

-- Owner, aal2, live session on an approved Windows device of that owner.
create function public.nohut_issue_windows_approval(p_device_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare
  o nohut_private.app_users;
  st text;
begin
  o := nohut_private.require_owner(auth.uid(), public.nohut_jwt_claim('aal'));
  st := nohut_private.session_status(auth.uid(), public.nohut_jwt_claim('session_id')::uuid, p_device_id, 'windows');
  if st <> 'ok' then raise exception 'windows_approval_requires_windows_session' using errcode = '42501'; end if;
  return nohut_private.new_windows_ticket(o.restaurant_id, 'approval', o.user_id, p_device_id);
end $$;

-- Phones/web keep the existing function; 'windows' now needs a ticket.
create or replace function public.nohut_register_device(p_device_id uuid, p_client text, p_label text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_client is null or p_client not in ('personel', 'yonetici', 'windows') then
    raise exception 'client_not_allowed' using errcode = '42501';
  end if;
  if p_client = 'windows' then
    raise exception 'windows_enrollment_requires_approval' using errcode = '42501';
  end if;
  perform nohut_private.enroll_device(auth.uid(), p_device_id, public.nohut_jwt_claim('session_id')::uuid, p_client, p_label);
  if not exists (select 1 from nohut_private.devices
                 where device_id = p_device_id and user_id = auth.uid() and client = p_client) then
    raise exception 'device_client_mismatch' using errcode = '42501';
  end if;
end $$;

create function public.nohut_register_windows_device(p_device_id uuid, p_label text, p_ticket text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  o nohut_private.app_users;
  tk nohut_private.windows_enrollment_tickets;
begin
  begin
    o := nohut_private.require_owner(auth.uid(), public.nohut_jwt_claim('aal'));
  exception when insufficient_privilege then
    raise exception 'windows_enrollment_requires_owner_mfa' using errcode = '42501';
  end;
  if p_ticket is null or length(p_ticket) > 64 then
    raise exception 'windows_enrollment_requires_approval' using errcode = '42501';
  end if;
  update nohut_private.windows_enrollment_tickets
     set consumed_at = now(), consumed_device = p_device_id
   where ticket_sha256 = encode(extensions.digest(p_ticket, 'sha256'), 'hex')
     and restaurant_id = o.restaurant_id and consumed_at is null and expires_at > now()
  returning * into tk;
  if not found then
    raise exception 'windows_enrollment_requires_approval' using errcode = '42501';
  end if;
  perform nohut_private.enroll_device(o.user_id, p_device_id, public.nohut_jwt_claim('session_id')::uuid, 'windows', p_label);
  if not exists (select 1 from nohut_private.devices
                 where device_id = p_device_id and user_id = o.user_id and client = 'windows') then
    raise exception 'device_client_mismatch' using errcode = '42501';
  end if;
  insert into nohut_private.security_audit(restaurant_id, actor_user_id, action, detail)
  values (o.restaurant_id, o.user_id, 'windows.enroll',
          jsonb_build_object('device', p_device_id, 'kind', tk.kind, 'approved_from', tk.issued_from_device));
end $$;

revoke all on function nohut_private.new_windows_ticket(uuid, text, uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function public.nohut_issue_windows_bootstrap(uuid) from public, anon, authenticated;
grant execute on function public.nohut_issue_windows_bootstrap(uuid) to service_role;
revoke all on function public.nohut_issue_windows_approval(uuid) from public, anon;
grant execute on function public.nohut_issue_windows_approval(uuid) to authenticated;
revoke all on function public.nohut_register_windows_device(uuid, text, text) from public, anon;
grant execute on function public.nohut_register_windows_device(uuid, text, text) to authenticated;
revoke all on function public.nohut_register_device(uuid, text, text) from public, anon;
grant execute on function public.nohut_register_device(uuid, text, text) to authenticated;
