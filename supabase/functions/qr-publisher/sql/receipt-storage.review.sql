-- REVIEW DRAFT ONLY. Not a migration. Do not deploy before independent SQL
-- and concurrency tests and binding to authenticated server-side Edge RPC.
-- Existing #39/#46 command authority is reused. No public function or grant.
begin;
create table nohut_private.qr_publish_receipts (
 restaurant_id uuid not null,
 request_id text not null,
 authority_epoch uuid not null,
 agent_id uuid not null references nohut_private.windows_agents(agent_id),
 lease_generation bigint not null check (lease_generation>0),
 envelope_sha256 text not null check (envelope_sha256 ~ '^[0-9a-f]{64}$'),
 payload_sha256 text not null check (payload_sha256 ~ '^[0-9a-f]{64}$'),
 expected_revision text not null check (expected_revision ~ '^[0-9a-f]{40}$'),
 fence uuid not null unique default gen_random_uuid(),
 state text not null default 'new' check (state in ('new','prepared','attempted','unknown','completed')),
 parent_sha text check (parent_sha ~ '^[0-9a-f]{40}$'),
 commit_sha text check (commit_sha ~ '^[0-9a-f]{40}$'),
 tree_sha text check (tree_sha ~ '^[0-9a-f]{40}$'),
 revision text check (revision ~ '^[0-9a-f]{40}$'),
 result jsonb,
 created_at timestamptz not null default clock_timestamp(),
 updated_at timestamptz not null default clock_timestamp(),
 attempted_at timestamptz,
 primary key (restaurant_id,request_id),
 foreign key (restaurant_id,request_id) references nohut_private.commands(restaurant_id,request_id),
 foreign key (restaurant_id,authority_epoch) references nohut_private.authority_epochs(restaurant_id,authority_epoch),
 check ((parent_sha is null and commit_sha is null and tree_sha is null and revision is null)
     or (parent_sha is not null and commit_sha is not null and tree_sha is not null and revision is not null)),
 check (state <> 'new' or (commit_sha is null and attempted_at is null and result is null)),
 check (state <> 'prepared' or (commit_sha is not null and attempted_at is null and result is null)),
 check (state not in ('attempted','unknown') or (commit_sha is not null and attempted_at is not null)),
 check (attempted_at is null or commit_sha is not null),
 check ((state='completed')=(result is not null)),
 check ((state<>'completed' or (
   jsonb_typeof(result)='object' and result->>'requestId'=request_id and
   ((result->>'status'='committed' and attempted_at is not null and result->>'commit'=commit_sha and result->>'revision'=revision)
   or (result->>'status'='no_change' and commit_sha is null and result->>'revision'=expected_revision)
   or (result->>'status'='cancelled_before_attempt' and attempted_at is null)))) is true)
);
-- Only one unresolved operation across ALL tenants because there is exactly
-- one fixed QR GitHub repository. No TTL releases an ambiguous operation.
create unique index qr_publish_single_unresolved
 on nohut_private.qr_publish_receipts ((1)) where state <> 'completed';
alter table nohut_private.qr_publish_receipts enable row level security;
alter table nohut_private.qr_publish_receipts force row level security;
do $$ begin
 if current_user in ('anon','authenticated','service_role') then raise exception 'unsafe migration owner'; end if;
 execute format('create policy qr_receipt_owner on nohut_private.qr_publish_receipts for all to %I using (true) with check (true)',current_user);
end $$;
revoke all on nohut_private.qr_publish_receipts from public,anon,authenticated,service_role;

