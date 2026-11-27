-- REVIEW ONLY. No production migration or role password provisioning.
-- DBA must first provision nohut_qr_runtime as a dedicated NOLOGIN,
-- NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION role,
-- with no privileged role membership. Only enable LOGIN after review.
begin;
do $$
begin
 if not exists(select 1 from pg_catalog.pg_roles where rolname='nohut_qr_runtime'
   and not rolsuper and not rolbypassrls and not rolcreatedb and not rolcreaterole
   and not rolreplication and not rolcanlogin)
   or exists(select 1 from pg_catalog.pg_auth_members m join pg_catalog.pg_roles r on r.oid=m.member where r.rolname='nohut_qr_runtime')
 then raise exception 'unsafe or missing dedicated QR runtime role'; end if;
end $$;
-- Must not be added to Data API exposed schemas. The role has no usage on
-- nohut_private and no direct access to restaurant business tables.
create schema nohut_qr_edge;
revoke all on schema nohut_qr_edge from public,anon,authenticated,service_role;
grant usage on schema nohut_qr_edge to nohut_qr_runtime;

create function nohut_qr_edge.qr_publish_bind_draft(
 p_token text,p_request text,p_generation bigint,p_envelope text,p_stamp text,p_revision text,p_draft text
) returns jsonb language sql security definer set search_path=''
as $$ select nohut_private.qr_publish_bind_draft(p_token,p_request,p_generation,p_envelope,p_stamp,p_revision,p_draft) $$;

create function nohut_qr_edge.qr_publish_claim(
 p_token text,p_request text,p_generation bigint,p_envelope text,p_digest text,p_revision text,p_stamp text,p_draft text
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v jsonb;
begin
 v:=nohut_private.qr_publish_bind_draft(p_token,p_request,p_generation,p_envelope,p_stamp,p_revision,p_draft);
 if v->>'digest' is distinct from p_digest then raise exception 'draft binding denied' using errcode='42501'; end if;
 return nohut_private.qr_publish_claim(p_token,p_request,p_generation,p_envelope,p_digest,p_revision);
end $$;

create function nohut_qr_edge.qr_publish_transition(
 p_token text,p_request text,p_generation bigint,p_envelope text,p_digest text,p_fence uuid,p_step text,
 p_parent text,p_commit text,p_tree text,p_revision text,p_stamp text,p_expected_revision text,p_draft text
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v jsonb;
begin
 v:=nohut_private.qr_publish_bind_draft(p_token,p_request,p_generation,p_envelope,p_stamp,p_expected_revision,p_draft);
 if v->>'digest' is distinct from p_digest then raise exception 'draft binding denied' using errcode='42501'; end if;
 return nohut_private.qr_publish_transition(p_token,p_request,p_generation,p_envelope,p_digest,p_fence,p_step,p_parent,p_commit,p_tree,p_revision);
end $$;

-- Do not return the agent record (which contains its credential hash).
create function nohut_qr_edge.qr_recovery_authority(
 p_token text,p_request text,p_generation bigint,p_envelope text
) returns text language sql security definer set search_path=''
as $$ select (nohut_private.qr_recovery_authority(p_token,p_request,p_generation,p_envelope)).restaurant_id::text $$;

create function nohut_qr_edge.qr_publish_recover(
 p_token text,p_request text,p_generation bigint,p_envelope text,p_target text,p_step text,p_commit text,p_revision text
) returns jsonb language sql security definer set search_path=''
as $$ select nohut_private.qr_publish_recover(p_token,p_request,p_generation,p_envelope,p_target,p_step,p_commit,p_revision) $$;

revoke all on all functions in schema nohut_qr_edge from public,anon,authenticated,service_role;
grant execute on function
 nohut_qr_edge.qr_publish_bind_draft(text,text,bigint,text,text,text,text),
 nohut_qr_edge.qr_publish_claim(text,text,bigint,text,text,text,text,text),
 nohut_qr_edge.qr_publish_transition(text,text,bigint,text,text,uuid,text,text,text,text,text,text,text,text),
 nohut_qr_edge.qr_recovery_authority(text,text,bigint,text),
 nohut_qr_edge.qr_publish_recover(text,text,bigint,text,text,text,text,text)
 to nohut_qr_runtime;
-- Do not grant table privileges or membership in the migration owner role.
commit;
