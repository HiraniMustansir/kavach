-- RLS smoke test. Runs in one DO block and always rolls back: success = error 'ALL_OK'.
do $$
declare a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); v uuid := gen_random_uuid();
        f uuid; f2 uuid; c uuid; n int; denied bool := false;
begin
  insert into auth.users (id, aud, role, phone) values (a,'authenticated','authenticated','919990000001'),
    (b,'authenticated','authenticated',null), (v,'authenticated','authenticated',null);
  insert into guardian (id, display_name, phone_e164) values (a,'A','+10000000000'), (b,'B',null), (v,'V',null);
  select count(*) into n from guardian where id = a and phone_e164 = '+919990000001'; assert n = 1, 'phone not taken from auth';
  insert into family default values returning id into f;
  insert into family default values returning id into f2;
  insert into family_member values (f, a, 'owner'), (f, v, 'viewer'), (f2, b, 'owner');
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
  assert denied, 'owner could change plan'; denied := false;
  begin update family_member set family_id = f2 where guardian_id = a; exception when insufficient_privilege then denied := true; end;
  assert denied, 'owner moved into another family'; denied := false;
  begin update guardian set phone_e164 = '+911' where id = a; exception when insufficient_privilege then denied := true; end;
  assert denied, 'guardian could set own phone'; denied := false;
  insert into policy (child_id, version, body, updated_by) values (c, 1, '{}', a);

  -- account deletion must not be blocked by history rows
  reset role;
  insert into consent_record (family_id, guardian_id, child_id, notice_version, scopes, verification_method)
    values (f, a, c, 'v1', '{}', 'otp_age_decl');
  delete from auth.users where id = a;
  delete from family where id = f;
  select count(*) into n from consent_record where guardian_id is null and family_id is null; assert n = 1, 'consent record lost';
  raise exception 'ALL_OK';
end $$;
