-- ============================================
-- Job-Hunt Agent — Migration 006: scope llm_calls per profile (Phase 3)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- llm_calls predates multi-tenant auth (Brick 9) and has never carried a
-- profile_id — every call was logged as one global stream. Nullable
-- because POST /resume/parse logs a call before a profile row exists yet
-- (the parse result is what creates it); every other task attributes to
-- the caller's profile.
alter table llm_calls
  add column if not exists profile_id uuid references profiles(id) on delete set null;

create index if not exists llm_calls_profile_id_idx on llm_calls(profile_id);

-- Same defense-in-depth posture as 004_auth.sql: the server always
-- connects with the service-role key and does the actual scoping itself
-- (services/llm.py callers pass the caller's profile_id). This policy
-- only matters if something ever queries Supabase directly with the
-- anon key.
alter table llm_calls enable row level security;
drop policy if exists "llm_calls: owner read" on llm_calls;
create policy "llm_calls: owner read" on llm_calls
  for select using (profile_id in (select id from profiles where user_id = auth.uid()));
