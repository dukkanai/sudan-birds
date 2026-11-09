-- Final schema contract, including rejection rather than silently ignoring old inputs.
begin;
create extension if not exists pgtap with schema extensions;
select plan(12);
select ok(to_regclass('public.posts') is null,'posts removed');
select ok(to_regclass('public.replies') is null,'replies removed');
select ok(to_regclass('public.topics') is null,'topics removed');
select is((select count(*)::integer from information_schema.columns where table_schema='public' and table_name in ('media','upload_intents','reports') and column_name in ('post_id','reply_id')),0,'removed target columns absent');
select ok(to_regprocedure('public.reserve_upload(uuid,uuid,integer,text)') is null,'old overload removed');
select ok(to_regprocedure('public.reserve_upload(uuid,integer,text)') is not null,'listing-only upload RPC exists');
select ok(to_regprocedure('private.validate_reply()') is null,'reply helper removed');
select is((select count(*)::integer from private.publish_limits where table_name in ('posts','replies')),0,'unused quota settings removed');
select is((select count(*)::integer from information_schema.columns where table_schema='public' and table_name in ('media','upload_intents') and column_name='listing_id' and is_nullable='NO'),2,'all media and intents require listing');
set local role authenticated;
select throws_ok($$select public.reserve_upload(null,null,100,'image/jpeg')$$,'42883',null,'old upload invocation rejected');
select throws_ok($$insert into public.reports(post_id,reason) values(gen_random_uuid(),'Old API payload')$$,'42703',null,'old report payload rejected');
select throws_ok($$insert into public.reports(reply_id,reason) values(gen_random_uuid(),'Old API payload')$$,'42703',null,'old reply report payload rejected');
select * from finish();
rollback;
