// Real PostgreSQL local harness with minimal synthetic Supabase auth context.
// Usage: EMBEDDED_POSTGRES_MODULE=/absolute/path/to/embedded-postgres/dist/index.js node supabase/tests/embedded_security.mjs
// Not a substitute for Supabase/PostgREST integration or pgTAP CI.
import { readFile, readdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import assert from 'node:assert/strict';
import {verifiedCases} from './verified_security_cases.mjs';
const { default: EmbeddedPostgres } = await import(process.env.EMBEDDED_POSTGRES_MODULE || 'embedded-postgres');
const dir = await mkdtemp(join(tmpdir(), 'birds-db-'));
const pg = new EmbeddedPostgres({ databaseDir: join(dir,'data'), user:'postgres', password:'synthetic-test-only', port:15439, persistent:false, createPostgresUser:false, initdbFlags:['--encoding=UTF8'], postgresFlags:['-c','unix_socket_directories='], onLog:()=>{}, onError:console.error });
let client; let passed=0;
const a='00000000-0000-4000-8000-000000000001', b='00000000-0000-4000-8000-000000000002';
async function q(sql,params){return client.query(sql,params);}
async function asUser(id){await q('reset role');await q("select set_config('request.jwt.claim.sub',$1,false)",[id||'']);await q(id?'set role authenticated':'set role anon');}
async function check(label, fn){await fn(); passed++; console.log(`ok ${passed} - ${label}`);}
async function denied(sql,params,code='42501'){await assert.rejects(q(sql,params),e=>e.code===code);}
try {
 await pg.initialise(); await pg.start(); client=pg.getPgClient(); await client.connect();
 await q(`create role anon; create role authenticated; create role service_role bypassrls;
 create schema auth; create table auth.users(id uuid primary key);
 create table auth.sessions(id uuid primary key,user_id uuid references auth.users(id) on delete cascade,created_at timestamptz not null default now(),not_after timestamptz);
 create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
 grant usage on schema auth to anon,authenticated; grant execute on function auth.uid() to anon,authenticated;`);
 for(const migration of (await readdir(new URL('../migrations/',import.meta.url))).filter(n=>n.endsWith('.sql')).sort()) await q(await readFile(new URL('../migrations/'+migration,import.meta.url),'utf8'));
 const seed=await readFile(new URL('../seed.sql',import.meta.url),'utf8');
 await check('local reference seed is idempotent and creates no user content',async()=>{
   await q(seed); await q(seed);
   assert.equal(Number((await q('select count(*) from bird_types')).rows[0].count),9);
   assert.equal(Number((await q('select count(*) from topics')).rows[0].count),6);
   assert.equal(Number((await q('select count(*) from locations')).rows[0].count),5);
   assert.equal(Number((await q('select count(*) from profiles')).rows[0].count),0);
   assert.equal(Number((await q('select count(*) from listings')).rows[0].count),0);
   assert.equal(Number((await q('select count(*) from posts')).rows[0].count),0);
 });
 await q('insert into auth.users values($1),($2)',[a,b]);
 await q("insert into profiles(id,display_name,accepted_terms_at) values($1,'Owner A',now()),($2,'Owner B',now())",[a,b]);
 await asUser(a);
 let p=(await q("insert into posts(kind,title,body) values('education','First post','Content') returning id")).rows[0].id;
 let p2=(await q("insert into posts(kind,title,body) values('consultation','Other post','Question') returning id")).rows[0].id;
 let l=(await q("insert into listings(kind,title,description,quantity,price) values('offer','Bird offer','Description',1,100) returning id")).rows[0].id;
 let r=(await q("insert into replies(post_id,body) values($1,'Reply') returning id",[p])).rows[0].id;
 await check('offer price mandatory',()=>denied("insert into listings(kind,title,description,quantity) values('offer','Missing price','Desc',1)",[], '23514'));
 await check('NaN price denied',()=>denied("insert into listings(kind,title,description,quantity,price) values('offer','NaN price','Desc',1,'NaN')",[], '23514'));
 await check('negative price denied',()=>denied("insert into listings(kind,title,description,quantity,price) values('offer','Bad price','Desc',1,-1)",[], '23514'));
 await check('optional request budget accepted',async()=>{await q("insert into listings(kind,title,description,quantity) values('request','Wanted bird','Desc',1)");});
 await check('requests cannot be reserved',()=>denied("update listings set status='reserved' where kind='request'",[], '23514'));
 await check('timestamp spoof denied',()=>denied('update posts set created_at=now()+interval \'1 day\' where id=$1',[p]));
 await check('owner spoof denied',()=>denied('update posts set owner_id=$1 where id=$2',[b,p]));
 await check('expiry extension denied',()=>denied("update listings set expires_at=now()+interval '100 years' where id=$1",[l]));
 await check('moderation bypass denied',()=>denied("update posts set moderation_state='hidden' where id=$1",[p]));
 await check('admin self promotion denied',()=>denied("insert into moderator_roles values($1,'admin')",[a]));
 await check('moderation RPC denies regular user',()=>denied("select moderate_content('post',$1,true,'hide this')",[p]));
 await check('cross-post reply parent denied',()=>denied("insert into replies(post_id,parent_id,body) values($1,$2,'Cross post')",[p2,r],'23514'));
 await check('reply cycle by reparenting denied',()=>denied('update replies set parent_id=id where id=$1',[r]));
 await check('self-parent insertion identity denied',()=>denied("insert into replies(id,post_id,parent_id,body) values($1,$2,$1,'Self')",[a,p]));
 await q("insert into profile_contacts values($1,'example@test.invalid','email',false,null)",[a]);
 await q("insert into reports(post_id,reason) values($1,'Please review this post')",[p]);
 await asUser(b);
 await check('cross-user edit touches no rows',async()=>assert.equal((await q("update posts set body='Hacked' where id=$1 returning id",[p])).rowCount,0));
 await check('cross-user delete touches no rows',async()=>assert.equal((await q('delete from listings where id=$1 returning id',[l])).rowCount,0));
 await check('contact table remains private',async()=>assert.equal((await q('select * from profile_contacts')).rowCount,0));
 await check('reports remain private',async()=>assert.equal((await q('select * from reports')).rowCount,0));
 await check('contact reveal needs explicit requester consent',()=>denied('select * from reveal_listing_contact($1,false)',[l]));
 await check('contact reveal needs owner consent',async()=>assert.equal((await q('select * from reveal_listing_contact($1,true)',[l])).rowCount,0));
 await check('upload cannot target other owner',()=>denied("select reserve_upload($1,null,100,'image/jpeg')",[p]));
 await asUser(a); await q('update profile_contacts set reveal_consent=true,consent_at=now()');
 await asUser(b);
 await check('owner consent permits explicit reveal',async()=>assert.equal((await q('select * from reveal_listing_contact($1,true)',[l])).rowCount,1));
 await q('insert into user_blocks(blocker_id,blocked_id) values($1,$2)',[b,a]);
 await check('blocked content hidden',async()=>assert.equal((await q('select * from posts where id=$1',[p])).rowCount,0));
 await check('blocked contact RPC denied',()=>denied('select * from reveal_listing_contact($1,true)',[l]));
 await check('blocked reply via API denied',()=>denied("insert into replies(post_id,body) values($1,'Blocked')",[p]));
 await asUser(a);
 await check('reverse block hides account',async()=>assert.equal((await q('select * from profiles where id=$1',[b])).rowCount,0));
 await check('first three attachment reservations succeed',async()=>{for(let i=0;i<3;i++)await q("select reserve_upload($1,null,100,'image/jpeg')",[p]);});
 await check('fourth attachment rejected',()=>denied("select reserve_upload($1,null,100,'image/jpeg')",[p],'P0001'));
 await check('oversize upload denied',()=>denied("select reserve_upload($1,null,6000000,'image/jpeg')",[p2],'22023'));
 await check('unsafe MIME denied',()=>denied("select reserve_upload($1,null,100,'image/svg+xml')",[p2],'22023'));
 await check('cannot mark intent verified',()=>denied("update upload_intents set state='verified' where owner_id=$1",[a]));
 await check('cannot publish unverified media',()=>denied("insert into media(id,owner_id,post_id,object_key,byte_size,mime_type,width,height,verified_at) values($1,$2,$3,'injected',1,'image/jpeg',1,1,now())",[a,a,p]));
 await asUser(null);
 await check('anonymous browsing works',async()=>assert.ok((await q('select * from posts')).rowCount>=2));
 await check('anonymous posting denied',()=>denied("insert into posts(kind,title,body) values('education','Anon post','Bad')"));
 await check('anonymous contact reveal denied',()=>denied('select * from reveal_listing_contact($1,true)',[l]));
 await q('reset role');await q("insert into moderator_roles values($1,'moderator')",[b]);await asUser(b);
 await check('authorized moderation writes audit atomically',async()=>{await q("select moderate_content('post',$1,true,'Policy violation')",[p]);assert.equal((await q('select * from moderation_actions')).rowCount,1);});
 await asUser(null);
 await check('hidden post unavailable anonymously',async()=>assert.equal((await q('select * from posts where id=$1',[p])).rowCount,0));
 await check('hidden post replies unavailable',async()=>assert.equal((await q('select * from replies where post_id=$1',[p])).rowCount,0));


 await asUser(a);
 await check('concurrent reservations cannot exceed three attachments',async()=>{
   const clients=Array.from({length:6},()=>pg.getPgClient());
   try {
     await Promise.all(clients.map(async c=>{await c.connect(); await c.query("select set_config('request.jwt.claim.sub',$1,false)",[a]);await c.query('set role authenticated');}));
     const results=await Promise.allSettled(clients.map(c=>c.query("select reserve_upload($1,null,100,'image/jpeg')",[p2])));
     assert.equal(results.filter(r=>r.status==='fulfilled').length,3);
     assert.equal(results.filter(r=>r.status==='rejected' && r.reason.code==='P0001').length,3);
   }finally{await Promise.all(clients.map(c=>c.end()));}
 });

 await check('content deletion cannot reset daily upload quota',async()=>{
   await q('reset role');
   const used=Number((await q('select count(*) from private.upload_events where user_id=$1',[a])).rows[0].count);
   await asUser(a);
   for(let i=used;i<20;i++) {
     const target=(await q("insert into posts(kind,title,body) values('education','Transient post','Body') returning id")).rows[0].id;
     await q("select reserve_upload($1,null,100,'image/jpeg')",[target]);
     await q('delete from posts where id=$1',[target]);
   }
   const target=(await q("insert into posts(kind,title,body) values('education','New target','Body') returning id")).rows[0].id;
   await denied("select reserve_upload($1,null,100,'image/jpeg')",[target],'P0001');
 });
 await check('clients cannot clear upload ledger',()=>denied('delete from private.upload_events'));
 await q('reset role'); await q("update private.publish_limits set max_per_day=2 where table_name='posts'"); await asUser(a);
 await check('rolling publish quota enforced',()=>denied("insert into posts(kind,title,body) values('education','Too many','Body')",[],'P0001'));

 const report=(await q("insert into reports(post_id,reason) values($1,'Synthetic target deletion report') returning id",[p2])).rows[0].id;
 await q('delete from posts where id=$1',[p2]);
 await check('author deletion preserves moderation queue',async()=>assert.equal((await q('select id from reports where id=$1',[report])).rowCount,1));
 await check('report must target visible existing content',()=>denied("insert into reports(post_id,reason) values($1,'Missing target report')",[p2],'23514'));

 await check('delete cannot reset publish quota',()=>denied("insert into posts(kind,title,body) values('education','Still too many','Body')",[],'P0001'));
 await check('private quota ledger cannot be modified',()=>denied('delete from private.publish_events'));
 await q('update profiles set accepted_terms_at=null where id=$1',[a]);
 await check('publishing requires terms acceptance',()=>denied("insert into listings(kind,title,description,quantity) values('request','No consent','Body',1)"));
 await verifiedCases({q,asUser,check,denied,pg});
 console.log(`PASS ${passed} real PostgreSQL security checks`);
} finally { if(client)await client.end(); await pg.stop(); await rm(dir,{recursive:true,force:true}); }
