-- Platform-created event helper, not an application RPC. Preserve its definition
-- and ensure_rls trigger. Fresh local projects may not install this helper.
begin;
do $migration$
declare
  helper oid := pg_catalog.to_regprocedure('public.rls_auto_enable()');
begin
  if helper is null then
    if exists (
      select 1 from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'rls_auto_enable'
    ) then
      raise exception 'Unexpected public.rls_auto_enable signature' using errcode = '55000';
    end if;
    raise notice 'No platform rls_auto_enable helper installed; nothing to revoke';
    return;
  end if;
  if (select p.prorettype <> 'pg_catalog.event_trigger'::pg_catalog.regtype
      from pg_catalog.pg_proc p where p.oid = helper)
     or (select count(*) <> 1 from pg_catalog.pg_proc p
         join pg_catalog.pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'rls_auto_enable') then
    raise exception 'Unexpected public.rls_auto_enable signature' using errcode = '55000';
  end if;

  -- PUBLIC is essential: the observed NULL ACL grants EXECUTE through PUBLIC.
  revoke execute on function public.rls_auto_enable() from public, anon, authenticated;

  -- Fail closed if a future inherited grant still permits either API role.
  if pg_catalog.has_function_privilege('anon', helper, 'EXECUTE')
     or pg_catalog.has_function_privilege('authenticated', helper, 'EXECUTE') then
    raise exception 'API roles retain inherited access to rls_auto_enable' using errcode = '55000';
  end if;
end;
$migration$;
commit;
