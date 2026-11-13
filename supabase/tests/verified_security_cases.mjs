// Synthetic DB-only tests. Storage/codec ordering is separately covered in Deno.
import assert from 'node:assert/strict';
export async function verifiedCases({q,asUser,check,denied,pg}) {
 const c='00000000-0000-4000-8000-000000000003';
 const svc=async()=>{await q('reset role');await q("select set_config('request.jwt.claim.sub','',false)");await q('set role service_role');};
 const admin=async()=>{await q('reset role');await q("select set_config('request.jwt.claim.sub','',false)");};
 await admin();await q('insert into auth.users values($1)',[c]);await q("insert into auth.sessions(id,user_id,created_at) values($1,$1,now()-interval '20 minutes')",[c]);await q("insert into profiles values($1,'Image owner',now(),now())",[c]);
 await q("update private.publish_limits set max_per_day=50 where table_name='listings'");
 await asUser(c);
 const targets=[];for(let i=0;i<6;i++)targets.push((await q("insert into listings(kind,title,description,quantity) values('request','Image target','Body',1) returning id")).rows[0].id);
 const report=(await q("insert into reports(listing_id,reason) values($1,'Synthetic moderation report') returning id",[targets[0]])).rows[0].id;
 await check('ordinary caller cannot resolve reports',()=>denied("select resolve_report($1,'resolved','Reviewed report')",[report]));
 await check('ordinary caller cannot inspect hidden report target',()=>denied('select * from moderator_report_target($1)',[report]));
 await admin();await q("insert into moderator_roles values($1,'moderator')",[c]);await q("update listings set moderation_state='hidden' where id=$1",[targets[0]]);await asUser(c);
 await check('moderator can review only sanitized target fields including hidden content',async()=>{
  const target=(await q('select * from moderator_report_target($1)',[report])).rows[0];assert.equal(target.target_id,targets[0]);assert.equal(target.moderation_state,'hidden');assert.equal(target.missing,false);assert.ok(!('contact_value'in target));assert.ok(!('email'in target));
 });
 await check('report resolution is role-checked and audited',async()=>{await q("select resolve_report($1,'reviewing','Review started')",[report]);assert.equal((await q('select state from reports where id=$1',[report])).rows[0].state,'reviewing');assert.equal((await q("select * from moderation_actions where target_id=$1 and action='report_reviewing'",[report])).rowCount,1);});
 await admin();await q("delete from moderator_roles where user_id=$1",[c]);await q("update listings set moderation_state='visible' where id=$1",[targets[0]]);await asUser(c);

 const reserve=async(target)=>{await asUser(c);return (await q("select * from reserve_upload($1,100,'image/jpeg')",[target])).rows[0];};
 const one=await reserve(targets[0]);
 await check('PNG no longer reservable in JPEG-only MVP',()=>denied("select reserve_upload($1,100,'image/png')",[targets[1]],'22023'));
 await check('ordinary caller cannot prepare verification',()=>denied('select * from prepare_media_verification($1,$2)',[c,one.id]));
 await check('ordinary caller cannot invoke cleanup or account service RPCs',()=>denied('select begin_account_deletion($1,$1,floor(extract(epoch from clock_timestamp()))::bigint)',[c]));
 await svc();
 await check('service verification still binds owner',()=>denied('select * from prepare_media_verification($1,$2)',['00000000-0000-4000-8000-000000000001',one.id]));
 const first=(await q('select * from prepare_media_verification($1,$2)',[c,one.id])).rows[0];
 const second=(await q('select * from prepare_media_verification($1,$2)',[c,one.id])).rows[0];
 await check('racing verification claims get distinct immutable keys',async()=>assert.notEqual(first.clean_key,second.clean_key));
 await check('canonical key cannot be chosen by caller',()=>denied("select * from commit_verified_media($1,$2,'verified/forged',100,10,10,'')",[c,one.id]));
 await check('canonical dimensions independently bounded by DB',()=>denied("select * from commit_verified_media($1,$2,$3,100,641,1,'')",[c,one.id,first.clean_key],'22023'));
 let winner;
 await check('parallel finalization publishes exactly one winner',async()=>{
  const clients=[pg.getPgClient(),pg.getPgClient()];
  try{
   await Promise.all(clients.map(async cl=>{await cl.connect();await cl.query('set role service_role');}));
   const result=await Promise.all(clients.map((cl,i)=>cl.query("select * from commit_verified_media($1,$2,$3,100,10,10,'Safe alt')",[c,one.id,[first.clean_key,second.clean_key][i]])));
   winner=result[0].rows[0].published_key;assert.equal(winner,result[1].rows[0].published_key);
   assert.equal((await q('select * from media where id=$1',[one.id])).rowCount,1);
  }finally{await Promise.all(clients.map(cl=>cl.end()));}
 });
 await asUser(null);
 await check('verified listing image is publicly readable',async()=>assert.equal((await q('select * from media where id=$1',[one.id])).rowCount,1));
 await admin();await q("update listings set moderation_state='hidden' where id=$1",[targets[0]]);await asUser(null);
 await check('hidden listing image is not publicly readable',async()=>assert.equal((await q('select * from media where id=$1',[one.id])).rowCount,0));
 await admin();await q("update listings set moderation_state='visible' where id=$1",[targets[0]]);
 await asUser('00000000-0000-4000-8000-000000000002');
 await q('insert into user_blocks(blocker_id,blocked_id) values(auth.uid(),$1)',[c]);
 await check('blocked listing image is not readable',async()=>assert.equal((await q('select * from media where id=$1',[one.id])).rowCount,0));
 await q('delete from user_blocks where blocker_id=auth.uid() and blocked_id=$1',[c]);await svc();
 await check('finalize replay returns existing media without new key',async()=>assert.equal((await q('select * from prepare_media_verification($1,$2)',[c,one.id])).rows[0].existing_media,one.id));
 const expired=await reserve(targets[1]);await admin();await q("update upload_intents set expires_at=now()-interval '1 second' where id=$1",[expired.id]);await svc();
 await check('expired intent cannot be verified',()=>denied('select * from prepare_media_verification($1,$2)',[c,expired.id]));
 const hidden=await reserve(targets[2]);await svc();const claim=(await q('select * from prepare_media_verification($1,$2)',[c,hidden.id])).rows[0];
 await admin();await q("update listings set moderation_state='hidden' where id=$1",[targets[2]]);await svc();
 await check('hidden target during verification cannot publish',()=>denied("select * from commit_verified_media($1,$2,$3,100,10,10,'')",[c,hidden.id,claim.clean_key]));
 const gone=await reserve(targets[3]);await svc();const claimGone=(await q('select * from prepare_media_verification($1,$2)',[c,gone.id])).rows[0];
 await asUser(c);await q('delete from listings where id=$1',[targets[3]]);await svc();
 await check('deleted target during verification cannot publish',()=>denied("select * from commit_verified_media($1,$2,$3,100,10,10,'')",[c,gone.id,claimGone.clean_key]));
 const limited=await reserve(targets[4]);await svc();for(let i=0;i<3;i++)await q('select * from prepare_media_verification($1,$2)',[c,limited.id]);
 await check('completion CPU attempts bounded before downloading',()=>denied('select * from prepare_media_verification($1,$2)',[c,limited.id],'P0001'));
 await admin();await q("update private.object_registry set safe_delete_after=now()-interval '1 second' where owner_id=$1",[c]);await svc();
 await check('cleanup selects orphan canonical key but never referenced winner',async()=>{
  const keys=(await q('select * from list_cleanup_objects($1,100)',[c])).rows.map(r=>r.object_key);
  assert.ok(keys.includes(winner===first.clean_key?second.clean_key:first.clean_key));assert.ok(!keys.includes(winner));
 });
 const ongoing=await reserve(targets[5]);await svc();const outstanding=(await q('select * from prepare_media_verification($1,$2)',[c,ongoing.id])).rows[0];
 await asUser(c);await q("insert into profile_contacts(owner_id,contact_value,contact_kind) values($1,'synthetic@example.invalid','email')",[c]);await svc();

 await admin();await q("insert into auth.sessions(id,user_id) values('99999999-9999-4999-8999-999999999998',$1)",[c]);await svc();
 await check('second-session login and fresh iat cannot rescue old-session stale authentication',()=>denied("select * from begin_account_deletion($1,$1,floor(extract(epoch from clock_timestamp()-interval '11 minutes'))::bigint)",[c]));
 await check('missing or revoked Auth session cannot authorize deletion',()=>denied("select * from begin_account_deletion($1,'99999999-9999-4999-8999-999999999999',floor(extract(epoch from clock_timestamp()))::bigint)",[c]));
 const job=(await q('select * from begin_account_deletion($1,$1,floor(extract(epoch from clock_timestamp()))::bigint)',[c])).rows[0];
 await check('deletion waits out already issued upload capabilities',async()=>assert.ok(new Date(job.not_before).getTime()>Date.now()+100000));
 await check('deletion begin is idempotent',async()=>assert.equal((await q('select * from begin_account_deletion($1,$1,floor(extract(epoch from clock_timestamp()))::bigint)',[c])).rows[0].id,job.id));
 await check('deleting account cannot finalize outstanding media',()=>denied("select * from commit_verified_media($1,$2,$3,100,10,10,'')",[c,ongoing.id,outstanding.clean_key]));
 await check('Auth deletion requires completed object cleanup',()=>denied('select deletion_ready_for_auth($1)',[job.id],'P0001'));
 await check('absence or expiry alone cannot authorize cleanup completion',()=>denied('select mark_object_deleted($1,false)',[one.object_key],'P0001'));
 await admin();await q('update private.object_registry set create_only=false where object_key=$1',[one.object_key]);await svc();
 await check('legacy unconditional capability cannot be marked safely fenced',()=>denied('select mark_object_deleted($1,true)',[one.object_key],'P0001'));
 await admin();await q('update private.object_registry set create_only=true where object_key=$1',[one.object_key]);await svc();


 await asUser(c);
 await check('deleting account content becomes unavailable',async()=>assert.equal((await q('select * from listings where owner_id=$1',[c])).rowCount,0));
 await check('deleting account cannot publish',()=>denied("insert into listings(kind,title,description,quantity) values('request','New forbidden','Body',1)"));
 await check('deleting account cannot reserve more uploads',()=>denied("select reserve_upload($1,100,'image/jpeg')",[targets[0]]));
 await check('ordinary caller cannot trigger manual admin cleanup',async()=>assert.equal((await q('select is_cleanup_admin()')).rows[0].is_cleanup_admin,false));
 await check('own deletion status survives pending-session UI restart',async()=>{const status=(await q('select * from own_deletion_status()')).rows[0];assert.equal(status.job_id,job.id);assert.equal(status.state,'pending');});
 await svc();await q("select record_deletion_failure($1,'storage_configuration_required')",[job.id]);await asUser(c);
 await check('own status exposes safe operator blocker rather than endless progress',async()=>{const status=(await q('select * from own_deletion_status()')).rows[0];assert.equal(status.blocker_code,'storage_configuration_required');assert.equal(status.requires_operator,true);});
 await check('caller cannot forge or erase durable deletion blocker',()=>denied('select record_deletion_failure($1,null)',[job.id]));
 await svc();await check('raw unclassified errors cannot enter deletion status',()=>denied("select record_deletion_failure($1,'arbitrary-unclassified-error')",[job.id],'23514'));
 await q('select record_deletion_failure($1,null)',[job.id]);await asUser(c);

 await check('pending old session cannot edit profile',async()=>assert.equal((await q("update profiles set display_name='Forbidden rename' where id=$1 returning id",[c])).rowCount,0));
 await check('pending old session cannot edit private contact',()=>denied("update profile_contacts set contact_value='forbidden@example.invalid' where owner_id=$1",[c]));
 await check('pending old session cannot add blocks',()=>denied("insert into user_blocks(blocker_id,blocked_id) values($1,'00000000-0000-4000-8000-000000000001')",[c]));
 await check('ordinary session cannot claim scheduler jobs',()=>denied('select * from claim_due_deletion_job()'));

 await admin();await q("update private.account_deletion_jobs set not_before=now()-interval '1 second' where id=$1",[job.id]);await q("update private.object_registry set safe_delete_after=now()-interval '1 second' where owner_id=$1",[c]);await svc();

 await check('scheduler claims due job and excludes active lease',async()=>{
  assert.equal((await q('select * from claim_due_deletion_job()')).rows[0].id,job.id);
  assert.equal((await q('select * from claim_due_deletion_job()')).rowCount,0);
 });
 await admin();await q("update private.account_deletion_jobs set lease_until=now()-interval '1 second' where id=$1",[job.id]);await svc();
 await check('interrupted scheduler lease becomes retryable',async()=>assert.equal((await q('select * from claim_due_deletion_job()')).rows[0].id,job.id));
 await check('deletion cleanup includes previously referenced image',async()=>assert.ok((await q('select * from list_cleanup_objects($1,100)',[c])).rows.some(r=>r.object_key===winner)));
 // Synthetic DB acknowledgement of object removal; Deno tests enforce real adapter ordering.
 for(const row of (await q('select * from list_cleanup_objects($1,100)',[c])).rows)await q('select mark_object_deleted($1,true)',[row.object_key]);
 await check('cleanup completion enables Auth deletion only for job owner',async()=>assert.equal((await q('select deletion_ready_for_auth($1)',[job.id])).rows[0].deletion_ready_for_auth,c));
 await check('cannot mark completed while Auth user still exists',()=>denied('select finish_account_deletion($1)',[job.id],'P0001'));
 await admin();await q('delete from auth.users where id=$1',[c]);await svc();await q('select finish_account_deletion($1)',[job.id]);
 await check('completed deletion job survives Auth deletion for retries',async()=>assert.equal((await q('select * from get_deletion_job($1)',[job.id])).rows[0].state,'completed'));
}
