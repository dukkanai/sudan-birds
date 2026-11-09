-- Remove the discontinued consultation/education timeline, preserving marketplace data.
-- Apply as one transaction. Never edit the two already-applied historic migrations.
-- A populated installation requires a separately approved export/retention/cleanup
-- plan first. This migration does not destroy user content or audit history.
begin;
-- Busy installations fail closed; no indefinite migration lock wait.
set local lock_timeout = '5s';
set local statement_timeout = '60s';
lock table public.posts, public.replies, public.topics, public.reports,
 public.media, public.upload_intents, public.moderation_actions,
 private.publish_events, private.publish_limits in access exclusive mode;
do $$ begin
 if exists(select 1 from public.posts) or exists(select 1 from public.replies)
 or exists(select 1 from public.media where post_id is not null)
 or exists(select 1 from public.upload_intents where post_id is not null)
 or exists(select 1 from public.reports where post_id is not null or reply_id is not null)
 or exists(select 1 from public.moderation_actions where target_kind in ('post','reply'))
 or exists(select 1 from private.publish_events where table_name in ('posts','replies')) then
  raise exception using errcode='55000',message='Timeline cleanup blocked: retained content or audit data requires an approved cleanup plan';
 end if;
 -- Only the known development reference topics may be discarded. Unknown topic
 -- values are not presumed to be disposable, even on a nominally empty instance.
 if exists(select 1 from public.topics where name_ar not in
  ('التغذية','الرعاية اليومية','التكاثر والتفريخ','المسكن والنظافة','صحة الطيور','إرشادات للمبتدئين')) then
  raise exception using errcode='55000',message='Timeline cleanup blocked: unknown topic reference data';
 end if;
end $$;

-- Remove the old overload instead of accepting a legacy target and ignoring it.
drop function public.reserve_upload(uuid,uuid,integer,text) restrict;
drop policy media_read on public.media;
alter table public.media drop constraint media_check;
alter table public.upload_intents drop constraint upload_intents_check;
alter table public.reports drop constraint reports_one_target;
alter table public.media drop column post_id restrict;
alter table public.upload_intents drop column post_id restrict;
alter table public.reports drop column post_id restrict, drop column reply_id restrict;
alter table public.media alter column listing_id set not null;
alter table public.upload_intents alter column listing_id set not null;
alter table public.reports add constraint reports_one_target check(num_nonnulls(account_id,listing_id)=1);
create policy media_read on public.media for select using(
 exists(select 1 from public.listings l where l.id=listing_id and l.moderation_state='visible'));

create or replace function private.validate_report_target() returns trigger language plpgsql set search_path='' as $$
 begin
  if not (
   (new.listing_id is not null and exists(select 1 from public.listings where id=new.listing_id)) or
   (new.account_id is not null and exists(select 1 from public.profiles where id=new.account_id))
  ) then raise exception using errcode='23514',message='Invalid report target'; end if;
  return new;
 end
$$;

create or replace function public.moderate_content(p_kind text,p_id uuid,p_hidden boolean,p_reason text)
returns void language plpgsql security definer set search_path='' as $$
 declare changed integer;
 begin
  if auth.uid() is null or not private.is_moderator() or exists(select 1 from private.account_deletion_jobs where owner_id=auth.uid()) then raise exception using errcode='42501',message='Moderation denied'; end if;
  if p_kind <> 'listing' or p_kind is null or p_hidden is null or p_reason is null or char_length(trim(p_reason)) not between 5 and 2000 then
   raise exception using errcode='22023',message='Invalid moderation action';
  end if;
  update public.listings set moderation_state=case when p_hidden then 'hidden' else 'visible' end where id=p_id;
  get diagnostics changed=row_count;
  if changed<>1 then raise exception using errcode='22023',message='Content not found'; end if;
  insert into public.moderation_actions(actor_id,target_kind,target_id,action,reason) values(auth.uid(),p_kind,p_id,case when p_hidden then 'hide' else 'restore' end,p_reason);
 end
$$;