-- Every write-stage transaction repeats the existing command authority check.
-- Caller must also validate the actual draft stamp and canonical catalog digest
-- server-side; a digest supplied by a client is not proof of its draft.
create function nohut_private.qr_publish_authority(
 p_token text,p_request text,p_generation bigint,p_envelope_sha256 text
) returns nohut_private.windows_agents language plpgsql security invoker set search_path=''
as $$
declare a nohut_private.windows_agents; c nohut_private.commands;
begin
 a:=nohut_private.authenticate_windows_agent(p_token);
 select * into c from nohut_private.commands q where q.restaurant_id=a.restaurant_id
   and q.authority_epoch=a.authority_epoch and q.request_id=p_request for update;
 if not found or p_generation is null or c.lease_generation<>p_generation
    or c.state<>'processing' or c.lease_until<=clock_timestamp() or c.expires_at<=clock_timestamp()
    or nohut_private.command_envelope_sha256(c.envelope) is distinct from p_envelope_sha256
    or c.envelope->>'action_type' is distinct from 'qr_menu_publish'
    or c.envelope->>'operation' is distinct from 'menu.qr.publish'
    or c.envelope->'payload'->'confirmed' is distinct from 'true'::jsonb
    or coalesce(c.envelope->'payload'->>'expectedStamp','') !~ '^[0-9a-f]{16}$'
    or nohut_private.command_still_authorized(a.restaurant_id,c.envelope) is not true then
   raise exception 'publication authority denied' using errcode='42501';
 end if;
 return a;
end $$;

create function nohut_private.qr_publish_claim(
 p_token text,p_request text,p_generation bigint,p_envelope_sha256 text,
 p_digest text,p_revision text
) returns jsonb language plpgsql security invoker set search_path=''
as $$
declare a nohut_private.windows_agents; q nohut_private.qr_publish_receipts;
begin
 a:=nohut_private.qr_publish_authority(p_token,p_request,p_generation,p_envelope_sha256);
 if coalesce(p_digest,'') !~ '^[0-9a-f]{64}$' or coalesce(p_revision,'') !~ '^[0-9a-f]{40}$' then
   raise exception 'invalid publication binding' using errcode='22023';
 end if;
 -- Serialize claims across tenants. Unique index is a second independent gate.
 perform pg_catalog.pg_advisory_xact_lock(734981,1);
 select * into q from nohut_private.qr_publish_receipts x where x.restaurant_id=a.restaurant_id and x.request_id=p_request for update;
 if found then
   if q.payload_sha256<>p_digest or q.expected_revision<>p_revision
      or q.envelope_sha256<>p_envelope_sha256 or q.authority_epoch<>a.authority_epoch then
     return jsonb_build_object('status','conflict');
   end if;
   if q.state='completed' then return jsonb_build_object('status','completed','result',q.result); end if;
   if q.state='new' then return jsonb_build_object('status','busy'); end if;
   return jsonb_build_object('status',q.state);
 end if;
 if exists(select 1 from nohut_private.qr_publish_receipts x where x.state<>'completed') then
   return jsonb_build_object('status','busy');
 end if;
 insert into nohut_private.qr_publish_receipts(restaurant_id,request_id,authority_epoch,agent_id,lease_generation,envelope_sha256,payload_sha256,expected_revision)
 values(a.restaurant_id,p_request,a.authority_epoch,a.agent_id,p_generation,p_envelope_sha256,p_digest,p_revision)
 returning * into q;
 return jsonb_build_object('status','new','fence',q.fence);
end $$;

