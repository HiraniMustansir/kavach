-- member_self_prefs lets a guardian update their own row; stop them changing role/keys (viewer -> owner).
create function private.guard_member_update() returns trigger language plpgsql as $$
begin
  if current_user = 'authenticated'
     and (new.role, new.family_id, new.guardian_id) is distinct from (old.role, old.family_id, old.guardian_id)
     and not private.is_member(old.family_id, array['owner']) then
    raise exception 'only owners can change membership' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger family_member_guard before update on public.family_member
  for each row execute function private.guard_member_update();