create or replace function public.moderator_report_target(p_report uuid)
returns table(target_kind text,target_id uuid,title text,body text,display_name text,moderation_state text,missing boolean)
language plpgsql security definer set search_path='' as $$
 declare r public.reports; kind text; target uuid;
 begin
  if auth.uid() is null or not private.is_moderator() or exists(select 1 from private.account_deletion_jobs where owner_id=auth.uid()) then
   raise exception using errcode='42501',message='Moderation denied'; end if;
  select * into r from public.reports where id=p_report;
  if not found then raise exception using errcode='22023',message='Report not found'; end if;
  if r.listing_id is not null then
   kind:='listing';target:=r.listing_id;
   return query select 'listing'::text,p.id,p.title,p.description,pr.display_name,p.moderation_state,false
    from public.listings p left join public.profiles pr on pr.id=p.owner_id where p.id=r.listing_id;
  else
   kind:='account';target:=r.account_id;
   return query select 'account'::text,p.id,null::text,null::text,p.display_name,'visible'::text,false
    from public.profiles p where p.id=r.account_id;
  end if;
  if found then return; end if;
  return query select kind,target,null::text,null::text,null::text,null::text,true;
 end
$$;

create or replace function public.reserve_upload(p_listing uuid,p_bytes integer,p_mime text)
returns public.upload_intents language plpgsql security definer set search_path='' as $$
 declare u uuid:=auth.uid(); v public.upload_intents; used integer;
 begin
  if u is null or not private.can_publish() then raise exception using errcode='42501',message='Upload denied'; end if;
  if p_listing is null or p_bytes is null or p_bytes not between 1 and 2097152 or p_mime is distinct from 'image/jpeg' then
   raise exception using errcode='22023',message='Invalid upload'; end if;
  perform pg_advisory_xact_lock(hashtextextended(u::text,0));
  if exists(select 1 from private.account_deletion_jobs where owner_id=u) then raise exception using errcode='42501',message='Upload denied'; end if;
  if not exists(select 1 from public.listings where id=p_listing and owner_id=u and moderation_state='visible') then
   raise exception using errcode='42501',message='Upload denied'; end if;
  select count(*) into used from private.upload_events where user_id=u and created_at>now()-interval '24 hours';
  if used>=20 then raise exception using errcode='P0001',message='Upload quota reached'; end if;
  select count(*) into used from public.upload_intents where owner_id=u and listing_id=p_listing and (state='verified' or (state='pending' and expires_at>now()));
  if used>=3 then raise exception using errcode='P0001',message='Attachment limit reached'; end if;
  insert into public.upload_intents(owner_id,listing_id,expected_bytes,expected_mime,object_key)
   values(u,p_listing,p_bytes,p_mime,'quarantine/'||u::text||'/'||gen_random_uuid()::text) returning * into v;
  insert into private.upload_events(user_id) values(u);
  insert into private.object_registry(object_key,owner_id,intent_id,kind,safe_delete_after,create_only)
   values(v.object_key,u,v.id,'quarantine',v.expires_at+interval '60 seconds',true);
  return v;
 end
$$;

create or replace function public.prepare_media_verification(p_owner uuid,p_intent uuid)
returns table(intent_id uuid,source_key text,expected_bytes integer,clean_key text,existing_media uuid,expires_at timestamptz)
language plpgsql security definer set search_path='' as $$
 declare v public.upload_intents; key text;
 begin
  perform pg_advisory_xact_lock(hashtextextended(p_owner::text,0));
  if exists(select 1 from private.account_deletion_jobs where owner_id=p_owner) then raise exception using errcode='42501',message='Verification denied'; end if;
  select * into v from public.upload_intents where id=p_intent and owner_id=p_owner for update;
  if not found then raise exception using errcode='42501',message='Verification denied'; end if;
  if v.state='verified' and exists(select 1 from public.media where id=v.id) then
   return query select v.id,v.object_key,v.expected_bytes,null::text,v.id,v.expires_at; return;
  end if;
  if v.state<>'pending' or v.expires_at<=clock_timestamp() or v.expected_mime<>'image/jpeg' or v.expected_bytes>2097152 then
   raise exception using errcode='42501',message='Verification denied'; end if;
  if not exists(select 1 from public.listings where id=v.listing_id and owner_id=p_owner and moderation_state='visible') then
   raise exception using errcode='42501',message='Verification denied'; end if;
  -- Bound repeated verification CPU/network work for one intent, including failures.
  if (select count(*) from private.object_registry r where r.intent_id=v.id and r.kind='clean')>=3 then
   raise exception using errcode='P0001',message='Verification attempts exhausted'; end if;
  key:='verified/'||p_owner::text||'/'||gen_random_uuid()::text||'.jpg';
  insert into private.object_registry(object_key,owner_id,intent_id,kind,safe_delete_after,create_only)
   values(key,p_owner,v.id,'clean',v.expires_at+interval '60 seconds',true);
  return query select v.id,v.object_key,v.expected_bytes,key,null::uuid,v.expires_at;
 end
