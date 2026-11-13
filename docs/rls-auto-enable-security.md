# Platform RLS helper hardening

## Read-only staging findings (2026-11-09)

Inspection of the scoped Sudan Birds staging database found
`public.rls_auto_enable()` owned by `postgres`, returning `event_trigger`, with
`SECURITY DEFINER`, `search_path=pg_catalog`, and a NULL function ACL. Both `anon`
and `authenticated` therefore inherit PostgreSQL's default PUBLIC EXECUTE grant.
The enabled `ensure_rls` event trigger references this function on
`ddl_command_end`, restricted to CREATE TABLE, CREATE TABLE AS, and SELECT INTO.
The body enables RLS on public tables using quoted schema/table identifiers.
Its shape matches the [Supabase event-trigger example](https://supabase.com/docs/guides/database/postgres/event-triggers).
This is consistent with a platform helper, not proof of its creation history.

This is an unnecessary privilege grant, not proof of an exploitable ordinary
REST RPC or RLS bypass. PostgreSQL's event-trigger calling convention does not
permit invoking this PL/pgSQL function as an ordinary SQL function, even before
the revoke. Its body takes no caller parameters, fixes its search path, and enables
rather than disables RLS. Restricting EXECUTE is still appropriate least-privilege
hardening. The generic advisor labels alone do not establish exploitability.
See [PostgreSQL event triggers](https://www.postgresql.org/docs/17/sql-createeventtrigger.html)
and [Supabase anonymous definer-function advisory](https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable).

## Narrow forward change

`20261109142454_harden_rls_auto_enable.sql` revokes only EXECUTE on the exact
zero-argument helper from PUBLIC, anon, and authenticated. It does not recreate,
move, disable, or drop the helper/event trigger; alter its owner/body; change default
privileges; or revoke any application RPC grants. Existing direct service-role grants,
if present, remain. A service role whose only grant was inherited from PUBLIC also
loses that unnecessary direct-call privilege. The function owner retains access.

The migration is transactional and repeatable. An unexpected return type or extra
argument overload aborts. Effective API access is checked after revocation; inherited
grants that keep API access alive abort and roll back instead of reporting success.
A fresh local installation without this platform-created helper produces an explicit
NOTICE and makes no changes. It does not invent a replacement helper. This means
migration success alone is NOT sufficient hosted acceptance evidence: a scoped
preflight must verify the expected helper and trigger are present before applying.

Seven authenticated SECURITY DEFINER application RPCs intentionally remain callable:
`is_cleanup_admin`, `moderate_content`, `moderator_report_target`,
`own_deletion_status`, `reserve_upload`, `resolve_report`, and
`reveal_listing_contact`. Their authorization checks and regression suites remain
necessary. Do not clear these advisor findings by blanket revocation.

## Regression and application gates

Run in disposable local PostgreSQL (pinned `embedded-postgres@17.6.0-beta.15`
installed outside the repository):

```sh
# Linux installation with --ignore-scripts also requires the package's bundled
# scripts/hydrate-symlinks.js to run from @embedded-postgres/linux-x64 first.
export LD_LIBRARY_PATH=/absolute/path/to/@embedded-postgres/linux-x64/native/lib
export EMBEDDED_POSTGRES_MODULE=/absolute/path/to/embedded-postgres/dist/index.js
node supabase/tests/rls_auto_enable_security.mjs
node supabase/tests/embedded_security.mjs
python3 scripts/check_repository.py
```

The focused suite checks no-helper reset behavior, wrong signatures, default PUBLIC
execution, refusal of ordinary event-trigger invocation, direct API denials after
hardening, unchanged application ACLs (including the seven authenticated RPCs),
unchanged function/event-trigger identity and definition, idempotence, and rollback
when inherited grants survive. It creates tables as a non-superuser without helper
EXECUTE for all three event tags and verifies that the existing trigger still enables
RLS. All fixtures and role changes occur only in an isolated synthetic database,
which the harness removes afterward. This is not a hosted Supautils/PostgREST test.

Before hosted application, review the exact migration and complete exact-revision CI.
After authorized application, recheck effective anon/authenticated execution=false,
helper definition/owner/return type/search path and trigger identity/tags/enabled state,
all application grants, and the security advisor. A missing helper/trigger or changed
signature requires investigation rather than accepting the local no-op path.
Hosted DDL smoke tests need their own authorization. The initial investigation
applied no hosted migration, created no hosted objects, deployed nothing, and read
no user rows or secrets. The later approved application is recorded below. Production, real sessions, media/R2, and other release gates remain open.

Local verification on 2026-11-09: all 9 focused helper checks and all 100 existing
PostgreSQL security checks passed on PostgreSQL 17.6. Node syntax, repository policy,
and whitespace checks also passed. These are working-tree checks, not exact-commit
CI or hosted application evidence.

## Hosted application (2026-11-09)

After specific owner approval, all seven checks passed for source
`0d194ece82e91770ea73267a70b96d0fa07ebdf8`. The exact reviewed migration bytes
(SHA-256 `0c63bc268c411c825299766a774e6023a2bf91420b9f543ccc650d52925729a8`)
were applied once to the scoped staging project. Supabase assigned migration
version `20261109142454`; the repository filename was aligned with that recorded
version without changing SQL content. The tested source used the provisional
filename `202611090003_harden_rls_auto_enable.sql`.

Read-only postchecks confirmed anon/authenticated effective EXECUTE=false, the
same helper/trigger OIDs, function body, owner, return type, search path and enabled
trigger tags. Catalog hashes of all other public/private function definitions and
ACLs, table RLS/ACL settings, and policy expressions were unchanged. Both advisor
findings for this helper disappeared. Seven intentional authenticated application
RPC findings remain; this is not a claim of a clean security report or end-to-end
Auth/media validation. No hosted DDL smoke fixture was created.

The generic table-list tool also warned about private tables without RLS. A
separate privilege check confirmed neither anon nor authenticated has SELECT,
INSERT, UPDATE or DELETE on any of those five tables. Private schema USAGE is
intentional for permitted helper resolution; it does not grant table data access.
The warning was not used as authority to alter private-table permissions.
