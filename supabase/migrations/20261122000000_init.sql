-- Kavach initial schema (design.md §4.1). Devices never touch tables directly:
-- Edge Functions verify the device signature and use the service role.

create table guardian (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  phone_e164 text unique,
  locale text default 'en-IN',
  created_at timestamptz default now()
);

create table family (
  id uuid primary key default gen_random_uuid(),
  name text,
  plan text not null default 'free' check (plan in ('free','plus','family')),
  created_at timestamptz default now()
);

create table family_member (
  family_id uuid references family(id) on delete cascade,
  guardian_id uuid references guardian(id) on delete cascade,
  role text not null check (role in ('owner','guardian','viewer')),
  notify_prefs jsonb default '{}',
  primary key (family_id, guardian_id)
);
create index on family_member (guardian_id);

create table child (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references family(id) on delete cascade,
  nickname text not null,
  birth_year int not null check (birth_year between 2005 and 2030),
  avatar text,
  created_at timestamptz default now()
);
create index on child (family_id);

create table device (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null references child(id) on delete cascade,
  platform text not null default 'android',
  model text, oem text, os_version text, app_version text,
  tier text not null check (tier in ('A','B','C')),
  pubkey bytea not null,
  fcm_token text,
  health_state text default 'protected' check (health_state in ('protected','degraded','offline','paused')),
  health_reason text,
  last_heartbeat timestamptz,
  paired_at timestamptz default now(),
  unpaired_at timestamptz
);
create index on device (child_id);

create table pairing_token (
  token_hash bytea primary key,
  child_id uuid references child(id) on delete cascade,
  tier text check (tier in ('A','B','C')),
  created_by uuid references guardian(id),
  expires_at timestamptz not null,
  used_at timestamptz
);

create table consent_record (
  id uuid primary key default gen_random_uuid(),
  family_id uuid references family(id),
  guardian_id uuid references guardian(id),
  child_id uuid references child(id),
  notice_version text not null,
  scopes jsonb not null,
  verification_method text not null,
  verification_ref text,
  granted_at timestamptz default now(),
  revoked_at timestamptz
);

create table policy (
  child_id uuid references child(id) on delete cascade,
  version int not null,
  body jsonb not null,
  updated_by uuid references guardian(id),
  updated_at timestamptz default now(),
  primary key (child_id, version)
);

-- PK must include the partition key on a partitioned table.
create table risk_event (
  id text not null,
  device_id uuid references device(id) on delete cascade,
  child_id uuid references child(id) on delete cascade,
  occurred_at timestamptz not null,
  received_at timestamptz default now(),
  category text not null, severity text not null check (severity in ('low','medium','high','critical')),
  score real not null,
  app_pkg text not null, app_label text, domain text,
  duration_s int, description text not null, custom_keyword text,
  status text default 'new' check (status in ('new','seen','resolved','dismissed')),
  feedback text check (feedback in ('useful','not_a_problem')),
  primary key (id, occurred_at)
) partition by range (occurred_at);
-- shortcut: single default partition, switch to monthly partitions (pg_partman) before 90-day retention drops are needed
create table risk_event_default partition of risk_event default;
create index on risk_event (child_id, occurred_at desc);

create table daily_digest (
  child_id uuid references child(id) on delete cascade,
  day date not null,
  stats jsonb not null,
  summary_text text, summary_model text,
  delivered_at timestamptz,
  primary key (child_id, day)
);

create table health_event (
  id bigserial primary key,
  device_id uuid references device(id) on delete cascade,
  at timestamptz default now(), state text, reason text
);
create index on health_event (device_id, at desc);

create table audit_log (
  id bigserial primary key, actor uuid, action text, target text, meta jsonb, at timestamptz default now()
);

-- ---------- RLS ----------
-- security definer helpers avoid recursive RLS on family_member.
create function is_member(fid uuid, roles text[] default array['owner','guardian','viewer'])
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.family_member
                 where family_id = fid and guardian_id = auth.uid() and role = any(roles));
$$;

create function child_family(cid uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select family_id from public.child where id = cid;
$$;

alter table guardian       enable row level security;
alter table family         enable row level security;
alter table family_member  enable row level security;
alter table child          enable row level security;
alter table device         enable row level security;
alter table pairing_token  enable row level security;  -- service role only
alter table consent_record enable row level security;
alter table policy         enable row level security;
alter table risk_event     enable row level security;
alter table daily_digest   enable row level security;
alter table health_event   enable row level security;
alter table audit_log      enable row level security;  -- service role only

create policy guardian_self on guardian for all to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy guardian_cofamily_read on guardian for select to authenticated
  using (exists (select 1 from family_member fm where fm.guardian_id = guardian.id and is_member(fm.family_id)));

-- family + owner membership are created server-side (Edge Function) to keep ownership atomic.
create policy family_read on family for select to authenticated using (is_member(id));
create policy family_update on family for update to authenticated
  using (is_member(id, array['owner'])) with check (is_member(id, array['owner']));
-- plan changes only via billing webhook (service role)
revoke update on family from authenticated;
grant update (name) on family to authenticated;

create policy member_read on family_member for select to authenticated using (is_member(family_id));
create policy member_owner_write on family_member for all to authenticated
  using (is_member(family_id, array['owner'])) with check (is_member(family_id, array['owner']));
-- a guardian may edit their own notification prefs
create policy member_self_prefs on family_member for update to authenticated
  using (guardian_id = (select auth.uid())) with check (guardian_id = (select auth.uid()));

create policy child_read on child for select to authenticated using (is_member(family_id));
create policy child_write on child for all to authenticated
  using (is_member(family_id, array['owner','guardian'])) with check (is_member(family_id, array['owner','guardian']));

create policy device_read on device for select to authenticated using (is_member(child_family(child_id)));

create policy consent_read on consent_record for select to authenticated using (is_member(family_id));

create policy policy_read on policy for select to authenticated using (is_member(child_family(child_id)));
create policy policy_insert on policy for insert to authenticated
  with check (is_member(child_family(child_id), array['owner','guardian']) and updated_by = (select auth.uid()));

create policy event_read on risk_event for select to authenticated using (is_member(child_family(child_id)));
create policy event_feedback on risk_event for update to authenticated
  using (is_member(child_family(child_id), array['owner','guardian']))
  with check (is_member(child_family(child_id), array['owner','guardian']));
-- guardians may only change triage fields, never the event itself
revoke update on risk_event from authenticated;
grant update (status, feedback) on risk_event to authenticated;

create policy digest_read on daily_digest for select to authenticated using (is_member(child_family(child_id)));

create policy health_read on health_event for select to authenticated
  using (exists (select 1 from device d where d.id = health_event.device_id and is_member(child_family(d.child_id))));

revoke execute on function is_member(uuid, text[]), child_family(uuid) from anon, public;
grant execute on function is_member(uuid, text[]), child_family(uuid) to authenticated;
