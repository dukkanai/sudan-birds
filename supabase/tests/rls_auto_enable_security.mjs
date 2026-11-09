// Disposable PostgreSQL only; no hosted connections, users, or credentials.
// Run with the same EMBEDDED_POSTGRES_MODULE dependency as embedded_security.mjs.
import assert from 'node:assert/strict';
import {mkdtemp, readFile, readdir, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
const {default: EmbeddedPostgres} = await import(process.env.EMBEDDED_POSTGRES_MODULE || 'embedded-postgres');
const dir = await mkdtemp(join(tmpdir(), 'birds-helper-'));
const pg = new EmbeddedPostgres({databaseDir:join(dir,'data'), user:'postgres', password:'synthetic-test-only', port:15440, persistent:false, createPostgresUser:false, initdbFlags:['--encoding=UTF8'], postgresFlags:['-c','unix_socket_directories='], onLog:()=>{}, onError:console.error});
let client; let passed=0;
const migration = await readFile(new URL('../migrations/20261109142454_harden_rls_auto_enable.sql', import.meta.url),'utf8');
const q = (sql, params) => client.query(sql, params);
async function check(label, fn) { await fn(); console.log(`ok ${++passed} - ${label}`); }
async function rejectedMigration() { await assert.rejects(q(migration), e=>e.code==='55000'); await q('rollback'); }
const helper = `create function public.rls_auto_enable() returns event_trigger
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare cmd record; tbl name;
begin
 for cmd in select * from pg_event_trigger_ddl_commands()
 where command_tag in ('CREATE TABLE','CREATE TABLE AS','SELECT INTO')
 and object_type in ('table','partitioned table') loop
  if cmd.schema_name is not null and cmd.schema_name in ('public')
  and cmd.schema_name not in ('pg_catalog','information_schema')
  and cmd.schema_name not like 'pg_toast%' and cmd.schema_name not like 'pg_temp%' then
   begin
    select c.relname into tbl from pg_catalog.pg_class c where c.oid=cmd.objid;
    execute format('alter table if exists %I.%I enable row level security',cmd.schema_name,tbl);
   exception when others then raise log 'rls_auto_enable fixture failed'; end;
  end if;
 end loop;
end; $$;`;
const snapshot = async () => (await q(`select p.oid,pg_get_functiondef(p.oid) as definition,
 p.proowner,p.prorettype,p.proconfig,e.oid as trigger_oid,e.evtname,e.evtevent,e.evtenabled,e.evttags,e.evtfoid
 from pg_proc p join pg_event_trigger e on e.evtfoid=p.oid
 where p.oid='public.rls_auto_enable()'::regprocedure`)).rows;
const appGrants = async () => (await q(`select p.oid::regprocedure::text as signature,p.proacl,
 has_function_privilege('anon',p.oid,'execute') as anon,
 has_function_privilege('authenticated',p.oid,'execute') as authenticated,
 has_function_privilege('service_role',p.oid,'execute') as service
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname in ('public','private') and p.proname <> 'rls_auto_enable' order by p.oid`)).rows;
try {
 await pg.initialise(); await pg.start(); client=pg.getPgClient(); await client.connect();
 await q('create role anon; create role authenticated; create role service_role bypassrls;');
 await check('fresh reset without platform helper is a safe no-op',async()=>{
  await q(migration); assert.equal((await q("select to_regprocedure('public.rls_auto_enable()') as helper")).rows[0].helper,null);
 });
 await check('wrong return type fails without changing ACL',async()=>{
  await q('create function public.rls_auto_enable() returns void language sql as $$select$$;');
  await rejectedMigration();
  assert.equal((await q("select has_function_privilege('anon','public.rls_auto_enable()','execute') as allowed")).rows[0].allowed,true);
  await q('drop function public.rls_auto_enable()');
 });
 await check('unexpected argument overload fails closed',async()=>{
  await q('create function public.rls_auto_enable(integer) returns void language sql as $$select$$;');
  await rejectedMigration(); await q('drop function public.rls_auto_enable(integer)');
 });
 await q(`create schema auth; create table auth.users(id uuid primary key);
 create table auth.sessions(id uuid primary key,user_id uuid references auth.users(id) on delete cascade,created_at timestamptz not null default now(),not_after timestamptz);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 grant usage on schema auth to anon,authenticated; grant execute on function auth.uid() to anon,authenticated;`);
 for (const file of (await readdir(new URL('../migrations/',import.meta.url))).filter(n=>n.endsWith('.sql')).sort()) {
  await q(await readFile(new URL('../migrations/'+file,import.meta.url),'utf8'));
 }
 await q(helper);
 await q("create event trigger ensure_rls on ddl_command_end when tag in ('CREATE TABLE','CREATE TABLE AS','SELECT INTO') execute function public.rls_auto_enable()");
 await check('PUBLIC default exposes execute but not ordinary event-function invocation',async()=>{
  assert.equal((await q("select proacl from pg_proc where oid='public.rls_auto_enable()'::regprocedure")).rows[0].proacl,null);
  await q('set role anon');
  await assert.rejects(q('select public.rls_auto_enable()'),e=>e.code==='0A000' && /trigger functions can only be called as triggers/.test(e.message));
  await q('reset role');
 });
 await check('additional overload beside valid helper fails closed',async()=>{
  await q('create function public.rls_auto_enable(integer) returns void language sql as $$select$$;');
  await rejectedMigration();
  assert.equal((await q("select has_function_privilege('anon','public.rls_auto_enable()','execute') as allowed")).rows[0].allowed,true);
  await q('drop function public.rls_auto_enable(integer)');
 });
 const before=await snapshot(); const grants=await appGrants();
 assert.equal(grants.filter(r=>r.authenticated && /^((public\.)?)(is_cleanup_admin|moderate_content|moderator_report_target|own_deletion_status|reserve_upload|resolve_report|reveal_listing_contact)\(/.test(r.signature)).length,7);
 await check('PUBLIC and direct API grants removed; all application grants unchanged',async()=>{
  await q('grant execute on function public.rls_auto_enable() to anon,authenticated,service_role');
  await q(migration);
  for (const role of ['anon','authenticated']) {
   assert.equal((await q("select has_function_privilege($1,'public.rls_auto_enable()','execute') as allowed",[role])).rows[0].allowed,false);
   await q(`set role ${role}`); await assert.rejects(q('select public.rls_auto_enable()'),e=>e.code==='42501'); await q('reset role');
  }
  assert.equal((await q("select has_function_privilege('service_role','public.rls_auto_enable()','execute') as allowed")).rows[0].allowed,true);
  assert.deepEqual(await appGrants(),grants); assert.deepEqual(await snapshot(),before);
 });
 await check('idempotent migration preserves helper and enabled trigger identities',async()=>{
  await q(migration); assert.deepEqual(await snapshot(),before);
 });
 await check('existing event trigger still enables RLS for all three DDL tags',async()=>{
  // Non-superuser, no EXECUTE privilege: proves runtime behavior, not owner bypass.
  await q('create role ddl_fixture; grant usage,create on schema public to ddl_fixture; set role ddl_fixture');
  await q('create table public.helper_create(id integer)');
  await q('create table public.helper_ctas as select 1 as id');
  await q('select 1 as id into public.helper_into');
  await q('reset role');
  const rows=(await q("select relrowsecurity from pg_class where oid in ('public.helper_create'::regclass,'public.helper_ctas'::regclass,'public.helper_into'::regclass)")).rows;
  assert.equal(rows.length,3); assert.ok(rows.every(r=>r.relrowsecurity));
 });
 await check('inherited API execution fails closed and rolls back revocation',async()=>{
  await q('create role helper_inherited; grant helper_inherited to anon; grant execute on function public.rls_auto_enable() to helper_inherited,authenticated');
  await rejectedMigration();
  assert.equal((await q("select has_function_privilege('authenticated','public.rls_auto_enable()','execute') as allowed")).rows[0].allowed,true);
  await q('revoke helper_inherited from anon; revoke execute on function public.rls_auto_enable() from helper_inherited');
  await q(migration);
 });
 console.log(`PASS ${passed} helper hardening checks`);
} finally {
 if(client)await client.end(); await pg.stop(); await rm(dir,{recursive:true,force:true});
}
