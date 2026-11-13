// Disposable embedded database only. Exercises upgrade before the fresh-chain suite.
import assert from 'node:assert/strict';
export async function migrationCases({q,check,migrations,bootstrap}) {
 for (const migration of migrations.slice(0,2)) await q(migration);
 const owner='90000000-0000-4000-8000-000000000001';
 const target='90000000-0000-4000-8000-000000000002';
 await q('insert into auth.users values($1)',[owner]);
 await q("insert into profiles(id,display_name,accepted_terms_at) values($1,'Upgrade owner',now())",[owner]);
 const migration=migrations[2];
 assert.ok(migration,'Removal migration must be present');
 async function blocked(label,setup,verify,cleanup){
  await setup();
  await check(label,async()=>{
   await assert.rejects(q(migration),e=>e.code==='55000');
   await q('rollback');
   assert.equal((await q("select to_regclass('public.posts') is not null as present")).rows[0].present,true);
   assert.equal((await q("select to_regprocedure('public.reserve_upload(uuid,uuid,integer,text)') is not null as present")).rows[0].present,true);
   await verify();
  });
  await cleanup();
 }
 await blocked('upgrade guard preserves removed-feature content and schema on rollback',async()=>{
  await q("insert into posts(id,owner_id,kind,title,body) values($1,$2,'consultation','Retained question','Do not destroy')",[target,owner]);
  await q("insert into replies(post_id,owner_id,body) values($1,$2,'Retained reply')",[target,owner]);
 },async()=>{
  assert.equal((await q('select body from posts where id=$1',[target])).rows[0].body,'Do not destroy');
  assert.equal((await q('select * from replies where post_id=$1',[target])).rowCount,1);
 },()=>q('delete from posts where id=$1',[target]));
 await blocked('upgrade guard retains orphan report identifiers',async()=>{
  await q("insert into posts(id,owner_id,kind,title,body) values($1,$2,'education','Retained history','Body')",[target,owner]);
  await q("insert into reports(reporter_id,post_id,reason) values($1,$2,'Retained moderation history')",[owner,target]);
  await q('delete from posts where id=$1',[target]);
 },async()=>{
  assert.equal((await q('select * from reports where post_id=$1',[target])).rowCount,1);
 },()=>q('delete from reports where post_id=$1',[target]));
 await blocked('upgrade guard retains moderation audit history',()=>q("insert into moderation_actions(actor_id,target_kind,target_id,action,reason) values($1,'reply',$2,'hide','Retained history')",[owner,target]),async()=>{
  assert.equal((await q("select * from moderation_actions where target_kind='reply'")).rowCount,1);
 },()=>q("delete from moderation_actions where target_kind='reply'"));
 await blocked('upgrade guard retains removed-target quota history',()=>q("insert into private.publish_events(user_id,table_name) values($1,'posts')",[owner]),async()=>{
  assert.equal((await q("select * from private.publish_events where table_name='posts'")).rowCount,1);
 },()=>q("delete from private.publish_events where table_name='posts'"));
 await blocked('upgrade guard preserves unknown custom topic references',()=>q("insert into topics(name_ar) values('Custom retained topic')"),async()=>{
  assert.equal((await q("select * from topics where name_ar='Custom retained topic'")).rowCount,1);
 },()=>q("delete from topics where name_ar='Custom retained topic'"));
 await q("insert into topics(name_ar) values('التغذية')");
 await q("select set_config('request.jwt.claim.sub',$1,false)",[owner]);
 await q('set role authenticated');
 const listing=(await q("insert into listings(kind,title,description,quantity,price) values('offer','Retained bird','Retained description',2,125) returning id")).rows[0].id;
 const report=(await q("insert into reports(listing_id,reason) values($1,'Retained listing report') returning id",[listing])).rows[0].id;
 const intent=(await q("select * from reserve_upload(null,$1,100,'image/jpeg')",[listing])).rows[0];
 await q("select * from reserve_upload(null,$1,100,'image/jpeg')",[listing]);
 await q('reset role');await q("select set_config('request.jwt.claim.sub','',false)");await q('set role service_role');
 const claim=(await q('select * from prepare_media_verification($1,$2)',[owner,intent.id])).rows[0];
 await q("select * from commit_verified_media($1,$2,$3,100,10,10,'Retained image')",[owner,intent.id,claim.clean_key]);
 await q('reset role');
 await q("insert into private.object_registry(object_key,owner_id,intent_id,kind,safe_delete_after) values('orphan-retained',$1,$2,'quarantine',now())",[owner,target]);
 const tables=['public.listings','public.reports','public.media','public.upload_intents','private.object_registry','private.publish_events','private.upload_events'];
 async function snapshots(){const rows={};for(const table of tables)rows[table]=(await q(`select to_jsonb(t)-'post_id'-'reply_id' as value from ${table} t order by to_jsonb(t)::text`)).rows;return rows;}
 const before=await snapshots();
 await check('populated marketplace upgrade preserves listings, reports, verified media, object registry and quotas',async()=>{
  await q(migration);assert.deepEqual(await snapshots(),before);
  assert.equal((await q('select listing_id from reports where id=$1',[report])).rows[0].listing_id,listing);
  assert.equal((await q('select listing_id from media where id=$1',[intent.id])).rows[0].listing_id,listing);
 });
 // Fresh-chain tests start from empty independent schemas, not upgrade leftovers.
 await q('drop schema public cascade; drop schema private cascade; drop schema auth cascade; create schema public; grant usage on schema public to public;');
 await q(bootstrap);
}
