-- ============================================
-- Job-Hunt Agent — Migration 004: multi-tenant auth (Brick 9)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- One profile per authenticated user (see DECISIONS.md ADR-008). Nulls
-- are allowed by a plain UNIQUE constraint in Postgres (they never
-- conflict with each other), so any pre-auth row with user_id still
-- null is left alone rather than erroring this migration out.
alter table profiles
  add constraint profiles_user_id_key unique (user_id);

-- ---------- Row Level Security ----------
-- Defense in depth, not the primary enforcement boundary: the FastAPI
-- server always connects with the service-role key (bypasses RLS) and
-- is itself what scopes every query to the authenticated caller's
-- profile_id (see server/services/auth.py). These policies only matter
-- if something ever queries Supabase directly with the anon key, which
-- Golden Rule 1 says shouldn't happen from the Flutter app — but they're
-- cheap insurance and the standard-practice thing to show in a portfolio
-- project that talks about auth at all.

alter table profiles enable row level security;
create policy "profiles: owner read/write" on profiles
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

alter table matches enable row level security;
create policy "matches: owner read/write" on matches
  for all using (profile_id in (select id from profiles where user_id = auth.uid()));

alter table applications enable row level security;
create policy "applications: owner read/write" on applications
  for all using (profile_id in (select id from profiles where user_id = auth.uid()));

alter table tailored_resumes enable row level security;
create policy "tailored_resumes: owner read/write" on tailored_resumes
  for all using (profile_id in (select id from profiles where user_id = auth.uid()));

-- jobs is a shared pool with no owner — any authenticated user may read
-- it; only the server (service role, bypasses RLS) ever writes to it.
alter table jobs enable row level security;
create policy "jobs: authenticated read" on jobs
  for select using (auth.role() = 'authenticated');
