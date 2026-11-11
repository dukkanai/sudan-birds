-- TEST ONLY. Install exclusively in the disposable sudan-birds-local stack.
-- Never a migration. Narrow, service-only fixture adapter; removed with the stack.
create function public.local_http_fixture(p_owner uuid, p_mode text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
  if not exists(select 1 from auth.users where id=p_owner
    and email like 'remaining-%@sudan-birds.invalid') then
    raise exception 'Synthetic owner required';
  end if;
  if p_mode='seed' then
    insert into private.object_registry(object_key,owner_id,intent_id,kind,safe_delete_after,create_only)
    select 'verified/'||p_owner||'/synthetic-'||n||'.jpg',p_owner,gen_random_uuid(),'clean',now()-interval '1 minute',true
    from generate_series(1,4) n;
  elsif p_mode='retry' then
    update private.account_deletion_jobs set lease_until=null,last_attempt_at=null where owner_id=p_owner;
  elsif p_mode<>'inspect' then raise exception 'Invalid fixture mode';
  end if;
  select jsonb_build_object('remaining',count(*) filter(where deleted_at is null),
    'fenced',count(*) filter(where fenced_at is not null)) into result
    from private.object_registry where owner_id=p_owner;
  return result;
end $$;
revoke all on function public.local_http_fixture(uuid,text) from public,anon,authenticated;
grant execute on function public.local_http_fixture(uuid,text) to service_role;
notify pgrst, 'reload schema';
