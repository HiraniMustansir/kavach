-- Keep RLS helpers out of the PostgREST-exposed schema (advisor 0029).
create schema if not exists private;
grant usage on schema private to authenticated;
alter function public.is_member(uuid, text[]) set schema private;
alter function public.child_family(uuid) set schema private;