$$;

create or replace function public.commit_verified_media(p_owner uuid,p_intent uuid,p_key text,p_bytes integer,p_width integer,p_height integer,p_alt text)
returns table(media_id uuid,published_key text) language plpgsql security definer set search_path='' as $$
 declare v public.upload_intents;
 begin
  perform pg_advisory_xact_lock(hashtextextended(p_owner::text,0));
  if exists(select 1 from private.account_deletion_jobs where owner_id=p_owner) then raise exception using errcode='42501',message='Verification denied'; end if;
  select * into v from public.upload_intents where id=p_intent and owner_id=p_owner for update;
  if not found then raise exception using errcode='42501',message='Verification denied'; end if;
  if v.state='verified' then return query select m.id,m.object_key from public.media m where m.id=v.id; return; end if;
  if v.state<>'pending' or v.expires_at<=clock_timestamp() or v.expected_mime<>'image/jpeg' or p_bytes is null or p_bytes not between 1 and 2097152 or
   p_width is null or p_height is null or p_width not between 1 and 640 or p_height not between 1 and 640 or p_width::bigint*p_height>409600 or
   p_alt is null or char_length(p_alt)>500 then raise exception using errcode='22023',message='Invalid verified image'; end if;
  if not exists(select 1 from private.object_registry where object_key=p_key and intent_id=v.id and owner_id=p_owner and kind='clean' and deleted_at is null) then
   raise exception using errcode='42501',message='Verification denied'; end if;
  if not exists(select 1 from public.listings where id=v.listing_id and owner_id=p_owner and moderation_state='visible') then
   raise exception using errcode='42501',message='Verification denied'; end if;
  insert into public.media(id,owner_id,listing_id,object_key,byte_size,mime_type,width,height,alt_text,verified_at)
   values(v.id,p_owner,v.listing_id,p_key,p_bytes,'image/jpeg',p_width,p_height,p_alt,now());
  update public.upload_intents set state='verified' where id=v.id;
  return query select v.id,p_key;
 end
$$;

-- Explicit privileges on the new API, including service-only verification.
revoke all on function private.validate_report_target() from public,anon,authenticated;
revoke all on function public.reserve_upload(uuid,integer,text) from public,anon,authenticated;
grant execute on function public.reserve_upload(uuid,integer,text) to authenticated;
revoke all on function public.moderate_content(text,uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.moderate_content(text,uuid,boolean,text) to authenticated;
revoke all on function public.moderator_report_target(uuid) from public,anon,authenticated;
grant execute on function public.moderator_report_target(uuid) to authenticated;
revoke all on function public.prepare_media_verification(uuid,uuid) from public,anon,authenticated;
grant execute on function public.prepare_media_verification(uuid,uuid) to service_role;
revoke all on function public.commit_verified_media(uuid,uuid,text,integer,integer,integer,text) from public,anon,authenticated;
grant execute on function public.commit_verified_media(uuid,uuid,text,integer,integer,integer,text) to service_role;

-- RESTRICT deliberately fails if an unexpected dependent object exists.
-- Table-local indexes, policies, constraints and triggers disappear with tables.
drop table public.replies restrict;
drop function private.validate_reply() restrict;
drop table public.posts restrict;
-- Seed topics are reference values, not user-generated content (guard above).
delete from public.topics;
drop table public.topics restrict;
delete from private.publish_limits where table_name in ('posts','replies');
notify pgrst, 'reload schema';
commit;
