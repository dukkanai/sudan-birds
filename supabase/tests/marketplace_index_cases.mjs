// Isolated synthetic PostgreSQL only. Catalog/plan checks are not load benchmarks.
import assert from 'node:assert/strict';

const expected = [
  ['listings', 'location_id', 'listings_location_id_idx'],
  ['listings', 'owner_id', 'listings_owner_id_idx'],
  ['media', 'listing_id', 'media_listing_id_idx'],
  ['media', 'owner_id', 'media_owner_id_idx'],
  ['reports', 'reporter_id', 'reports_reporter_id_idx'],
  ['upload_intents', 'listing_id', 'upload_intents_listing_id_idx'],
];

// A usable FK index must contain every FK column in its leading key positions,
// not merely somewhere in INCLUDE, behind another key, or in a partial index.
const uncoveredForeignKeys = `select c.relname as table_name, f.conname,
 array(select a.attname::text from unnest(f.conkey) with ordinality k(attnum, pos)
 join pg_attribute a on a.attrelid=f.conrelid and a.attnum=k.attnum order by k.pos) as columns
 from pg_constraint f join pg_class c on c.oid=f.conrelid
 join pg_namespace n on n.oid=c.relnamespace
 where f.contype='f' and n.nspname='public' and not exists (
  select 1 from pg_index i join pg_class ic on ic.oid=i.indexrelid
  join pg_am am on am.oid=ic.relam
  where i.indrelid=f.conrelid and am.amname='btree'
  and i.indisvalid and i.indisready and i.indislive
  and i.indpred is null and i.indexprs is null
  and i.indnkeyatts >= cardinality(f.conkey)
  and array(select k.attnum from unnest(i.indkey::smallint[]) with ordinality k(attnum, pos)
            where k.pos <= cardinality(f.conkey) order by k.attnum)
      = array(select k.attnum from unnest(f.conkey) k(attnum) order by k.attnum)
 ) order by c.relname,f.conname`;

async function indexes(q) {
  return (await q(`select n.nspname,c.relname as table_name,ic.relname as index_name,
   pg_get_indexdef(i.indexrelid) as definition,am.amname as method,
   i.indisvalid,i.indisready,i.indislive,i.indisunique,i.indnkeyatts,i.indnatts,
   pg_get_expr(i.indpred,i.indrelid) as predicate,
   pg_get_expr(i.indexprs,i.indrelid) as expressions,
   array(select a.attname::text from unnest(i.indkey::smallint[]) with ordinality k(attnum,pos)
         join pg_attribute a on a.attrelid=i.indrelid and a.attnum=k.attnum order by k.pos) as columns
   from pg_index i join pg_class c on c.oid=i.indrelid
   join pg_namespace n on n.oid=c.relnamespace
   join pg_class ic on ic.oid=i.indexrelid join pg_am am on am.oid=ic.relam
   where n.nspname in ('public','private') order by n.nspname,ic.relname`)).rows;
}

export async function assertMarketplaceIndexes(q) {
  const actual = await indexes(q);
  for (const [table, column, name] of expected) {
    const index = actual.find(i => i.nspname === 'public' && i.index_name === name);
    assert.ok(index, `Missing ${name}`);
    assert.equal(index.table_name, table);
    assert.equal(index.method, 'btree');
    assert.equal(index.indisvalid && index.indisready && index.indislive, true);
    assert.equal(index.indisunique, false);
    assert.equal(index.indnkeyatts, 1);
    assert.equal(index.indnatts, 1);
    assert.equal(index.predicate, null);
    assert.equal(index.expressions, null);
    assert.deepEqual(index.columns, [column]);
  }
  assert.deepEqual((await q(uncoveredForeignKeys)).rows, [], 'Every final public FK needs a usable leading B-tree key');
}

async function dataSnapshot(q) {
  const tables = (await q(`select n.nspname,c.relname from pg_class c
   join pg_namespace n on n.oid=c.relnamespace
   where n.nspname in ('public','private','auth') and c.relkind='r'
   order by n.nspname,c.relname`)).rows;
  const snapshot = {};
  for (const {nspname,relname} of tables) {
    const quote = name => '"' + name.replaceAll('"','""') + '"';
    snapshot[`${nspname}.${relname}`] = (await q(
      `select to_jsonb(t) as value from ${quote(nspname)}.${quote(relname)} t order by to_jsonb(t)::text`,
    )).rows;
  }
  return snapshot;
}

