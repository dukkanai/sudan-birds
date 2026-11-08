-- Image verification + durable object cleanup and self-deletion jobs.
-- No schedules or credentials are created by this migration.
create table private.account_deletion_jobs (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null unique,
 state text not null default 'pending' check(state in ('pending','auth_pending','completed')),
 not_before timestamptz not null, created_at timestamptz not null default now(), completed_at timestamptz
);
create table private.object_registry (
 object_key text primary key, owner_id uuid not null, intent_id uuid not null,
 kind text not null check(kind in ('quarantine','clean')), created_at timestamptz not null default now(),
 safe_delete_after timestamptz not null, deleted_at timestamptz,
 last_checked_at timestamptz,
 create_only boolean not null default false, fenced_at timestamptz
);
create index object_registry_owner on private.object_registry(owner_id) where deleted_at is null;
revoke all on private.account_deletion_jobs,private.object_registry from public,anon,authenticated;
grant all on private.account_deletion_jobs,private.object_registry to service_role;
-- Preserve audit actor UUID after account deletion, without retaining profile snapshots.
alter table public.moderation_actions drop constraint moderation_actions_actor_id_fkey;

create or replace function private.can_publish() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles where id=auth.uid() and accepted_terms_at is not null)
 and not exists(select 1 from private.account_deletion_jobs where owner_id=auth.uid())
$$;
create or replace function private.visible_author(author uuid) returns boolean language sql stable security definer set search_path='' as $$
 select not exists(select 1 from public.user_blocks b where
 (b.blocker_id=auth.uid() and b.blocked_id=author) or (b.blocked_id=auth.uid() and b.blocker_id=author))
 and not exists(select 1 from private.account_deletion_jobs where owner_id=author)
$$;
create function private.guard_deleting_account() returns trigger language plpgsql security definer set search_path='' as $$
 begin
  if auth.uid() is not null then
   perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));
   if exists(select 1 from private.account_deletion_jobs where owner_id=auth.uid()) then
    raise exception using errcode='42501',message='Account deletion pending';
   end if;
  end if;
  if TG_OP='DELETE' then return old; end if;
  return new;
 end
$$;
revoke all on function private.guard_deleting_account() from public,anon,authenticated;
do $$ declare t text; begin
 foreach t in array array['profiles','profile_contacts','user_blocks','listings','posts','replies','reports'] loop
  execute format('create trigger account_active before insert or update or delete on public.%I for each row execute function private.guard_deleting_account()',t);
 end loop;
end $$;

-- New upload format is deliberately narrow; old reserved formats cannot finalize.
create or replace function public.reserve_upload(p_post uuid,p_listing uuid,p_bytes integer,p_mime text)
returns public.upload_intents language plpgsql security definer set search_path='' as $$
 declare u uuid:=auth.uid(); v public.upload_intents; used integer;
 begin
  if u is null or not private.can_publish() then raise exception using errcode='42501',message='Upload denied'; end if;
  if num_nonnulls(p_post,p_listing)<>1 or p_bytes is null or p_bytes not between 1 and 2097152 or p_mime is distinct from 'image/jpeg' then
   raise exception using errcode='22023',message='Invalid upload'; end if;
  perform pg_advisory_xact_lock(hashtextextended(u::text,0));
  if exists(select 1 from private.account_deletion_jobs where owner_id=u) then raise exception using errcode='42501',message='Upload denied'; end if;
  if not ((p_post is not null and exists(select 1 from public.posts where id=p_post and owner_id=u and moderation_state='visible')) or
   (p_listing is not null and exists(select 1 from public.listings where id=p_listing and owner_id=u and moderation_state='visible'))) then
   raise exception using errcode='42501',message='Upload denied'; end if;
  select count(*) into used from private.upload_events where user_id=u and created_at>now()-interval '24 hours';
  if used>=20 then raise exception using errcode='P0001',message='Upload quota reached'; end if;
  select count(*) into used from public.upload_intents where owner_id=u and (post_id=p_post or listing_id=p_listing) and (state='verified' or (state='pending' and expires_at>now()));
  if used>=3 then raise exception using errcode='P0001',message='Attachment limit reached'; end if;
  insert into public.upload_intents(owner_id,post_id,listing_id,expected_bytes,expected_mime,object_key)
   values(u,p_post,p_listing,p_bytes,p_mime,'quarantine/'||u::text||'/'||gen_random_uuid()::text) returning * into v;
  insert into private.upload_events(user_id) values(u);
  insert into private.object_registry(object_key,owner_id,intent_id,kind,safe_delete_after,create_only)
   values(v.object_key,u,v.id,'quarantine',v.expires_at+interval '60 seconds',true);
  return v;
 end
