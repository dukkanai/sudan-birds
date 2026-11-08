-- Initial local foundation. Apply through a Supabase migration runner, never a mobile client.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated, anon;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(trim(display_name)) between 2 and 80),
  accepted_terms_at timestamptz,
  created_at timestamptz not null default now()
);
create table public.profile_contacts (
  owner_id uuid primary key references public.profiles(id) on delete cascade,
  contact_value text not null check (char_length(contact_value) between 3 and 160),
  contact_kind text not null check (contact_kind in ('phone','whatsapp','email')),
  reveal_consent boolean not null default false,
  consent_at timestamptz,
  check (not reveal_consent or consent_at is not null)
);
create table public.bird_types (id bigint generated always as identity primary key, name_ar text not null unique);
create table public.topics (id bigint generated always as identity primary key, name_ar text not null unique);
create table public.locations (id bigint generated always as identity primary key, state_ar text not null, city_ar text not null, unique(state_ar,city_ar));
create table public.moderator_roles (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  role text not null check (role in ('moderator','admin'))
);
create table public.user_blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id,blocked_id), check (blocker_id <> blocked_id)
);
create function private.is_moderator() returns boolean language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.moderator_roles where user_id = auth.uid())
$$;
create function private.visible_author(author uuid) returns boolean language sql stable security definer set search_path = '' as $$
 select not exists(select 1 from public.user_blocks b where
 (b.blocker_id = auth.uid() and b.blocked_id = author) or
 (b.blocked_id = auth.uid() and b.blocker_id = author))
$$;
create function private.can_publish() returns boolean language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.profiles where id=auth.uid() and accepted_terms_at is not null)
$$;
create table public.listings (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
 kind text not null check(kind in ('request','offer')),
 title text not null check(char_length(trim(title)) between 3 and 120),
 description text not null check(char_length(trim(description)) between 1 and 5000),
 bird_type_id bigint references public.bird_types(id),
 location_id bigint references public.locations(id),
 quantity integer not null check(quantity between 1 and 100000),
 price numeric(14,2) check(price >= 0 and price < 1000000000000),
 currency text not null default 'SDG' check(currency ~ '^[A-Z]{3}$'),
 price_unit text not null default 'bird' check(price_unit in ('bird','group')),
 negotiable boolean not null default false,
 age_value integer check(age_value between 0 and 10000),
 age_unit text check(age_unit in ('day','month','year')),
 status text not null default 'active' check(status in ('active','reserved','fulfilled','closed','expired')),
 moderation_state text not null default 'visible' check(moderation_state in ('visible','hidden')),
 created_at timestamptz not null default now(),
 expires_at timestamptz not null default now()+interval '30 days',
 check(kind <> 'offer' or price is not null),
 check((age_value is null) = (age_unit is null)),
 check(expires_at > created_at)
);
create table public.posts (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
 kind text not null check(kind in ('education','consultation')),
 title text not null check(char_length(trim(title)) between 3 and 120),
 body text not null check(char_length(trim(body)) between 1 and 10000),
 topic_id bigint references public.topics(id),
 bird_type_id bigint references public.bird_types(id),
 moderation_state text not null default 'visible' check(moderation_state in ('visible','hidden')),
 created_at timestamptz not null default now()
);
create table public.replies (
 id uuid primary key default gen_random_uuid(),
 post_id uuid not null references public.posts(id) on delete cascade,
 owner_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
 parent_id uuid,
 body text not null check(char_length(trim(body)) between 1 and 5000),
 moderation_state text not null default 'visible' check(moderation_state in ('visible','hidden')),
 created_at timestamptz not null default now(),
 unique(id,post_id),
 foreign key(parent_id,post_id) references public.replies(id,post_id),
 check(parent_id is null or parent_id <> id)
);
-- Parent links and identity are immutable (column grants below). New reply parents must
-- already exist: no deferred FK and no post-hoc reparenting means cycles cannot be formed.
create function private.validate_reply() returns trigger language plpgsql set search_path = '' as $$
 begin
  if new.parent_id is not null and not exists(select 1 from public.replies where id=new.parent_id and post_id=new.post_id) then
   raise exception using errcode='23514', message='Invalid reply parent';
  end if;
  return new;
 end