async function securitySnapshot(q) {
  const queries = {
    tables: `select c.oid,c.relowner,c.relacl,c.relrowsecurity,c.relforcerowsecurity
      from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname in ('public','private','auth') and c.relkind in ('r','p','v','m','S') order by c.oid`,
    columns: `select a.attrelid,a.attnum,a.attacl from pg_attribute a
      join pg_class c on c.oid=a.attrelid join pg_namespace n on n.oid=c.relnamespace
      where n.nspname in ('public','private','auth') and c.relkind in ('r','p','v','m','S') order by a.attrelid,a.attnum`,
    policies: `select * from pg_policies where schemaname in ('public','private','auth') order by schemaname,tablename,policyname`,
    functions: `select p.oid,p.proowner,p.proacl,pg_get_functiondef(p.oid) as definition
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname in ('public','private','auth') order by p.oid`,
    constraints: `select c.oid,pg_get_constraintdef(c.oid) as definition from pg_constraint c
      join pg_namespace n on n.oid=c.connamespace
      where n.nspname in ('public','private','auth') order by c.oid`,
    triggers: `select t.oid,t.tgenabled,pg_get_triggerdef(t.oid) as definition from pg_trigger t
      join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
      where n.nspname in ('public','private','auth') order by t.oid`,
    schemas: `select oid,nspowner,nspacl from pg_namespace where nspname in ('public','private','auth') order by oid`,
    defaultGrants: `select * from pg_default_acl order by oid`,
  };
  const snapshot = {};
  for (const [key, sql] of Object.entries(queries)) snapshot[key] = (await q(sql)).rows;
  return snapshot;
}