$$;
-- Register older objects as well so upgrading a populated staging DB does not orphan them.
insert into private.object_registry(object_key,owner_id,intent_id,kind,safe_delete_after)
 select object_key,owner_id,id,'quarantine',expires_at+interval '60 seconds' from public.upload_intents on conflict do nothing;
insert into private.object_registry(object_key,owner_id,intent_id,kind,safe_delete_after)
 select object_key,owner_id,id,'clean',now()+interval '6 minutes' from public.media on conflict do nothing;

-- Prepare a unique output key BEFORE network write. A crash or loser in a race
-- leaves a registered orphan, not an untracked object. No two attempts share keys.
create function public.prepare_media_verification(p_owner uuid,p_intent uuid)
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
  if not ((v.post_id is not null and exists(select 1 from public.posts where id=v.post_id and owner_id=p_owner and moderation_state='visible')) or
   (v.listing_id is not null and exists(select 1 from public.listings where id=v.listing_id and owner_id=p_owner and moderation_state='visible'))) then
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
create function public.commit_verified_media(p_owner uuid,p_intent uuid,p_key text,p_bytes integer,p_width integer,p_height integer,p_alt text)
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
  if not ((v.post_id is not null and exists(select 1 from public.posts where id=v.post_id and owner_id=p_owner and moderation_state='visible')) or
   (v.listing_id is not null and exists(select 1 from public.listings where id=v.listing_id and owner_id=p_owner and moderation_state='visible'))) then
   raise exception using errcode='42501',message='Verification denied'; end if;
  insert into public.media(id,owner_id,post_id,listing_id,object_key,byte_size,mime_type,width,height,alt_text,verified_at)
   values(v.id,p_owner,v.post_id,v.listing_id,p_key,p_bytes,'image/jpeg',p_width,p_height,p_alt,now());
  update public.upload_intents set state='verified' where id=v.id;
  return query select v.id,p_key;
 end
$$;
create function public.begin_account_deletion(p_owner uuid)
returns private.account_deletion_jobs language plpgsql security definer set search_path='' as $$
 declare job private.account_deletion_jobs; cutoff timestamptz;
 begin
  perform pg_advisory_xact_lock(hashtextextended(p_owner::text,0));
  select * into job from private.account_deletion_jobs where owner_id=p_owner;
  if found then return job; end if;
  if not exists(select 1 from auth.users where id=p_owner) then raise exception using errcode='42501',message='Account not found'; end if;
  -- Wait out all already-issued PUT capabilities and outstanding verification work.
  select greatest(now(),coalesce(max(safe_delete_after),now())) into cutoff from private.object_registry where owner_id=p_owner and deleted_at is null;
  insert into private.account_deletion_jobs(owner_id,not_before) values(p_owner,cutoff) returning * into job;
  return job;
 end
$$;
create function public.is_cleanup_admin() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.moderator_roles where user_id=auth.uid() and role='admin')
 and not exists(select 1 from private.account_deletion_jobs where owner_id=auth.uid())
$$;
revoke all on function public.is_cleanup_admin() from public,anon,authenticated;
grant execute on function public.is_cleanup_admin() to authenticated;
-- Lifecycle RPCs are service-only. No user can mark a key deleted or skip cleanup.
create function public.get_deletion_job(p_job uuid) returns setof private.account_deletion_jobs language sql security definer set search_path='' as $$
 select * from private.account_deletion_jobs where id=p_job