$$;
create trigger reply_parent before insert on public.replies for each row execute function private.validate_reply();
create table public.reports (
 id uuid primary key default gen_random_uuid(),
 reporter_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
 post_id uuid references public.posts(id) on delete cascade,
 reply_id uuid references public.replies(id) on delete cascade,
 account_id uuid references public.profiles(id) on delete cascade,
 reason text not null check(char_length(trim(reason)) between 5 and 2000),
 state text not null default 'open' check(state in ('open','reviewing','resolved','dismissed')),
 created_at timestamptz not null default now(),
 check(num_nonnulls(post_id,reply_id,account_id)=1)
);
create table public.moderation_actions (
 id uuid primary key default gen_random_uuid(), actor_id uuid not null references public.profiles(id),
 target_kind text not null, target_id uuid not null, action text not null, reason text not null,
 created_at timestamptz not null default now()
);
create table public.upload_intents (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.profiles(id) on delete cascade,
 post_id uuid references public.posts(id) on delete cascade,
 listing_id uuid references public.listings(id) on delete cascade,
 object_key text not null unique,
 expected_bytes integer not null check(expected_bytes between 1 and 5242880),
 expected_mime text not null check(expected_mime in ('image/jpeg','image/png','image/webp')),
 state text not null default 'pending' check(state in ('pending','verified','rejected','expired')),
 created_at timestamptz not null default now(), expires_at timestamptz not null default now()+interval '5 minutes',
 check(num_nonnulls(post_id,listing_id)=1)
);
create table public.media (
 id uuid primary key references public.upload_intents(id),
 owner_id uuid not null references public.profiles(id) on delete cascade,
 post_id uuid references public.posts(id) on delete cascade,
 listing_id uuid references public.listings(id) on delete cascade,
 object_key text not null unique,
 byte_size integer not null check(byte_size between 1 and 5242880),
 mime_type text not null check(mime_type in ('image/jpeg','image/png','image/webp')),
 width integer not null check(width between 1 and 4096), height integer not null check(height between 1 and 4096),
 alt_text text not null default '' check(char_length(alt_text)<=500),
 verified_at timestamptz not null,
 check(num_nonnulls(post_id,listing_id)=1)
);
create index listings_feed on public.listings(kind,status,created_at desc,id desc);
create index listings_filter on public.listings(bird_type_id,location_id,currency,price);
create index posts_feed on public.posts(created_at desc,id desc);
create index replies_post on public.replies(post_id,created_at,id);
create index blocks_reverse on public.user_blocks(blocked_id,blocker_id);
create index upload_owner_time on public.upload_intents(owner_id,created_at);
create index reports_state on public.reports(state,created_at);
create index listings_text on public.listings using gin(to_tsvector('simple',title || ' ' || description));
create index posts_text on public.posts using gin(to_tsvector('simple',title || ' ' || body));

-- Deny by default: no implicit Supabase default table/function privileges.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.is_moderator(), private.visible_author(uuid), private.can_publish() to anon, authenticated;
do $$ declare t text; begin
 foreach t in array array['profiles','profile_contacts','bird_types','topics','locations','moderator_roles','user_blocks','listings','posts','replies','reports','moderation_actions','upload_intents','media'] loop
 execute format('alter table public.%I enable row level security',t);
 end loop;
end $$;
grant select on public.profiles, public.bird_types,public.topics,public.locations,public.listings,public.posts,public.replies,public.media to anon,authenticated;
grant select on public.profile_contacts,public.user_blocks,public.reports,public.moderator_roles,public.moderation_actions,public.upload_intents to authenticated;
grant insert(id,display_name,accepted_terms_at), update(display_name,accepted_terms_at) on public.profiles to authenticated;
grant insert(owner_id,contact_value,contact_kind,reveal_consent,consent_at), update(contact_value,contact_kind,reveal_consent,consent_at),delete on public.profile_contacts to authenticated;
grant insert(blocker_id,blocked_id),delete on public.user_blocks to authenticated;
grant insert(kind,title,description,bird_type_id,location_id,quantity,price,currency,price_unit,negotiable,age_value,age_unit),
 update(title,description,bird_type_id,location_id,quantity,price,currency,price_unit,negotiable,age_value,age_unit,status),delete on public.listings to authenticated;
