-- Advisor 0011: pin search_path on trigger functions (both already schema-qualify everything they use).
alter function private.child_age_gate() set search_path = '';
alter function private.guard_member_update() set search_path = '';