$$;
create function public.list_cleanup_objects(p_owner uuid default null,p_limit integer default 50)
returns table(object_key text,owner_id uuid) language sql security definer set search_path='' as $$
 select r.object_key,r.owner_id from private.object_registry r where r.deleted_at is null and r.safe_delete_after<=clock_timestamp()
 and (p_owner is null or r.owner_id=p_owner)
 and ((exists(select 1 from private.account_deletion_jobs j where j.owner_id=r.owner_id and j.not_before<=now() and j.state<>'completed'))
 or (not exists(select 1 from public.media m where m.object_key=r.object_key)
 and not exists(select 1 from public.upload_intents i where i.object_key=r.object_key and i.state='pending' and i.expires_at>now())))
 order by r.created_at,r.object_key limit greatest(1,least(p_limit,100))
$$;
create function public.mark_object_deleted(p_key text,p_fenced boolean default false) returns void language plpgsql security definer set search_path='' as $$
 begin
  -- A trusted zero-byte tombstone must exist at R2. All capabilities issued for
  -- this key must have been cryptographically create-only. Legacy unconditioned
  -- keys cannot be declared fenced merely from an absence/expiry observation.
  if p_fenced is distinct from true or not exists(select 1 from private.object_registry where object_key=p_key and create_only) then
   raise exception using errcode='P0001',message='Cleanup fencing unproven'; end if;
  update private.object_registry set deleted_at=clock_timestamp(),fenced_at=clock_timestamp(),last_checked_at=clock_timestamp()
   where object_key=p_key and safe_delete_after<=clock_timestamp();
 end
$$;
create function public.deletion_ready_for_auth(p_job uuid) returns uuid language plpgsql security definer set search_path='' as $$
 declare job private.account_deletion_jobs;
 begin
  select * into job from private.account_deletion_jobs where id=p_job for update;
  if not found or job.not_before>now() or exists(select 1 from private.object_registry where owner_id=job.owner_id and (deleted_at is null or fenced_at is null)) then
   raise exception using errcode='P0001',message='Cleanup pending'; end if;
  update private.account_deletion_jobs set state='auth_pending' where id=job.id and state<>'completed';
  return job.owner_id;
 end
$$;
create function public.finish_account_deletion(p_job uuid) returns void language plpgsql security definer set search_path='' as $$
 begin
  if exists(select 1 from private.account_deletion_jobs j join auth.users u on u.id=j.owner_id where j.id=p_job) then
   raise exception using errcode='P0001',message='Auth deletion not complete'; end if;
  update private.account_deletion_jobs set state='completed',completed_at=coalesce(completed_at,now()) where id=p_job;
 end
$$;
-- REVOKE before granting avoids PUBLIC/default Supabase function grants.
do $$ declare f regprocedure; begin
 for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname in ('prepare_media_verification','commit_verified_media','begin_account_deletion','get_deletion_job','list_cleanup_objects','mark_object_deleted','deletion_ready_for_auth','finish_account_deletion') loop
  execute format('revoke all on function %s from public,anon,authenticated',f);
  execute format('grant execute on function %s to service_role',f);
 end loop;
end $$;

-- Optional scheduler support. No extension, schedule, secret or credential is
-- created here. Claims are short and retryable after worker interruption.
alter table private.account_deletion_jobs add column last_attempt_at timestamptz;
alter table private.account_deletion_jobs add column lease_until timestamptz;
create function public.claim_due_deletion_job() returns setof private.account_deletion_jobs
language plpgsql security definer set search_path='' as $$
 declare target uuid;
 begin
  select id into target from private.account_deletion_jobs
   where state<>'completed' and not_before<=clock_timestamp()
    and (lease_until is null or lease_until<clock_timestamp())
   order by last_attempt_at nulls first,created_at for update skip locked limit 1;
  if target is null then return; end if;
  return query update private.account_deletion_jobs set last_attempt_at=clock_timestamp(),lease_until=clock_timestamp()+interval '2 minutes'
   where id=target returning *;
 end
