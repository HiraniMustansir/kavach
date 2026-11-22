-- 4. Read policies compare against the caller's child/device ids, computed once per query
--    (array(select ...) becomes an initPlan and can use the child_id indexes), not two lookups per row.
create function private.my_child_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select c.id from public.child c
  join public.family_member fm on fm.family_id = c.family_id
  where fm.guardian_id = auth.uid();
$$;
create function private.my_device_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select d.id from public.device d where d.child_id in (select private.my_child_ids());
$$;
revoke execute on function private.my_child_ids(), private.my_device_ids() from anon, public;
grant execute on function private.my_child_ids(), private.my_device_ids() to authenticated;

drop policy device_read on device;
create policy device_read on device for select to authenticated
  using (child_id = any(array(select private.my_child_ids())));
drop policy policy_read on policy;
create policy policy_read on policy for select to authenticated
  using (child_id = any(array(select private.my_child_ids())));
drop policy event_read on risk_event;
create policy event_read on risk_event for select to authenticated
  using (child_id = any(array(select private.my_child_ids())));
drop policy digest_read on daily_digest;
create policy digest_read on daily_digest for select to authenticated
  using (child_id = any(array(select private.my_child_ids())));
drop policy health_read on health_event;
create policy health_read on health_event for select to authenticated
  using (device_id = any(array(select private.my_device_ids())));

-- 5. No adult profiles. Birth year only (ACC-4), so a 17-year-old born late in the
--    year 18 years ago is also refused: err towards never monitoring an adult.
create function private.child_age_gate() returns trigger language plpgsql as $$
begin
  if extract(year from now() at time zone 'Asia/Kolkata')::int - new.birth_year >= 18 then
    raise exception 'child profiles must be under 18' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger child_age_gate before insert or update of birth_year on public.child
  for each row execute function private.child_age_gate();
