-- ============================================
-- Job-Hunt Agent — Migration 020: score_snapshots (frontend rebuild v2, Phase 4)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- One row per pipeline run per profile, capturing that day's match-quality
-- summary. GET /stats/score-history reads these to show a day-over-day delta
-- chip ("your best fit rose +6 since yesterday"). Written by _process_profile
-- (services/.../daily_pipeline) on every run — batch AND per-user run-mine.
--
-- Why a delta needs a DEDICATED snapshot table and not just "recompute from
-- matches": matches get overwritten each run, so yesterday's scores are gone by
-- the time you'd want to diff against them. The snapshot freezes the number.
--
-- R-D (see docs/20-frontend-rebuild-master-plan.md): run-mine is rate-limited
-- to 5/300s, so a user refreshing thrice a minute writes three snapshots
-- minutes apart. The READ must therefore diff against the latest snapshot at
-- least 24h older — NOT the immediately-previous row, which would be ~0 every
-- time and make the chip permanently meaningless. Day-over-day was the point.
create table if not exists score_snapshots (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  top_fit_score integer not null,   -- best single match score this run (0..100)
  avg_fit_score real not null,      -- mean across scored matches this run
  match_count integer not null,     -- how many matches the average is over
  captured_at timestamptz not null default now()
);

-- The one hot query is "this profile's snapshots, newest first" (latest row +
-- scan back for the ≥24h-older one). This composite serves both.
create index if not exists score_snapshots_profile_captured_idx
  on score_snapshots(profile_id, captured_at desc);

-- Owner-read RLS as defense-in-depth. The server reads/writes with the
-- service-role key (bypasses RLS); FastAPI's per-profile scoping is the real
-- boundary (see services/auth.py). The policy denies the anon key any row it
-- doesn't own, matching every other per-user table.
alter table score_snapshots enable row level security;
create policy "score_snapshots: owner read" on score_snapshots
  for select using (profile_id in (select id from profiles where user_id = auth.uid()));
