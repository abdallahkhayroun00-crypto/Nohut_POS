-- REVIEW ONLY; never apply to production as-is.
-- Trusted normalization and original-source hash verification are mandatory
-- BEFORE calling this owner-only port. No image decoder or upload endpoint here.
begin;
create table nohut_private.qr_staged_images (
 restaurant_id uuid not null,
 request_id text not null,
 authority_epoch uuid not null,
 envelope_sha256 text not null check(length(envelope_sha256)=64),
 source_sha256 text not null check(length(source_sha256)=64),
 image_sha256 text not null check(length(image_sha256)=64),
 draft_stamp text not null check(length(draft_stamp)=16),
 product_id text not null,
 mime text not null check(mime in ('image/png','image/jpeg','image/webp')),
 path text not null,
 image_bytes bytea not null check(octet_length(image_bytes) between 12 and 6000000),
 created_at timestamptz not null default clock_timestamp(),
 expires_at timestamptz not null default (clock_timestamp()+interval '24 hours'),
 primary key(restaurant_id,request_id),
 foreign key(restaurant_id,request_id) references nohut_private.commands(restaurant_id,request_id),
 foreign key(restaurant_id,authority_epoch) references nohut_private.authority_epochs(restaurant_id,authority_epoch),
 check(image_sha256=encode(sha256(image_bytes),'hex')),
 check(path='assets/products/pos-'||image_sha256||case mime when 'image/png' then '.png' when 'image/jpeg' then '.jpg' else '.webp' end)
);
alter table nohut_private.qr_staged_images enable row level security;
alter table nohut_private.qr_staged_images force row level security;
do $$ begin
 if current_user in ('anon','authenticated','service_role','nohut_qr_runtime') then raise exception 'unsafe migration owner'; end if;
 execute format('create policy qr_stage_owner on nohut_private.qr_staged_images for all to %I using(true) with check(true)',current_user);
end $$;
revoke all on nohut_private.qr_staged_images from public,anon,authenticated,service_role,nohut_qr_runtime;

create function nohut_private.qr_stage_normalized_image(
 p_token text,p_request text,p_generation bigint,p_envelope_sha256 text,
 p_source_sha256 text,p_mime text,p_image bytea
) returns jsonb language plpgsql security invoker set search_path=''
as $$
declare a nohut_private.windows_agents; c nohut_private.commands;
 q nohut_private.qr_menu_state; old nohut_private.qr_staged_images;
 payload jsonb; digest text; asset text; product text; stamp text;