-- Private transition API, called only by a trusted Edge adapter. Validate
-- exact receipt fence, current command generation and authenticated agent.
-- No public grants. No arbitrary caller-supplied result JSON is persisted.
create function nohut_private.qr_publish_transition(
 p_token text,p_request text,p_generation bigint,p_envelope_sha256 text,
 p_digest text,p_fence uuid,p_step text,
 p_parent text default null,p_commit text default null,p_tree text default null,p_revision text default null
) returns jsonb language plpgsql security invoker set search_path=''
as $$
declare a nohut_private.windows_agents; q nohut_private.qr_publish_receipts; v_result jsonb;
begin
 a:=nohut_private.qr_publish_authority(p_token,p_request,p_generation,p_envelope_sha256);
 select * into q from nohut_private.qr_publish_receipts x
 where x.restaurant_id=a.restaurant_id and x.request_id=p_request for update;
 if not found or q.authority_epoch<>a.authority_epoch or q.agent_id<>a.agent_id
   or q.lease_generation<>p_generation or q.envelope_sha256 is distinct from p_envelope_sha256
   or q.payload_sha256 is distinct from p_digest or q.fence is distinct from p_fence then
   raise exception 'publication fence denied' using errcode='42501';
 end if;
 if p_step='prepare' and q.state='new' then
   if coalesce(p_parent,'') !~ '^[0-9a-f]{40}$' or coalesce(p_commit,'') !~ '^[0-9a-f]{40}$'
      or coalesce(p_tree,'') !~ '^[0-9a-f]{40}$' or coalesce(p_revision,'') !~ '^[0-9a-f]{40}$' then
     raise exception 'invalid immutable commit' using errcode='22023';
   end if;
   update nohut_private.qr_publish_receipts x set state='prepared',parent_sha=p_parent,
     commit_sha=p_commit,tree_sha=p_tree,revision=p_revision,updated_at=clock_timestamp()
     where x.restaurant_id=q.restaurant_id and x.request_id=q.request_id;
   return jsonb_build_object('status','prepared');
 elsif p_step='attempt' and q.state='prepared' then
   update nohut_private.qr_publish_receipts x set state='attempted',attempted_at=clock_timestamp(),updated_at=clock_timestamp()
     where x.restaurant_id=q.restaurant_id and x.request_id=q.request_id;
   return jsonb_build_object('requestId',q.request_id,'parent',q.parent_sha,'commit',q.commit_sha,
     'tree',q.tree_sha,'revision',q.revision,'expectedRevision',q.expected_revision);
 elsif p_step='unknown' and q.state='attempted' then
   update nohut_private.qr_publish_receipts x set state='unknown',updated_at=clock_timestamp()
     where x.restaurant_id=q.restaurant_id and x.request_id=q.request_id;
   return jsonb_build_object('requestId',q.request_id,'status','reconciliation_required');
 elsif p_step='committed' and q.state='attempted' and p_commit=q.commit_sha and p_revision=q.revision then
   -- Only the trusted Edge transport may attest observed GitHub success.
   v_result:=jsonb_build_object('requestId',q.request_id,'status','committed','commit',q.commit_sha,'revision',q.revision,'pages','unverified');
 elsif p_step='no_change' and q.state='new' and p_revision=q.expected_revision then
   v_result:=jsonb_build_object('requestId',q.request_id,'status','no_change','revision',q.expected_revision);
 else
   raise exception 'invalid publication transition' using errcode='22023';
 end if;
 update nohut_private.qr_publish_receipts x set state='completed',result=v_result,updated_at=clock_timestamp()
   where x.restaurant_id=q.restaurant_id and x.request_id=q.request_id;
 return v_result;
end $$;
revoke all on function nohut_private.qr_publish_authority(text,text,bigint,text),
 nohut_private.qr_publish_claim(text,text,bigint,text,text,text),
 nohut_private.qr_publish_transition(text,text,bigint,text,text,uuid,text,text,text,text,text)
 from public,anon,authenticated,service_role;
-- A NEW, currently authorized reconcile command is required, independently
-- of the original publish actor/session/lease. This permits recovery after
-- expiry or PC replacement within the same restaurant, not cross-tenant access.
-- The private Edge adapter must never forward client-supplied Git evidence.
create function nohut_private.qr_recovery_authority(
 p_token text,p_reconcile_request text,p_generation bigint,p_envelope_sha256 text
) returns nohut_private.windows_agents language plpgsql security invoker set search_path=''
as $
declare a nohut_private.windows_agents; c nohut_private.commands;
begin
 a:=nohut_private.authenticate_windows_agent(p_token);
 select * into c from nohut_private.commands q where q.restaurant_id=a.restaurant_id
  and q.authority_epoch=a.authority_epoch and q.request_id=p_reconcile_request for update;
 if not found or p_generation is null or c.lease_generation<>p_generation
  or c.state<>'processing' or c.lease_until<=clock_timestamp() or c.expires_at<=clock_timestamp()
  or nohut_private.command_envelope_sha256(c.envelope) is distinct from p_envelope_sha256
  or c.envelope->>'action_type' is distinct from 'qr_menu_reconcile'
  or c.envelope->>'operation' is distinct from 'menu.qr.publish'
  or nohut_private.command_still_authorized(a.restaurant_id,c.envelope) is not true then
   raise exception 'reconciliation authority denied' using errcode='42501';
 end if;
 return a;
