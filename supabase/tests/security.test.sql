-- Run with `supabase test db` against a disposable local Supabase database only.
begin;
create extension if not exists pgtap with schema extensions;
select plan(24);
insert into auth.users(id) values ('00000000-0000-4000-8000-000000000001'),('00000000-0000-4000-8000-000000000002');
insert into public.profiles(id,display_name,accepted_terms_at) values
 ('00000000-0000-4000-8000-000000000001','Test A',now()),('00000000-0000-4000-8000-000000000002','Test B',now());
insert into public.posts(id,owner_id,kind,title,body) values
 ('10000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001','education','Test post','Body'),
 ('10000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000001','consultation','Test question','Body');
insert into public.replies(id,post_id,owner_id,body) values
 ('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001','Reply');
insert into public.profile_contacts values('00000000-0000-4000-8000-000000000001','synthetic@test.invalid','email',false,null);
insert into public.reports(reporter_id,post_id,reason) values('00000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','Test reason');
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000002',true);
select is((select count(*)::integer from public.profile_contacts),0,'private contacts hidden');
select is((select count(*)::integer from public.reports),0,'other reports hidden');
select results_eq($$update public.posts set body='Hacked' where id='10000000-0000-4000-8000-000000000001' returning id$$,$$select null::uuid where false$$,'cannot edit another author');
select throws_ok($$insert into public.moderator_roles values('00000000-0000-4000-8000-000000000002','admin')$$,'42501',null,'cannot self-promote');
select throws_ok($$select public.moderate_content('post','10000000-0000-4000-8000-000000000001',true,'Test reason')$$,'42501',null,'moderation needs trusted role');
select throws_ok($$insert into public.listings(kind,title,description,quantity) values('offer','No price','Description',1)$$,'23514',null,'offer requires price');
select throws_ok($$insert into public.listings(kind,title,description,quantity,price) values('offer','NaN price','Description',1,'NaN')$$,'23514',null,'NaN price denied');
select lives_ok($$insert into public.listings(kind,title,description,quantity) values('request','Wanted bird','Description',1)$$,'request may omit budget');
select throws_ok($$insert into public.replies(post_id,parent_id,body) values('10000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000001','Wrong parent')$$,'23514',null,'same post parent required');
select throws_ok($$update public.replies set parent_id=id$$,'42501',null,'immutable parents prevent cycles');
select throws_ok($$update public.posts set created_at=now()$$,'42501',null,'feed timestamp immutable');
select throws_ok($$update public.listings set expires_at=now()+interval '100 years'$$,'42501',null,'expiry immutable');
insert into public.user_blocks(blocker_id,blocked_id) values('00000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000001');
select is((select count(*)::integer from public.posts),0,'block hides posts via API');
select throws_ok($$insert into public.replies(post_id,body) values('10000000-0000-4000-8000-000000000001','Blocked reply')$$,'42501',null,'block denies replying');
select throws_ok($$update public.upload_intents set state='verified'$$,'42501',null,'clients cannot verify media');
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
select lives_ok($$select public.reserve_upload('10000000-0000-4000-8000-000000000001',null,100,'image/png')$$,'first reservation accepted');
select public.reserve_upload('10000000-0000-4000-8000-000000000001',null,100,'image/png');
select public.reserve_upload('10000000-0000-4000-8000-000000000001',null,100,'image/png');
select throws_ok($$select public.reserve_upload('10000000-0000-4000-8000-000000000001',null,100,'image/png')$$,'P0001','Attachment limit reached','fourth image denied');
select throws_ok($$select public.reserve_upload('10000000-0000-4000-8000-000000000002',null,6000000,'image/png')$$,'22023','Invalid upload','oversize denied');
select lives_ok($test$
 do $body$ declare target uuid; begin
  for i in 1..17 loop
   insert into public.posts(kind,title,body) values('education','Quota target','Body') returning id into target;
   perform public.reserve_upload(target,null,100,'image/png');
   delete from public.posts where id=target;
  end loop;
 end $body$;
$test$,'consume daily quota while deleting each uploaded parent');
select throws_ok($$select public.reserve_upload('10000000-0000-4000-8000-000000000002',null,100,'image/png')$$,'P0001','Upload quota reached','parent deletion cannot reset upload quota');
select throws_ok($$delete from private.upload_events$$,'42501',null,'upload ledger is private');
insert into public.reports(post_id,reason) values('10000000-0000-4000-8000-000000000002','Report survives target deletion');
delete from public.posts where id='10000000-0000-4000-8000-000000000002';
select is((select count(*)::integer from public.reports where post_id='10000000-0000-4000-8000-000000000002'),1,'author cannot erase moderation queue by deleting target');
select throws_ok($$insert into public.reports(post_id,reason) values('10000000-0000-4000-8000-000000000002','Missing target')$$,'23514','Invalid report target','new reports require visible existing target');
set local role anon;
select throws_ok($$select public.reveal_listing_contact('10000000-0000-4000-8000-000000000001',true)$$,'42501',null,'anonymous contact access denied');
select * from finish();
rollback;
