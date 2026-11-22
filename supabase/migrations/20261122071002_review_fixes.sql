-- 1. Members may never move their row to another family/guardian; only owners change roles.
create or replace function private.guard_member_update() returns trigger language plpgsql as $$
begin
  if current_user = 'authenticated' then
    if (new.family_id, new.guardian_id) is distinct from (old.family_id, old.guardian_id) then
      raise exception 'membership keys cannot change' using errcode = '42501';
    end if;
    if new.role is distinct from old.role and not private.is_member(old.family_id, array['owner']) then
      raise exception 'only owners can change roles' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

-- 2. Deleting a guardian/family/child must not be blocked by history rows.
--    Consent records survive (retention per counsel) with the link nulled.
alter table policy drop constraint policy_updated_by_fkey,
  add constraint policy_updated_by_fkey foreign key (updated_by) references guardian(id) on delete set null;
alter table pairing_token drop constraint pairing_token_created_by_fkey,
  add constraint pairing_token_created_by_fkey foreign key (created_by) references guardian(id) on delete set null;
alter table consent_record
  drop constraint consent_record_guardian_id_fkey,
  drop constraint consent_record_family_id_fkey,
  drop constraint consent_record_child_id_fkey,
  add constraint consent_record_guardian_id_fkey foreign key (guardian_id) references guardian(id) on delete set null,
  add constraint consent_record_family_id_fkey foreign key (family_id) references family(id) on delete set null,
  add constraint consent_record_child_id_fkey foreign key (child_id) references child(id) on delete set null;

-- 3. Phone number comes from the verified auth login, never from the client.
revoke insert, update on guardian from authenticated;
grant insert (id, display_name, locale) on guardian to authenticated;
grant update (display_name, locale) on guardian to authenticated;

create function private.guardian_phone_from_auth() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.phone_e164 := '+' || nullif((select phone from auth.users where id = new.id), '');
  return new;
end $$;
create trigger guardian_phone before insert on public.guardian
  for each row execute function private.guardian_phone_from_auth();