begin
 a:=nohut_private.authenticate_windows_agent(p_token);
 select * into c from nohut_private.commands x where x.restaurant_id=a.restaurant_id
 and x.authority_epoch=a.authority_epoch and x.request_id=p_request for update;
 if not found or p_generation is null or c.lease_generation<>p_generation
 or c.state<>'processing' or c.lease_until<=clock_timestamp() or c.expires_at<=clock_timestamp()
 or nohut_private.command_envelope_sha256(c.envelope) is distinct from p_envelope_sha256
 or c.envelope->>'action_type' is distinct from 'qr_menu_image'
 or c.envelope->>'operation' is distinct from 'menu.product.edit'
 or nohut_private.command_still_authorized(a.restaurant_id,c.envelope) is not true then
 raise exception 'image authority denied' using errcode='42501';
 end if;
 payload:=c.envelope->'payload'; product:=payload->>'id'; stamp:=payload->>'expectedStamp';
 -- Proposed upstream source hash and explicit product target. Legacy commands
 -- cannot stage bytes. Campaign image permissions need a separate contract.
 if p_source_sha256 is null or length(p_source_sha256)<>64 or p_source_sha256 !~ '^[a-f0-9]+$'
 or payload->>'sourceSha256' is distinct from p_source_sha256
 or payload->>'target' is distinct from 'product'
 or payload->>'mime' is distinct from p_mime
 or c.envelope->>'payload_sha256' is distinct from encode(sha256(convert_to(nohut_private.canonical_command_json(payload),'UTF8')),'hex')
 or product is null or length(product) not between 1 and 120
 or stamp is null or length(stamp)<>16 or stamp !~ '^[a-f0-9]+$' then
 raise exception 'image command binding denied' using errcode='42501'; end if;
 if p_image is null or octet_length(p_image) not between 12 and 6000000 or p_mime is null
 or p_mime not in ('image/png','image/jpeg','image/webp') then
 raise exception 'invalid staged image' using errcode='22023'; end if;
 -- Defense in depth signature only, NOT a substitute for trusted decoding.
 if (p_mime='image/png' and substring(p_image from 1 for 8)<>decode('89504e470d0a1a0a','hex'))
 or (p_mime='image/jpeg' and substring(p_image from 1 for 2)<>decode('ffd8','hex'))
 or (p_mime='image/webp' and (substring(p_image from 1 for 4)<>convert_to('RIFF','UTF8')
 or substring(p_image from 9 for 4)<>convert_to('WEBP','UTF8'))) then
 raise exception 'invalid staged image signature' using errcode='22023'; end if;
 digest:=encode(sha256(p_image),'hex');
 asset:='assets/products/pos-'||digest||case p_mime when 'image/png' then '.png' when 'image/jpeg' then '.jpg' else '.webp' end;
 select * into q from nohut_private.qr_menu_state x where x.restaurant_id=a.restaurant_id for share;
 if not found or not q.available or q.offline or q.draft_stamp is distinct from stamp
 or not exists(select 1 from jsonb_array_elements(q.catalog->'products') v where v->>'id'=product)
 or not exists(select 1 from nohut_private.sync_transactions t join nohut_private.sync_event_ids i
 on i.restaurant_id=t.restaurant_id and i.authority_epoch=t.authority_epoch and i.tx_id=t.tx_id
 where t.restaurant_id=a.restaurant_id and t.authority_epoch=a.authority_epoch
 and t.source_revision=q.source_revision and i.entity_type='qrMenuState' and i.entity_id='core') then
 raise exception 'stale image target' using errcode='42501'; end if;
 -- Single fixed repository: cap ALL staging rows globally. Expiry alone
 -- cannot free storage until a reviewed cleanup path proves no pinned receipt.
 perform pg_catalog.pg_advisory_xact_lock(734981,2);
 select * into old from nohut_private.qr_staged_images x where x.restaurant_id=a.restaurant_id and x.request_id=p_request;
 if found then
 if old.envelope_sha256<>p_envelope_sha256 or old.authority_epoch<>a.authority_epoch
 or old.source_sha256<>p_source_sha256 or old.image_sha256<>digest or old.mime<>p_mime
 or old.expires_at<=clock_timestamp() then return jsonb_build_object('status','conflict'); end if;
 return jsonb_build_object('status','staged','requestId',p_request,'path',old.path,'sha256',old.image_sha256,'expiresAt',old.expires_at);
 end if;
 if (select count(*) from nohut_private.qr_staged_images)>=4 or
 (select coalesce(sum(octet_length(image_bytes)),0) from nohut_private.qr_staged_images)+octet_length(p_image)>24000000 then
 return jsonb_build_object('status','quota_exceeded'); end if;
 insert into nohut_private.qr_staged_images(restaurant_id,request_id,authority_epoch,envelope_sha256,source_sha256,image_sha256,draft_stamp,product_id,mime,path,image_bytes)
 values(a.restaurant_id,p_request,a.authority_epoch,p_envelope_sha256,p_source_sha256,digest,stamp,product,p_mime,asset,p_image)
 returning * into old;
 return jsonb_build_object('status','staged','requestId',p_request,'path',old.path,'sha256',old.image_sha256,'expiresAt',old.expires_at);
end $$;
revoke all on function nohut_private.qr_stage_normalized_image(text,text,bigint,text,text,text,bytea)
 from public,anon,authenticated,service_role,nohut_qr_runtime;
commit;