$$;
revoke all on function public.claim_due_deletion_job() from public,anon,authenticated;
grant execute on function public.claim_due_deletion_job() to service_role;

create function public.own_deletion_status()
returns table(job_id uuid,state text,retry_after_seconds integer)
language sql security definer set search_path='' as $$
 select j.id,case when j.state='completed' then 'completed' else 'pending' end,
  greatest(0,ceil(extract(epoch from (j.not_before-clock_timestamp())))::integer)
 from private.account_deletion_jobs j where j.owner_id=auth.uid()
$$;
revoke all on function public.own_deletion_status() from public,anon,authenticated;
grant execute on function public.own_deletion_status() to authenticated;

create function public.resolve_report(p_report uuid,p_state text,p_reason text)
returns void language plpgsql security definer set search_path='' as $$
 declare affected integer;
 begin
  if auth.uid() is null or not private.is_moderator() or exists(select 1 from private.account_deletion_jobs where owner_id=auth.uid()) then
   raise exception using errcode='42501',message='Moderation denied'; end if;
  if p_state is null or p_state not in ('reviewing','resolved','dismissed') or p_reason is null or char_length(trim(p_reason)) not between 5 and 2000 then
   raise exception using errcode='22023',message='Invalid report action'; end if;
  update public.reports set state=p_state where id=p_report;
  get diagnostics affected=row_count;
  if affected<>1 then raise exception using errcode='22023',message='Report not found'; end if;
  insert into public.moderation_actions(actor_id,target_kind,target_id,action,reason)
   values(auth.uid(),'report',p_report,'report_'||p_state,p_reason);
 end
$$;
revoke all on function public.resolve_report(uuid,text,text) from public,anon,authenticated;
grant execute on function public.resolve_report(uuid,text,text) to authenticated;

create function public.moderator_report_target(p_report uuid)
returns table(target_kind text,target_id uuid,title text,body text,display_name text,moderation_state text,missing boolean)
language plpgsql security definer set search_path='' as $$
 declare r public.reports; kind text; target uuid;
 begin
  if auth.uid() is null or not private.is_moderator() or exists(select 1 from private.account_deletion_jobs where owner_id=auth.uid()) then
   raise exception using errcode='42501',message='Moderation denied'; end if;
  select * into r from public.reports where id=p_report;
  if not found then raise exception using errcode='22023',message='Report not found'; end if;
  if r.post_id is not null then
   kind:='post';target:=r.post_id;
   return query select 'post'::text,p.id,p.title,p.body,pr.display_name,p.moderation_state,false
    from public.posts p left join public.profiles pr on pr.id=p.owner_id where p.id=r.post_id;
  elsif r.reply_id is not null then
   kind:='reply';target:=r.reply_id;
   return query select 'reply'::text,p.id,null::text,p.body,pr.display_name,p.moderation_state,false
    from public.replies p left join public.profiles pr on pr.id=p.owner_id where p.id=r.reply_id;
  elsif r.listing_id is not null then
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
revoke all on function public.moderator_report_target(uuid) from public,anon,authenticated;
grant execute on function public.moderator_report_target(uuid) to authenticated;

-- Safe operational classifications, never raw exceptions or storage credentials.
alter table private.account_deletion_jobs add column last_error_code text
 check(last_error_code in ('storage_configuration_required','storage_permission_required','legacy_upload_review_required','auth_configuration_required','database_configuration_required','storage_retry_required','auth_retry_required','database_retry_required','completion_retry_required','cleanup_retry_required'));
alter table private.account_deletion_jobs add column last_failure_at timestamptz;
alter table private.account_deletion_jobs add column failure_count integer not null default 0;
create function public.record_deletion_failure(p_job uuid,p_code text)
returns void language plpgsql security definer set search_path='' as $$
 begin
  update private.account_deletion_jobs set last_error_code=p_code,
   last_failure_at=case when p_code is null then null else clock_timestamp() end,
   failure_count=case when p_code is null then failure_count else failure_count+1 end
   where id=p_job and state<>'completed';
 end
