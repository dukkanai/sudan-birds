-- Run with `supabase test db` against a disposable local Supabase database only.
begin;
create extension if not exists pgtap with schema extensions;
select plan(21);
insert into auth.users(id) values ('00000000-0000-4000-8000-000000000001'),('00000000-0000-4000-8000-000000000002');
insert into public.profiles(id,display_name,accepted_terms_at) values
 ('00000000-0000-4000-8000-000000000001','Test A',now()),('00000000-0000-4000-8000-000000000002','Test B',now());
insert into public.listings(id,owner_id,kind,title,description,quantity) values
 ('10000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001','request','Test listing','Body',1),
 ('10000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000001','request','Second listing','Body',1);
insert into public.profile_contacts values('00000000-0000-4000-8000-000000000001','synthetic@test.invalid','email',false,null);
insert into public.reports(reporter_id,listing_id,reason) values('00000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','Test reason');
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000002',true);
select is((select count(*)::integer from public.profile_contacts),0,'private contacts hidden');
select is((select count(*)::integer from public.reports),0,'other reports hidden');
select results_eq($$update public.listings set description='Hacked' where id='10000000-0000-4000-8000-000000000001' returning id$$,$$select null::uuid where false$$,'cannot edit another author');
select throws_ok($$insert into public.moderator_roles values('00000000-0000-4000-8000-000000000002','admin')$$,'42501',null,'cannot self-promote');
select throws_ok($$select public.moderate_content('listing','10000000-0000-4000-8000-000000000001',true,'Test reason')$$,'42501',null,'moderation needs trusted role');
select throws_ok($$insert into public.listings(kind,title,description,quantity) values('offer','No price','Description',1)$$,'23514',null,'offer requires price');
select throws_ok($$insert into public.listings(kind,title,description,quantity,price) values('offer','NaN price','Description',1,'NaN')$$,'23514',null,'NaN price denied');
select lives_ok($$insert into public.listings(kind,title,description,quantity) values('request','Wanted bird','Description',1)$$,'request may omit budget');
select throws_ok($$update public.listings set created_at=now()$$,'42501',null,'feed timestamp immutable');
select throws_ok($$update public.listings set expires_at=now()+interval '100 years'$$,'42501',null,'expiry immutable');
insert into public.user_blocks(blocker_id,blocked_id) values('00000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000001');
select is((select count(*)::integer from public.listings where owner_id='00000000-0000-4000-8000-000000000001'),0,'block hides listings via API');
select throws_ok($$update public.upload_intents set state='verified'$$,'42501',null,'clients cannot verify media');
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
select lives_ok($$select public.reserve_upload('10000000-0000-4000-8000-000000000001',100,'image/jpeg')$$,'first reservation accepted');
select public.reserve_upload('10000000-0000-4000-8000-000000000001',100,'image/jpeg');
select public.reserve_upload('10000000-0000-4000-8000-000000000001',100,'image/jpeg');
select throws_ok($$select public.reserve_upload('10000000-0000-4000-8000-000000000001',100,'image/jpeg')$$,'P0001','Attachment limit reached','fourth image denied');
select throws_ok($$select public.reserve_upload('10000000-0000-4000-8000-000000000002',6000000,'image/jpeg')$$,'22023','Invalid upload','oversize denied');
select lives_ok($test$
 do $body$ declare target uuid; begin
  for i in 1..17 loop
   insert into public.listings(kind,title,description,quantity) values('request','Quota target','Body',1) returning id into target;
   perform public.reserve_upload(target,100,'image/jpeg');
   delete from public.listings where id=target;
  end loop;
 end $body$;
$test$,'consume daily quota while deleting each uploaded parent');
select throws_ok($$select public.reserve_upload('10000000-0000-4000-8000-000000000002',100,'image/jpeg')$$,'P0001','Upload quota reached','parent deletion cannot reset upload quota');
select throws_ok($$delete from private.upload_events$$,'42501',null,'upload ledger is private');
insert into public.reports(listing_id,reason) values('10000000-0000-4000-8000-000000000002','Report survives target deletion');
delete from public.listings where id='10000000-0000-4000-8000-000000000002';
select is((select count(*)::integer from public.reports where listing_id='10000000-0000-4000-8000-000000000002'),1,'author cannot erase moderation queue by deleting target');
select throws_ok($$insert into public.reports(listing_id,reason) values('10000000-0000-4000-8000-000000000002','Missing target')$$,'23514','Invalid report target','new reports require visible existing target');
set local role anon;
select throws_ok($$select public.reveal_listing_contact('10000000-0000-4000-8000-000000000001',true)$$,'42501',null,'anonymous contact access denied');
select * from finish();
rollback;