grant insert(kind,title,body,topic_id,bird_type_id),update(title,body,topic_id,bird_type_id),delete on public.posts to authenticated;
grant insert(post_id,parent_id,body),update(body) on public.replies to authenticated;
grant insert(post_id,reply_id,account_id,reason) on public.reports to authenticated;
create policy profiles_read on public.profiles for select using(private.visible_author(id));
create policy profiles_insert on public.profiles for insert to authenticated with check(id=auth.uid());
create policy profiles_update on public.profiles for update to authenticated using(id=auth.uid()) with check(id=auth.uid());
create policy contacts_owner on public.profile_contacts for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
create policy bird_types_read on public.bird_types for select using(true);
create policy topics_read on public.topics for select using(true);
create policy locations_read on public.locations for select using(true);
create policy roles_read on public.moderator_roles for select to authenticated using(user_id=auth.uid());
create policy blocks_owner on public.user_blocks for all to authenticated using(blocker_id=auth.uid()) with check(blocker_id=auth.uid());
create policy listings_read on public.listings for select using((moderation_state='visible' or owner_id=auth.uid()) and private.visible_author(owner_id));
create policy listings_insert on public.listings for insert to authenticated with check(owner_id=auth.uid() and private.can_publish() and moderation_state='visible');
create policy listings_update on public.listings for update to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
create policy listings_delete on public.listings for delete to authenticated using(owner_id=auth.uid());
create policy posts_read on public.posts for select using((moderation_state='visible' or owner_id=auth.uid()) and private.visible_author(owner_id));
create policy posts_insert on public.posts for insert to authenticated with check(owner_id=auth.uid() and private.can_publish() and moderation_state='visible');
create policy posts_update on public.posts for update to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
create policy posts_delete on public.posts for delete to authenticated using(owner_id=auth.uid());
create policy replies_read on public.replies for select using((moderation_state='visible' or owner_id=auth.uid()) and private.visible_author(owner_id) and exists(select 1 from public.posts p where p.id=post_id and p.moderation_state='visible'));
create policy replies_insert on public.replies for insert to authenticated with check(owner_id=auth.uid() and private.can_publish() and moderation_state='visible' and exists(select 1 from public.posts p where p.id=post_id and p.moderation_state='visible'));
create policy replies_update on public.replies for update to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
create policy reports_read on public.reports for select to authenticated using(reporter_id=auth.uid() or private.is_moderator());
create policy reports_insert on public.reports for insert to authenticated with check(reporter_id=auth.uid() and state='open');
create policy actions_read on public.moderation_actions for select to authenticated using(private.is_moderator());
create policy upload_owner_read on public.upload_intents for select to authenticated using(owner_id=auth.uid());
create policy media_read on public.media for select using(
 (post_id is not null and exists(select 1 from public.posts p where p.id=post_id and p.moderation_state='visible')) or
 (listing_id is not null and exists(select 1 from public.listings l where l.id=listing_id and l.moderation_state='visible')));

-- Contact revelation is authenticated, explicitly requested, consented by the owner,
-- restricted to a visible listing and checked against BOTH directions of blocking.
create function public.reveal_listing_contact(p_listing uuid,p_explicit_consent boolean)
returns table(contact_kind text,contact_value text) language plpgsql security definer set search_path='' as $$
 declare v_owner uuid;
 begin
  if auth.uid() is null or p_explicit_consent is distinct from true then
   raise exception using errcode='42501',message='Contact access denied';
  end if;
  select owner_id into v_owner from public.listings where id=p_listing and moderation_state='visible' and expires_at>now() and status in ('active','reserved');
  if v_owner is null or not private.visible_author(v_owner) then
   raise exception using errcode='42501',message='Contact access denied';
  end if;
  return query select c.contact_kind,c.contact_value from public.profile_contacts c where c.owner_id=v_owner and c.reveal_consent and c.consent_at is not null;
 end