$$;
revoke all on function public.record_deletion_failure(uuid,text) from public,anon,authenticated;
grant execute on function public.record_deletion_failure(uuid,text) to service_role;
drop function public.own_deletion_status();
create function public.own_deletion_status()
returns table(job_id uuid,state text,retry_after_seconds integer,blocker_code text,requires_operator boolean)
language sql security definer set search_path='' as $$
 select j.id,case when j.state='completed' then 'completed' else 'pending' end,
  greatest(0,ceil(extract(epoch from (j.not_before-clock_timestamp())))::integer),j.last_error_code,
  coalesce(j.last_error_code in ('storage_configuration_required','storage_permission_required','legacy_upload_review_required','auth_configuration_required','database_configuration_required'),false)
 from private.account_deletion_jobs j where j.owner_id=auth.uid()
$$;
revoke all on function public.own_deletion_status() from public,anon,authenticated;
grant execute on function public.own_deletion_status() to authenticated;
create or replace function public.claim_due_deletion_job() returns setof private.account_deletion_jobs
language plpgsql security definer set search_path='' as $$
 declare target uuid;
 begin
  select id into target from private.account_deletion_jobs
   where state<>'completed' and not_before<=clock_timestamp()
    and (lease_until is null or lease_until<clock_timestamp())
    and (last_error_code is null or last_error_code not in ('storage_configuration_required','storage_permission_required','legacy_upload_review_required','auth_configuration_required','database_configuration_required')
     or last_attempt_at is null or last_attempt_at<clock_timestamp()-interval '1 hour')
   order by last_attempt_at nulls first,created_at for update skip locked limit 1;
  if target is null then return; end if;
  return query update private.account_deletion_jobs set last_attempt_at=clock_timestamp(),lease_until=clock_timestamp()+interval '2 minutes'
   where id=target returning *;
 end
$$;
create or replace function public.finish_account_deletion(p_job uuid) returns void language plpgsql security definer set search_path='' as $$
 begin
  if exists(select 1 from private.account_deletion_jobs j join auth.users u on u.id=j.owner_id where j.id=p_job) then
   raise exception using errcode='P0001',message='Auth deletion not complete'; end if;
  update private.account_deletion_jobs set state='completed',completed_at=coalesce(completed_at,now()),last_error_code=null,last_failure_at=null where id=p_job;
 end
$$;

-- Destructive authorization is tied to the verified JWT's live Auth session and
-- interactive AMR timestamp, not account-global last_sign_in_at or refreshed iat.
drop function public.begin_account_deletion(uuid);
create function public.begin_account_deletion(p_owner uuid,p_session uuid,p_auth_at bigint)
returns private.account_deletion_jobs language plpgsql security definer set search_path='' as $$
 declare job private.account_deletion_jobs; cutoff timestamptz; session_created timestamptz;
 begin
  perform pg_advisory_xact_lock(hashtextextended(p_owner::text,0));
  select created_at into session_created from auth.sessions where id=p_session and user_id=p_owner
   and (not_after is null or not_after>clock_timestamp()) for share;
  if not found or session_created is null or p_auth_at is null or to_timestamp(p_auth_at)<clock_timestamp()-interval '10 minutes'
   or to_timestamp(p_auth_at)>clock_timestamp()+interval '30 seconds'
   or to_timestamp(p_auth_at)<session_created-interval '60 seconds' then
   raise exception using errcode='42501',message='Recent authentication required'; end if;
  select * into job from private.account_deletion_jobs where owner_id=p_owner;
  if found then return job; end if;
  if not exists(select 1 from auth.users where id=p_owner) then raise exception using errcode='42501',message='Account not found'; end if;
  select greatest(now(),coalesce(max(safe_delete_after),now())) into cutoff from private.object_registry where owner_id=p_owner and deleted_at is null;
  insert into private.account_deletion_jobs(owner_id,not_before) values(p_owner,cutoff) returning * into job;
  return job;
 end
$$;
revoke all on function public.begin_account_deletion(uuid,uuid,bigint) from public,anon,authenticated;
grant execute on function public.begin_account_deletion(uuid,uuid,bigint) to service_role;
