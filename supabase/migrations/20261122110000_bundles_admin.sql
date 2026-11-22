-- CLS-8 signed rule/model bundles + ADM-1..3 admin console (aggregates, bundles, abuse handling).

-- Bundles: files live in the private `bundles` storage bucket under <version>/; the manifest is
-- signed offline (tools/bundle.ts) with the ECDSA P-256 key whose public half is pinned in the app.
create table rule_bundle (
  version text primary key,                -- e.g. 2026.11.22-1
  manifest jsonb not null,                 -- {version, files:[{name, sha256, size}]}
  signature text not null,                 -- base64 DER ECDSA-SHA256 over the manifest bytes as stored
  manifest_text text not null,             -- exact signed bytes (jsonb would reorder keys)
  rollout_pct int not null default 0 check (rollout_pct between 0 and 100),
  status text not null default 'draft' check (status in ('draft','active','revoked')),
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
alter table rule_bundle enable row level security; -- service role + admin RPCs only

insert into storage.buckets (id, name, public) values ('bundles', 'bundles', false) on conflict (id) do nothing;

-- Admins (internal staff). Added by hand: insert into admin_user values ('<auth user id>');
create table admin_user (user_id uuid primary key references auth.users(id) on delete cascade);
alter table admin_user enable row level security;

create function private.is_admin() returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.admin_user where user_id = auth.uid());
$$;
grant execute on function private.is_admin() to authenticated;

-- ADM-3: misuse reports (e.g. an adult being monitored). From the child phone via the device function,
-- or from a signed-in parent.
create table abuse_report (
  id bigserial primary key,
  family_id uuid references family(id) on delete set null,
  device_id uuid references device(id) on delete set null,
  reporter text not null check (reporter in ('child_device','guardian')),
  reporter_guardian uuid references guardian(id) on delete set null,
  message text check (length(message) <= 1000),
  status text not null default 'open' check (status in ('open','reviewing','actioned','dismissed')),
  admin_note text,
  created_at timestamptz default now(),
  resolved_at timestamptz
);
alter table abuse_report enable row level security;
create policy report_insert on abuse_report for insert to authenticated
  with check (reporter = 'guardian' and reporter_guardian = (select auth.uid()));
grant insert (family_id, reporter, reporter_guardian, message) on abuse_report to authenticated;

alter table family add column suspended_at timestamptz;

-- ---------- admin RPCs (ADM-2: aggregates only, no per-family event detail) ----------

create function public.admin_metrics(p_days int default 14) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare since timestamptz := now() - make_interval(days => least(greatest(p_days, 1), 90));
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  return jsonb_build_object(
    'families', (select count(*) from public.family),
    'children', (select count(*) from public.child),
    'devices', (select jsonb_object_agg(health_state, n) from (
      select health_state, count(*) n from public.device where unpaired_at is null group by 1) t),
    'devicesByOem', (select jsonb_object_agg(coalesce(oem, '?'), n) from (
      select lower(oem) oem, count(*) n from public.device where unpaired_at is null group by 1 order by 2 desc limit 15) t),
    'alertsByDay', (select coalesce(jsonb_agg(t order by day), '[]') from (
      select date_trunc('day', occurred_at)::date as day, severity, count(*) as n
      from public.risk_event where occurred_at >= since group by 1, 2) t),
    'alertsByCategory', (select jsonb_object_agg(category, n) from (
      select category, count(*) n from public.risk_event where occurred_at >= since group by 1) t),
    -- precision proxy per category: share of labelled alerts marked useful (PRD §2.3 KPI)
    'feedback', (select coalesce(jsonb_agg(t), '[]') from (
      select category, count(*) filter (where feedback = 'useful') useful,
             count(*) filter (where feedback = 'not_a_problem') not_a_problem
      from public.risk_event where occurred_at >= since and feedback is not null group by 1) t),
    'bundleVersions', (select jsonb_object_agg(coalesce(model_version, '?'), n) from (
      select model_version, count(*) n from public.device where unpaired_at is null group by 1) t),
    'openReports', (select count(*) from public.abuse_report where status in ('open','reviewing'))
  );
end $$;

create function public.admin_bundles() returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  return query select jsonb_build_object('version', version, 'files', manifest->'files', 'rollout_pct', rollout_pct,
    'status', status, 'created_at', created_at, 'updated_at', updated_at) from public.rule_bundle order by created_at desc;
end $$;

create function public.admin_set_bundle(p_version text, p_status text, p_rollout int) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  update public.rule_bundle set status = p_status, rollout_pct = p_rollout, updated_at = now() where version = p_version;
  if not found then raise exception 'no such bundle'; end if;
  insert into public.audit_log (actor, action, target, meta)
    values (auth.uid(), 'bundle.set', p_version, jsonb_build_object('status', p_status, 'rollout', p_rollout));
end $$;

create function public.admin_reports() returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  -- Report text + family size only; no alerts or usage (ADM-2: no per-family event access).
  return query select jsonb_build_object('id', r.id, 'family_id', r.family_id, 'reporter', r.reporter, 'message', r.message,
    'status', r.status, 'admin_note', r.admin_note, 'created_at', r.created_at,
    'family_suspended', f.suspended_at is not null,
    'children', (select count(*) from public.child c where c.family_id = r.family_id),
    'devices', (select count(*) from public.device d join public.child c on c.id = d.child_id
                where c.family_id = r.family_id and d.unpaired_at is null))
  from public.abuse_report r left join public.family f on f.id = r.family_id order by r.created_at desc limit 200;
end $$;

-- ADM-3 action: suspend the family → every device is told to unpair, parent API refuses further actions.
create function public.admin_resolve_report(p_id bigint, p_status text, p_note text, p_suspend boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare fid uuid;
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  update public.abuse_report set status = p_status, admin_note = p_note,
    resolved_at = case when p_status in ('actioned','dismissed') then now() end
  where id = p_id returning family_id into fid;
  if not found then raise exception 'no such report'; end if;
  if p_suspend and fid is not null then
    update public.family set suspended_at = now() where id = fid and suspended_at is null;
    insert into public.device_command (device_id, kind, args)
      select d.id, 'unpair', '{"reason":"suspended"}' from public.device d join public.child c on c.id = d.child_id
      where c.family_id = fid and d.unpaired_at is null;
  end if;
  insert into public.audit_log (actor, action, target, meta)
    values (auth.uid(), 'report.resolve', p_id::text, jsonb_build_object('status', p_status, 'suspend', p_suspend));
end $$;

revoke execute on function public.admin_metrics(int), public.admin_bundles(), public.admin_set_bundle(text, text, int),
  public.admin_reports(), public.admin_resolve_report(bigint, text, text, boolean) from anon, public;
grant execute on function public.admin_metrics(int), public.admin_bundles(), public.admin_set_bundle(text, text, int),
  public.admin_reports(), public.admin_resolve_report(bigint, text, text, boolean) to authenticated;