$$;
revoke all on function public.reveal_listing_contact(uuid,boolean) from public,anon;
grant execute on function public.reveal_listing_contact(uuid,boolean) to authenticated;

-- The serialized per-owner reservation protects the 3 attachment limit and daily
-- upload budget even under parallel requests. Pending, unexpired slots count.
create table private.upload_events (user_id uuid not null references auth.users(id) on delete cascade, created_at timestamptz not null default now());
create index upload_events_lookup on private.upload_events(user_id,created_at);
revoke all on private.upload_events from public,anon,authenticated;
grant all on private.upload_events to service_role;
create function public.reserve_upload(p_post uuid,p_listing uuid,p_bytes integer,p_mime text)
returns public.upload_intents language plpgsql security definer set search_path='' as $$
 declare u uuid:=auth.uid(); v public.upload_intents; used integer;
 begin
  if u is null or not private.can_publish() then raise exception using errcode='42501',message='Upload denied'; end if;
  if num_nonnulls(p_post,p_listing)<>1 or p_bytes not between 1 and 5242880 or p_bytes is null or p_mime is null or p_mime not in ('image/jpeg','image/png','image/webp') then
   raise exception using errcode='22023',message='Invalid upload';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(u::text,0));
  if not ((p_post is not null and exists(select 1 from public.posts where id=p_post and owner_id=u and moderation_state='visible')) or
    (p_listing is not null and exists(select 1 from public.listings where id=p_listing and owner_id=u and moderation_state='visible'))) then
   raise exception using errcode='42501',message='Upload denied';
  end if;
  select count(*) into used from private.upload_events where user_id=u and created_at>now()-interval '24 hours';
  if used>=20 then raise exception using errcode='P0001',message='Upload quota reached'; end if;
  select count(*) into used from public.upload_intents where owner_id=u and (post_id=p_post or listing_id=p_listing) and (state='verified' or (state='pending' and expires_at>now()));
  if used>=3 then raise exception using errcode='P0001',message='Attachment limit reached'; end if;
  insert into public.upload_intents(owner_id,post_id,listing_id,expected_bytes,expected_mime,object_key)
  values(u,p_post,p_listing,p_bytes,p_mime,'quarantine/'||u::text||'/'||gen_random_uuid()::text) returning * into v;
  insert into private.upload_events(user_id) values(u);
  return v;
 end
$$;
revoke all on function public.reserve_upload(uuid,uuid,integer,text) from public,anon;
grant execute on function public.reserve_upload(uuid,uuid,integer,text) to authenticated;

alter table public.listings add constraint listing_status_by_kind check(kind='offer' or status<>'reserved');
alter table public.reports add column listing_id uuid references public.listings(id) on delete cascade;
-- Replace the initial target cardinality check after adding marketplace reports.
alter table public.reports drop constraint reports_check;
alter table public.reports add constraint reports_one_target check(num_nonnulls(post_id,reply_id,account_id,listing_id)=1);
grant insert(listing_id) on public.reports to authenticated;

create function public.moderate_content(p_kind text,p_id uuid,p_hidden boolean,p_reason text)
returns void language plpgsql security definer set search_path='' as $$
 declare changed integer;
 begin
  if auth.uid() is null or not private.is_moderator() then raise exception using errcode='42501',message='Moderation denied'; end if;
  if p_kind not in ('post','reply','listing') or p_kind is null or p_hidden is null or p_reason is null or char_length(trim(p_reason)) not between 5 and 2000 then
   raise exception using errcode='22023',message='Invalid moderation action';
  end if;
  if p_kind='post' then update public.posts set moderation_state=case when p_hidden then 'hidden' else 'visible' end where id=p_id;
  elsif p_kind='reply' then update public.replies set moderation_state=case when p_hidden then 'hidden' else 'visible' end where id=p_id;
  else update public.listings set moderation_state=case when p_hidden then 'hidden' else 'visible' end where id=p_id; end if;
  get diagnostics changed=row_count;
  if changed<>1 then raise exception using errcode='22023',message='Content not found'; end if;
  insert into public.moderation_actions(actor_id,target_kind,target_id,action,reason) values(auth.uid(),p_kind,p_id,case when p_hidden then 'hide' else 'restore' end,p_reason);
 end
