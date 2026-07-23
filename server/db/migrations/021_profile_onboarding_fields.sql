-- ============================================
-- Job-Hunt Agent — Migration 021: profile onboarding fields (frontend rebuild v2, Phase 4)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- The extra profile facts the rebuilt onboarding (§4.1) collects beyond the
-- resume parse. All nullable / defaulted: existing profiles predate these
-- questions and must stay valid without a backfill.
alter table profiles
  add column if not exists branch text,                 -- academic branch/major, e.g. "CSE"
  add column if not exists grad_year integer,           -- expected/actual graduation year
  add column if not exists cgpa real,                   -- 0.0..10.0 (or GPA scale)
  add column if not exists company text,                -- current employer, if working
  add column if not exists experience_years real,       -- total professional experience
  add column if not exists notice_period_days integer,  -- for working candidates
  -- Preferred job cities, an ordered list the filter/match paths read. jsonb (not
  -- text[]) to match how the app already ships list fields as JSON, default '[]'
  -- so a never-onboarded profile reads as "no preference" rather than NULL.
  add column if not exists target_locations jsonb not null default '[]'::jsonb;

-- Widen the onboarding state machine for the new steps this data implies. The
-- rebuilt flow inserts academics/experience/locations between the existing
-- 'student_info' and 'roles' steps. NOTE: Phase 5 owns the onboarding SCREENS
-- and is the final authority on these step names — if it settles on different
-- labels, that's a one-line follow-up ALTER, not a data migration. Keeping the
-- old values ('welcome'..'student_info'..'roles'..'done') so no existing row
-- is invalidated. Pattern mirrors migration 014.
alter table profiles drop constraint if exists profiles_onboarding_step_check;
alter table profiles add constraint profiles_onboarding_step_check
  check (onboarding_step in (
    'welcome', 'resume', 'review', 'student_info',
    'academics', 'experience', 'locations',
    'roles', 'done'
  ));