end $;

-- Private recovery port. A row lock serializes it against markAttempt.
-- Recover only a named receipt owned by the authenticated restaurant.
-- Before-ref cancellation never releases an attempted or uncertain write.
-- Positive evidence is accepted solely from the reviewed Git transport.
create function nohut_private.qr_publish_recover(
 p_token text,p_reconcile_request text,p_generation bigint,p_envelope_sha256 text,
 p_target text,p_step text,p_commit text default null,p_revision text default null
) returns jsonb language plpgsql security invoker set search_path=''
as $
declare a nohut_private.windows_agents; q nohut_private.qr_publish_receipts;
 c nohut_private.commands; v_result jsonb;
begin
 a:=nohut_private.qr_recovery_authority(p_token,p_reconcile_request,p_generation,p_envelope_sha256);
 if p_target is null or p_target !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}
 then
   raise exception 'invalid receipt target' using errcode='22023';
 end if;
 select * into q from nohut_private.qr_publish_receipts x where x.restaurant_id=a.restaurant_id and x.request_id=p_target for update;
 if not found then return jsonb_build_object('status','not_found'); end if;
 if q.state='completed' then return jsonb_build_object('status','completed','requestId',q.request_id,'result',q.result); end if;
 if p_step='inspect' then
   if q.state in ('attempted','unknown') then
     return jsonb_build_object('status',q.state,'requestId',q.request_id,'prepared',jsonb_build_object(
       'requestId',q.request_id,'parent',q.parent_sha,'commit',q.commit_sha,'tree',q.tree_sha,
       'revision',q.revision,'expectedRevision',q.expected_revision));
   end if;
   return jsonb_build_object('status',q.state,'requestId',q.request_id);
 elsif p_step='cancel_before_attempt' and q.state in ('new','prepared') and q.attempted_at is null then
   -- Original authority row is already fenced for the current epoch.
   -- A superseded/expired generation cannot consume the attempt after cancellation.
   select * into c from nohut_private.commands x where x.restaurant_id=q.restaurant_id and x.request_id=q.request_id;
   if not found then raise exception 'missing original command' using errcode='42501'; end if;
   if c.state='processing' and c.lease_until>clock_timestamp() and c.expires_at>clock_timestamp()
      and c.lease_generation=q.lease_generation and q.authority_epoch=a.authority_epoch
      and q.agent_id=a.agent_id and nohut_private.command_still_authorized(q.restaurant_id,c.envelope) is true then
     return jsonb_build_object('status','busy','requestId',q.request_id);
   end if;
   v_result:=jsonb_build_object('requestId',q.request_id,'status','cancelled_before_attempt');
 elsif p_step='confirm_reachable' and q.state in ('attempted','unknown') and q.attempted_at is not null
    and p_commit=q.commit_sha and p_revision=q.revision then
   -- A trusted server adapter has verified exact commit reachability. Merely
   -- failing to find the commit NEVER proves the write did not happen.
   v_result:=jsonb_build_object('requestId',q.request_id,'status','committed','commit',q.commit_sha,'revision',q.revision,'pages','unverified');
 else
   raise exception 'invalid recovery transition' using errcode='22023';
 end if;
 update nohut_private.qr_publish_receipts x set state='completed',result=v_result,updated_at=clock_timestamp()
 where x.restaurant_id=q.restaurant_id and x.request_id=q.request_id;
 return v_result;
end $;
revoke all on function nohut_private.qr_recovery_authority(text,text,bigint,text),
 nohut_private.qr_publish_recover(text,text,bigint,text,text,text,text,text)
 from public,anon,authenticated,service_role;
-- No public/Edge wrapper grants yet. Record trusted recovery actor/command
-- evidence in an append-only audit before release. No negative-evidence unlock.
commit;