$$;
revoke all on function public.moderate_content(text,uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.moderate_content(text,uuid,boolean,text) to authenticated;
-- Explicit server rights; never expose this role key to the app.
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;

-- Configurable server-only rolling limits. A private event ledger and a per-user
-- transaction lock make concurrent inserts obey the same budget.
create table private.publish_limits (table_name text primary key, max_per_day integer not null check(max_per_day between 1 and 1000));
insert into private.publish_limits values('posts',50),('listings',50),('replies',200),('reports',20);
revoke all on private.publish_limits from public,anon,authenticated;
grant all on private.publish_limits to service_role;
create table private.publish_events (user_id uuid not null references auth.users(id) on delete cascade, table_name text not null, created_at timestamptz not null default now());
create index publish_events_lookup on private.publish_events(user_id,table_name,created_at);
revoke all on private.publish_events from public,anon,authenticated;
grant all on private.publish_events to service_role;
create function private.enforce_publish_limit() returns trigger language plpgsql security definer set search_path='' as $$
 declare u uuid:=auth.uid(); n integer; maximum integer;
 begin
  if u is null then return new; end if; -- Trusted server maintenance; clients fail RLS.
  perform pg_advisory_xact_lock(hashtextextended(u::text,0));
  select max_per_day into maximum from private.publish_limits where table_name=TG_TABLE_NAME;
  if maximum is null then raise exception using errcode='P0001',message='Publishing unavailable'; end if;
  select count(*) into n from private.publish_events where user_id=u and table_name=TG_TABLE_NAME and created_at>now()-interval '24 hours';
  if n>=maximum then raise exception using errcode='P0001',message='Publishing quota reached'; end if;
  insert into private.publish_events(user_id,table_name) values(u,TG_TABLE_NAME);
  return new;
 end
$$;
revoke all on function private.enforce_publish_limit() from public,anon,authenticated;
create trigger posts_limit before insert on public.posts for each row execute function private.enforce_publish_limit();
create trigger listings_limit before insert on public.listings for each row execute function private.enforce_publish_limit();
create trigger replies_limit before insert on public.replies for each row execute function private.enforce_publish_limit();
create trigger reports_limit before insert on public.reports for each row execute function private.enforce_publish_limit();

-- Keep the moderation queue when an author removes the target. Retain only the
-- target UUID, not a snapshot of deleted personal content. Reporter account deletion
-- still removes its submitted reports pending the final retention policy.
alter table public.reports drop constraint reports_post_id_fkey;
alter table public.reports drop constraint reports_reply_id_fkey;
alter table public.reports drop constraint reports_account_id_fkey;
alter table public.reports drop constraint reports_listing_id_fkey;
create function private.validate_report_target() returns trigger language plpgsql set search_path='' as $$
 begin
  if not (
   (new.post_id is not null and exists(select 1 from public.posts where id=new.post_id)) or
   (new.reply_id is not null and exists(select 1 from public.replies where id=new.reply_id)) or
   (new.listing_id is not null and exists(select 1 from public.listings where id=new.listing_id)) or
   (new.account_id is not null and exists(select 1 from public.profiles where id=new.account_id))
  ) then raise exception using errcode='23514',message='Invalid report target'; end if;
  return new;
 end
$$;
revoke all on function private.validate_report_target() from public,anon,authenticated;
create trigger report_target before insert on public.reports for each row execute function private.validate_report_target();
