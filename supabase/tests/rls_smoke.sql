-- RLS smoke test. Runs in one DO block and always rolls back: success = error 'ALL_OK'.
do $$
declare a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); v uuid := gen_random_uuid();
        f uuid; c uuid; n int; denied bool := false;
begin
  insert into auth.users (id, aud, role) values (a,'authenticated','authenticated'), (b,'authenticated','authenticated'), (v,'authenticated','authenticated');
  insert into guardian (id, display_name) values (a,'A'), (b,'B'), (v,'V');
  insert into family default values returning id into f;
  insert into family_member values (f, a, 'owner'), (f, v, 'viewer');
  insert into child (family_id, nickname, birth_year) values (f,'kid',2015) returning id into c;
  insert into risk_event (id, child_id, occurred_at, category, severity, score, app_pkg, description)
    values ('e1', c, now(), 'GORE', 'high', 0.9, 'com.x', 'test');

  set local role authenticated;
  -- outsider
  perform set_config('request.jwt.claims', json_build_object('sub', b)::text, true);
  select count(*) into n from child; assert n = 0, 'B sees child';
  select count(*) into n from risk_event; assert n = 0, 'B sees event';
  select count(*) into n from guardian; assert n = 1, 'B sees other guardians';

  -- viewer
  perform set_config('request.jwt.claims', json_build_object('sub', v)::text, true);
  select count(*) into n from risk_event; assert n = 1, 'viewer cannot read';
  update risk_event set status = 'seen'; get diagnostics n = row_count; assert n = 0, 'viewer can triage';
  update family_member set notify_prefs = '{"x":1}' where guardian_id = v; get diagnostics n = row_count; assert n = 1, 'viewer cannot set prefs';
  begin update family_member set role = 'owner' where guardian_id = v; exception when insufficient_privilege then denied := true; end;
  assert denied, 'viewer self-promoted'; denied := false;

  -- owner
  perform set_config('request.jwt.claims', json_build_object('sub', a)::text, true);
  select count(*) into n from child; assert n = 1, 'owner cannot see child';
  update risk_event set status = 'seen' where id = 'e1'; get diagnostics n = row_count; assert n = 1, 'owner cannot triage';
  begin update risk_event set description = 'x'; exception when insufficient_privilege then denied := true; end;
  assert denied, 'owner could rewrite event'; denied := false;
  begin update family set plan = 'family'; exception when insufficient_privilege then denied := true; end;
  assert denied, 'owner could change plan';
  raise exception 'ALL_OK';
end $$;
