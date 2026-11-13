# Marketplace relationship indexes

## Scope and expected benefit

The 2026-11-09 read-only Supabase performance advisor reported six unindexed
foreign keys. Reviewing the complete migration chain and current queries confirmed
these gaps. `20261109145425_index_marketplace_relations.sql` adds exactly six
non-unique, non-partial B-tree indexes:

- `listings_location_id_idx`: `listings(location_id)`. Supports location equality
  and IN filters in `app/lib/repository.dart` and referenced-location integrity
  checks. The existing `listings_filter(bird_type_id,location_id,currency,price)`
  does not have `location_id` as its leading key.
- `listings_owner_id_idx`: `listings(owner_id)`. Supports owner-based lookup and
  cascading profile deletion. Existing ID-based edit/delete requests can already
  use the listing primary key; this is not a claim those requests become faster.
- `media_listing_id_idx`: `media(listing_id)`. Supports listing attachment lookup
  in `app/lib/repository.dart` and listing-delete cascades.
- `media_owner_id_idx`: `media(owner_id)`. Supports profile-delete cascades.
- `reports_reporter_id_idx`: `reports(reporter_id)`. Supports reporter filtering
  and profile-delete cascades. The reporter/moderator OR policy may still lead
  the planner to choose another plan.
- `upload_intents_listing_id_idx`: `upload_intents(listing_id)`. Supports
  listing-delete cascades and the listing condition in `reserve_upload`'s
  attachment-count query. Its owner, state and expiry checks still apply.

Each index covers its foreign-key lookup, not the complete selected row. These
are not INCLUDE/payload indexes or a promise of index-only scans. Existing feed,
text search, filters, primary/unique keys, `upload_owner_time(owner_id,created_at)`
and other indexes remain unchanged. In particular, the existing owner/time index
already covers the upload-owner FK and should not be duplicated.

The final schema intentionally has no FK from reports to their listing/account
targets so that target deletion preserves moderation history. No target FK or
extra report-target index is introduced here. No table data, policies, grants,
RPCs, triggers, application queries or upload enablement is changed.

## Migration behavior and operational limits

The migration uses one transaction and ordinary CREATE INDEX, with a five-second
lock timeout and a sixty-second per-statement timeout. A same-name existing
object, lock timeout or failed build aborts the transaction rather than accepting
an index with an unknown definition or leaving only some of the six indexes.
It deliberately does not use IF NOT EXISTS. Applied migration history must not
be rewritten, and a successful migration must not be manually replayed.

Ordinary index creation blocks table writes while allowing ordinary reads; its
locks are retained until transaction end. The six statement timeouts are not one
sixty-second budget for the whole transaction. Preflight table sizes, existing
indexes and active workload before an authorized application, and use a reviewed
maintenance window. This migration is not a zero-downtime rollout for a large
or busy production database. Such an environment needs a separately reviewed
concurrent-index rollout and invalid-index recovery plan, not a blind timeout
increase or an out-of-band retry.

Indexes use additional disk space and add maintenance cost to writes. They give
the planner indexed alternatives and can reduce FK/cascade scans, but actual
benefit depends on cardinality, selectivity, statistics, RLS and concurrency.
Small tables can correctly use sequential scans. This work includes no hosted
throughput/latency measurement, load test, production capacity claim, or proof
of a particular feed query plan. Representative EXPLAIN (ANALYZE, BUFFERS) and
load testing remain separate gates on authorized test data.

## Regression checks

The existing CI database job runs `supabase/tests/embedded_security.mjs`, which
now also loads `marketplace_index_cases.mjs`. With the existing pinned local
`embedded-postgres@17.6.0-beta.15` installation outside the repository:

```sh
export LD_LIBRARY_PATH=/absolute/path/to/@embedded-postgres/linux-x64/native/lib
export EMBEDDED_POSTGRES_MODULE=/absolute/path/to/embedded-postgres/dist/index.js
node supabase/tests/embedded_security.mjs
node supabase/tests/rls_auto_enable_security.mjs
python3 scripts/check_repository.py
```

The focused cases check the six missing keys before upgrading, populated upgrade
and fresh-chain coverage of every final public FK, full valid/ready/live B-tree
definitions, unchanged pre-existing indexes, identical synthetic rows, and
unchanged RLS flags/policies, schema/table/column/function ACLs, function bodies,
constraints and triggers. A wrong-definition collision on the last index verifies
rollback of the earlier five builds. Forced-plan equality checks verify each
new index is usable; forcing scans on tiny fixtures is not performance evidence.
FK rejection and deletion cascades check that reports, cleanup registry and
unrelated users retain their existing semantics. The original security tests
then run independently on a fresh chain, including anonymous/cross-user access,
moderation, quotas, media verification and account deletion.

All tests use disposable synthetic PostgreSQL, not hosted user rows or secrets.
The harness's minimal auth stub does not prove Supabase Auth/PostgREST behavior.
Before hosted application, require exact-revision CI and authorization. After
application, recheck valid index definitions and FK coverage, compare security
metadata, and rerun the performance advisor. Local success alone is not hosted
application evidence and does not close other release gates.

Local verification on 2026-11-09: all 111 embedded PostgreSQL checks (100 existing
plus 11 index-related checks), all 9 RLS-helper checks, Node syntax checks,
repository policy and whitespace checks passed.

## Hosted application verified, 2026-11-09

After all seven checks passed for `b4f39445b386dd3bd9ec682af5214b04233f9f41`,
the six-index migration was applied once to the designated staging project.
Preflight found zero accounts or rows in the affected tables, no other active
client sessions/open transactions and no waiting locks. Each table occupied
8 KiB excluding indexes. The existing index definitions and security metadata
were captured before application; no same-name index or migration existed.

Supabase recorded version `20261109145425`. The source filename was aligned to
that recorded version without changing the SQL bytes, whose SHA-256 is
`690ca988d78c35ffc8cc45033d5590b56716a1dd02abf34b3847e0fd70edf868`.
Do not replay this migration.

Read-only postflight verified all six indexes' exact definitions, valid/ready/live
flags, nonunique/full B-tree shape and single target columns. All 28 pre-existing
public/private index definitions were unchanged; every final public FK now has
a usable leading B-tree key. Eight hashes covering table/RLS security, column
grants, policies, functions, constraints, triggers, schema grants and default
grants were identical. All recorded account/content counts remained zero.

The performance advisor no longer reports the six uncovered FKs. It still reports
12 per-row Auth RLS evaluations, two private event tables without primary keys
and 14 unused indexes in this empty project. These are separate findings, not a
reason to remove required indexes or change policies without review. This
verification establishes schema consistency, not production performance, actual
query-plan speedup, real-user behavior, image delivery or release readiness.
