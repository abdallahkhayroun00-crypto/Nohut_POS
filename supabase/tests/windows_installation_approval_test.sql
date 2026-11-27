-- A1 follow-up: a Windows binding needs an approved installation ticket.
\set ON_ERROR_STOP on
begin;
insert into nohut_private.restaurants(restaurant_id) values ('e0000000-0000-0000-0000-0000000000b1'), ('e0000000-0000-0000-0000-0000000000b2');
insert into nohut_private.app_users(user_id, restaurant_id, username, role_template, is_owner)
values ('b1000000-0000-0000-0000-00000000000a', 'e0000000-0000-0000-0000-0000000000b1', 'sahip_b', 'Yönetici', true),
       ('b1000000-0000-0000-0000-00000000000c', 'e0000000-0000-0000-0000-0000000000b2', 'sahip_c', 'Yönetici', true);

-- 1. Owner aal2 phone JWT cannot mint a Windows binding (old or new API).
select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-00000000000a","session_id":"b2000000-0000-0000-0000-000000000001","aal":"aal2","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  begin
    perform public.nohut_register_device('b3000000-0000-0000-0000-000000000001', 'windows', 'Kasa');
    raise exception 'register_device minted windows';
  exception when insufficient_privilege then
    if sqlerrm <> 'windows_enrollment_requires_approval' then raise; end if;
  end;
  begin
    perform public.nohut_register_windows_device('b3000000-0000-0000-0000-000000000001', 'Kasa', 'guess-ticket');
    raise exception 'guessed ticket accepted';
  exception when insufficient_privilege then
    if sqlerrm <> 'windows_enrollment_requires_approval' then raise; end if;
  end;
  -- authenticated cannot issue a bootstrap ticket.
  begin
    perform public.nohut_issue_windows_bootstrap('e0000000-0000-0000-0000-0000000000b1');
    raise exception 'phone issued bootstrap';
  exception when insufficient_privilege then null;
  end;
end $$;
-- A phone ('yonetici') session cannot issue an approval ticket either.
select public.nohut_register_device('b3000000-0000-0000-0000-000000000009', 'yonetici', 'Telefon');
do $$ begin
  begin
    perform public.nohut_issue_windows_approval('b3000000-0000-0000-0000-000000000009');
    raise exception 'phone issued approval';
  exception when insufficient_privilege then
    if sqlerrm <> 'windows_approval_requires_windows_session' then raise; end if;
  end;
end $$;
reset role;

-- 2. Bootstrap via the service role; single use; other restaurant refused.
set local role service_role;
select set_config('nohut.t1', public.nohut_issue_windows_bootstrap('e0000000-0000-0000-0000-0000000000b1'), true);
select set_config('nohut.t_other', public.nohut_issue_windows_bootstrap('e0000000-0000-0000-0000-0000000000b2'), true);
reset role;
do $$ begin
  if exists (select 1 from nohut_private.windows_enrollment_tickets where ticket_sha256 = current_setting('nohut.t1')) then
    raise exception 'ticket stored in clear';
  end if;
end $$;
select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-00000000000a","session_id":"b2000000-0000-0000-0000-000000000002","aal":"aal2","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  begin
    perform public.nohut_register_windows_device('b3000000-0000-0000-0000-000000000001', 'Kasa', current_setting('nohut.t_other'));
    raise exception 'other restaurant ticket accepted';
  exception when insufficient_privilege then null;
  end;
end $$;
select public.nohut_register_windows_device('b3000000-0000-0000-0000-000000000001', 'Kasa PC', current_setting('nohut.t1'));
do $$ begin
  if public.nohut_windows_owner_session('b3000000-0000-0000-0000-000000000001')->>'status' <> 'ok' then
    raise exception 'approved installation not a windows owner session';
  end if;
end $$;
reset role;
-- Reuse refused (fresh session, other device).
select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-00000000000a","session_id":"b2000000-0000-0000-0000-000000000003","aal":"aal2","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  begin
    perform public.nohut_register_windows_device('b3000000-0000-0000-0000-000000000002', 'Kasa 2', current_setting('nohut.t1'));
    raise exception 'ticket reused';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
-- While an approved installation exists, no further bootstrap.
set local role service_role;
do $$ begin
  begin
    perform public.nohut_issue_windows_bootstrap('e0000000-0000-0000-0000-0000000000b1');
    raise exception 'second bootstrap issued';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- 3. The approved Windows installation approves a second one.
select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-00000000000a","session_id":"b2000000-0000-0000-0000-000000000002","aal":"aal2","role":"authenticated"}', true);
set local role authenticated;
select set_config('nohut.t2', public.nohut_issue_windows_approval('b3000000-0000-0000-0000-000000000001'), true);
reset role;
-- aal1 on Windows cannot approve.
select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-00000000000a","session_id":"b2000000-0000-0000-0000-000000000002","aal":"aal1","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  begin
    perform public.nohut_issue_windows_approval('b3000000-0000-0000-0000-000000000001');
    raise exception 'aal1 approved';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-00000000000a","session_id":"b2000000-0000-0000-0000-000000000004","aal":"aal2","role":"authenticated"}', true);
set local role authenticated;
select public.nohut_register_windows_device('b3000000-0000-0000-0000-000000000002', 'Kasa 2', current_setting('nohut.t2'));
reset role;
-- Expired tickets are refused.
update nohut_private.windows_enrollment_tickets set created_at = now() - interval '20 minutes', expires_at = now() - interval '11 minutes'
 where ticket_sha256 = encode(extensions.digest(current_setting('nohut.t_other'), 'sha256'), 'hex');
select set_config('request.jwt.claims', '{"sub":"b1000000-0000-0000-0000-00000000000c","session_id":"b2000000-0000-0000-0000-000000000005","aal":"aal2","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  begin
    perform public.nohut_register_windows_device('b3000000-0000-0000-0000-000000000003', 'Kasa', current_setting('nohut.t_other'));
    raise exception 'expired ticket accepted';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
do $$ begin
  if (select count(*) from nohut_private.security_audit where action = 'windows.enroll') <> 2 then
    raise exception 'enrollments not audited';
  end if;
end $$;
rollback;
select 'windows_installation_approval_test ok';
