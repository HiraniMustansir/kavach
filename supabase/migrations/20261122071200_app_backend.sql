-- Backend pieces the app needs beyond design.md §4.1: onboarding RPC, push tokens,
-- device commands, child requests, device live fields, request nonces, cron jobs.

-- Device live state (TMP-7/8, DASH-2). shortcut: heartbeats update device directly; move to an
-- unlogged device_live table when heartbeat writes become a hot spot (design §4.5).
alter table device add column battery int, add column screen_on_recent boolean default false,
  add column policy_version int, add column model_version text, add column current_app text,
  add column today jsonb; -- {usedMin, minutesLeft, topApps:[{label,pkg,min}]} for the parent Today card (DASH-3)

create table guardian_push_token (
  token text primary key,
  guardian_id uuid not null references guardian(id) on delete cascade,
  platform text not null check (platform in ('android','ios')),
  updated_at timestamptz default now()
);
create index on guardian_push_token (guardian_id);
alter table guardian_push_token enable row level security;
create policy push_token_own on guardian_push_token for all to authenticated
  using (guardian_id = (select auth.uid())) with check (guardian_id = (select auth.uid()));
grant select, insert, update, delete on guardian_push_token to authenticated;

-- Parent → device commands (CTL-6, CTL-8, PAIR-6). Written by Edge Function, polled + pushed to device.
create table device_command (
  id bigserial primary key,
  device_id uuid not null references device(id) on delete cascade,
  kind text not null check (kind in ('lock','unlock','pause','resume','add_time','unpair','sync_policy')),
  args jsonb not null default '{}',
  created_by uuid references guardian(id) on delete set null,
  created_at timestamptz default now(),
  acked_at timestamptz
);
create index on device_command (device_id) where acked_at is null;
alter table device_command enable row level security;
create policy command_read on device_command for select to authenticated
  using (device_id = any(array(select private.my_device_ids())));
grant select on device_command to authenticated;

-- Child requests: more time / an app (CTL-7, KID-4).
create table child_request (
  id bigserial primary key,
  child_id uuid not null references child(id) on delete cascade,
  device_id uuid references device(id) on delete cascade,
  kind text not null check (kind in ('more_time','app')),
  minutes int, app_pkg text, reason text,
  status text not null default 'pending' check (status in ('pending','approved','denied')),
  decided_by uuid references guardian(id) on delete set null,
  created_at timestamptz default now(), decided_at timestamptz
);
create index on child_request (child_id, created_at desc);
alter table child_request enable row level security;
create policy request_read on child_request for select to authenticated
  using (child_id = any(array(select private.my_child_ids())));
grant select on child_request to authenticated;

-- Replay protection for signed device requests (design §4.2).
create table request_nonce (
  device_id uuid not null, nonce text not null, at timestamptz default now(),
  primary key (device_id, nonce)
);
alter table request_nonce enable row level security;  -- service role only

-- Push bookkeeping for rate limiting / batching (ALR-4, ALR-5).
alter table risk_event add column pushed_at timestamptz;

-- Consent: guardians record and revoke their own consent (VPC-3/4). Rows are never deleted.
create policy consent_insert on consent_record for insert to authenticated
  with check (guardian_id = (select auth.uid()) and private.is_member(family_id, array['owner','guardian']));
create policy consent_revoke on consent_record for update to authenticated
  using (guardian_id = (select auth.uid())) with check (guardian_id = (select auth.uid()));
grant insert (family_id, guardian_id, child_id, notice_version, scopes, verification_method, verification_ref)
  on consent_record to authenticated;
grant update (revoked_at) on consent_record to authenticated;

-- Onboarding (ACC-3): guardian + family + owner membership in one transaction.
create function public.create_family(p_display_name text, p_family_name text default null, p_locale text default 'en-IN')
returns uuid language plpgsql security definer set search_path = '' as $$
declare fid uuid; uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not signed in' using errcode = '42501'; end if;
  insert into public.guardian (id, display_name, locale) values (uid, p_display_name, p_locale)
    on conflict (id) do update set display_name = excluded.display_name;
  select family_id into fid from public.family_member where guardian_id = uid and role = 'owner' limit 1;
  if fid is null then
    insert into public.family (name) values (p_family_name) returning id into fid;
    insert into public.family_member (family_id, guardian_id, role) values (fid, uid, 'owner');
  end if;
  return fid;
end $$;
revoke execute on function public.create_family(text, text, text) from anon, public;
grant execute on function public.create_family(text, text, text) to authenticated;

-- Used by the digest function (service role only).
create function public.child_owner_locale(cid uuid) returns text language sql stable set search_path = '' as $$
  select g.locale from public.child c
  join public.family_member fm on fm.family_id = c.family_id and fm.role = 'owner'
  join public.guardian g on g.id = fm.guardian_id
  where c.id = cid limit 1;
$$;
revoke execute on function public.child_owner_locale(uuid) from anon, authenticated, public;

-- Cron: heartbeat sweeper + digest fallback + nonce cleanup, via the `cron` Edge Function.
-- Needs vault secrets `project_url` and `cron_secret` (see README).
create extension if not exists pg_cron;
create extension if not exists pg_net;
select cron.schedule('kavach-cron', '*/5 * * * *', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/cron',
    headers := jsonb_build_object('Content-Type','application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
    body := '{}'::jsonb)
$$);
select cron.schedule('kavach-nonce-gc', '*/10 * * * *', $$ delete from public.request_nonce where at < now() - interval '10 minutes' $$);
-- Retention (§8 Privacy): events 90 days, digests 1 year.
select cron.schedule('kavach-retention', '17 3 * * *', $$
  delete from public.risk_event where occurred_at < now() - interval '90 days';
  delete from public.daily_digest where day < current_date - 365;
  delete from public.health_event where at < now() - interval '90 days';
$$);

-- Late-digest fallback: children with a paired device and no digest for p_day, in one bounded query.
create function public.children_missing_digest(p_day date, p_limit int default 500)
returns table (child_id uuid, nickname text, last_heartbeat timestamptz)
language sql stable set search_path = '' as $$
  select c.id, c.nickname, max(d.last_heartbeat)
  from public.device d join public.child c on c.id = d.child_id
  where d.unpaired_at is null
    and not exists (select 1 from public.daily_digest g where g.child_id = c.id and g.day = p_day)
  group by c.id, c.nickname
  limit p_limit;
$$;
revoke execute on function public.children_missing_digest(date, int) from anon, authenticated, public;

-- Edge Functions run as service_role. This project has no default grants, so give it explicit rights
-- on everything (it already bypasses RLS) and on whatever later migrations create.
grant usage on schema public, private to service_role;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant execute on all functions in schema public, private to service_role;
alter default privileges in schema public grant all on tables to service_role;
alter default privileges in schema public grant all on sequences to service_role;
alter default privileges in schema public grant execute on functions to service_role;
