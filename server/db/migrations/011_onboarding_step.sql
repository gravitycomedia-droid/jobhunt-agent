-- ============================================
-- Job-Hunt Agent — Migration 011: onboarding resumption (Phase 3B)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- Where the user is in onboarding, so killing the app mid-flow resumes at
-- the exact step instead of restarting from Welcome. Server-side because
-- onboarding spans reinstalls/devices; the client mirrors it in its local
-- cache for instant resume (Phase 5). Values walk forward:
--   welcome → resume → review → roles → done
alter table profiles
  add column if not exists onboarding_step text not null default 'welcome'
  check (onboarding_step in ('welcome', 'resume', 'review', 'roles', 'done'));

-- Backfill: every profile that exists today was created before step
-- tracking and belongs to a user already using the main app — mark them
-- done so nobody gets bounced back into onboarding.
update profiles set onboarding_step = 'done' where onboarding_step = 'welcome';