export async function marketplaceIndexCases({q,check,migrations,bootstrap}) {
  for (const migration of migrations.slice(0,4)) await q(migration);
  const migration = migrations[4];
  assert.ok(migration, 'Forward index migration must be present');
  const owner = '91000000-0000-4000-8000-000000000001';
  const secondOwner = '91000000-0000-4000-8000-000000000002';
  await q('insert into auth.users values($1),($2)', [owner,secondOwner]);
  await q("insert into profiles(id,display_name,accepted_terms_at) values($1,'Index owner',now()),($2,'Other owner',now())", [owner,secondOwner]);
  const location = (await q("insert into locations(state_ar,city_ar) values('Synthetic state','Synthetic city') returning id")).rows[0].id;
  await q("select set_config('request.jwt.claim.sub',$1,false)", [owner]);
  await q('set role authenticated');
  const listing = (await q("insert into listings(kind,title,description,quantity,location_id) values('request','Retained request','Synthetic body',1,$1) returning id", [location])).rows[0].id;
  await q("insert into reports(listing_id,reason) values($1,'Retained index test report')", [listing]);
  const intent = (await q("select * from reserve_upload($1,100,'image/jpeg')", [listing])).rows[0];
  await q("select * from reserve_upload($1,100,'image/jpeg')", [listing]);
  // A second listing keeps owner cascades non-vacuous after listing deletion.
  // Its NULL location also exercises the nullable FK without changing semantics.
  const secondListing = (await q("insert into listings(kind,title,description,quantity) values('request','Second retained request','Synthetic body',1) returning id")).rows[0].id;
  const secondIntent = (await q("select * from reserve_upload($1,100,'image/jpeg')", [secondListing])).rows[0];
  await q('reset role');
  await q("select set_config('request.jwt.claim.sub','',false)");
  await q('set role service_role');
  for (const upload of [intent,secondIntent]) {
    const claim = (await q('select * from prepare_media_verification($1,$2)', [owner,upload.id])).rows[0];
    await q("select * from commit_verified_media($1,$2,$3,100,10,10,'Retained synthetic image')", [owner,upload.id,claim.clean_key]);
  }
  await q('reset role');

  await check('index preflight finds exactly the six known uncovered foreign keys', async () => {
    const missing = (await q(uncoveredForeignKeys)).rows.map(r => [r.table_name,...r.columns]).sort();
    assert.deepEqual(missing, expected.map(([table,column]) => [table,column]).sort());
  });
  const data = await dataSnapshot(q);
  const security = await securitySnapshot(q);
  const existingIndexes = await indexes(q);
  await check('same-name wrong index fails and rolls back every earlier index build', async () => {
    await q('create index upload_intents_listing_id_idx on public.upload_intents(expires_at)');
    const collisionIndexes = await indexes(q);
    await assert.rejects(q(migration), e => e.code === '42P07');
    await q('rollback');
    assert.deepEqual(await indexes(q), collisionIndexes);
    assert.deepEqual(await dataSnapshot(q), data);
    assert.deepEqual(await securitySnapshot(q), security);
    await q('drop index public.upload_intents_listing_id_idx');
  });
  await q(migration);
  await check('populated index upgrade preserves every synthetic application and auth row', async () => {
    assert.deepEqual(await dataSnapshot(q), data);
  });
  await check('index upgrade leaves RLS, ACLs, RPCs, triggers and constraints unchanged', async () => {
    assert.deepEqual(await securitySnapshot(q), security);
  });
  await check('index upgrade adds only six indexes and preserves existing index definitions', async () => {
    const actual = await indexes(q);
    assert.equal(actual.length, existingIndexes.length + expected.length);
    assert.deepEqual(actual.filter(i => !expected.some(([, , name]) => i.index_name === name)), existingIndexes);
  });
  await check('all six new indexes are usable nonunique full B-trees and cover every remaining public FK', () => assertMarketplaceIndexes(q));
  await check('each new index supports its equality lookup (forced-plan applicability, not speed)', async () => {
    // Tiny fixtures normally favor sequential scans. This tests index eligibility
    // only; do not turn a forced local plan into a throughput or latency claim.
    await q('set enable_seqscan=off');
    try {
      for (const [table,column,name] of expected) {
        const value = column === 'location_id' ? location : column === 'listing_id' ? listing : owner;
        const result = await q(`explain (format json) select id from public.${table} where ${column}=$1`, [value]);
        const nodes = [];
        const visit = node => { nodes.push(node); for (const child of node.Plans || []) visit(child); };
        visit(result.rows[0]['QUERY PLAN'][0].Plan);
        assert.ok(nodes.some(n => n['Index Name'] === name && n['Index Cond']?.includes(column)), `No indexed equality condition for ${name}`);
      }
    } finally { await q('reset enable_seqscan'); }
  });
  await check('indexed location FK still rejects deleting a referenced location', async () => {
    await assert.rejects(q('delete from locations where id=$1', [location]), e => e.code === '23503');
    assert.deepEqual(await dataSnapshot(q), data);
  });
  await check('indexed listing cascade preserves reports and object-cleanup registry', async () => {
    await q('delete from listings where id=$1', [listing]);
    for (const table of ['media','upload_intents']) {
      assert.equal((await q(`select * from ${table} where listing_id=$1`, [listing])).rowCount, 0);
    }
    assert.equal((await q('select * from reports where listing_id=$1', [listing])).rowCount, 1);
    assert.deepEqual((await dataSnapshot(q))['private.object_registry'], data['private.object_registry']);
  });
  await check('indexed owner and reporter cascades retain unrelated profiles', async () => {
    for (const table of ['listings','media','upload_intents']) {
      assert.equal((await q(`select * from ${table} where owner_id=$1`, [owner])).rowCount, 1);
    }
    await q('delete from auth.users where id=$1', [owner]);
    assert.equal((await q('select * from profiles where id=$1', [owner])).rowCount, 0);
    for (const table of ['listings','media','upload_intents']) {
      assert.equal((await q(`select * from ${table} where owner_id=$1`, [owner])).rowCount, 0);
    }
    assert.equal((await q('select * from reports where reporter_id=$1', [owner])).rowCount, 0);
    assert.equal((await q('select * from profiles where id=$1', [secondOwner])).rowCount, 1);
  });

  // Keep the existing fresh-chain security suite independent of upgrade fixtures.
  await q('drop schema public cascade; drop schema private cascade; drop schema auth cascade; create schema public; grant usage on schema public to public;');
  await q(bootstrap);
}
