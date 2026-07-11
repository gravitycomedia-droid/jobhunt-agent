-- ============================================
-- Job-Hunt Agent — Migration 014: student/experienced onboarding info
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- employment_type: self-reported (never extracted from a resume). usn:
-- Indian engineering college register number — the parser (services/llm.py
-- PARSE_SYSTEM_PROMPT) tries to extract it when visible, so it's usually
-- already set by the time the new onboarding step below would ask for it.
alter table profiles add column if not exists employment_type text
  check (employment_type in ('student', 'experienced'));
alter table profiles add column if not exists usn text;

-- New onboarding step 'student_info' inserted between 'review' and 'roles'
-- (see routers/resume.py's ONBOARDING_STEPS). Existing rows already sit at
-- one of the pre-existing values, so no backfill is needed — 'done' rows
-- stay 'done', and rows mid-flow at 'review' or earlier simply walk
-- through the new step next time they advance.
alter table profiles drop constraint if exists profiles_onboarding_step_check;
alter table profiles add constraint profiles_onboarding_step_check
  check (onboarding_step in ('welcome', 'resume', 'review', 'student_info', 'roles', 'done'));
