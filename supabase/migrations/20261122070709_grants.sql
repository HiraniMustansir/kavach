-- Explicit grants; RLS policies narrow these further. anon gets nothing.
grant select on guardian, family, family_member, child, device, consent_record,
                policy, risk_event, daily_digest, health_event to authenticated;
grant insert, update on guardian to authenticated;
grant update (name) on family to authenticated;
grant insert, update, delete on family_member, child to authenticated;
grant insert on policy to authenticated;
grant update (status, feedback) on risk_event to authenticated;
