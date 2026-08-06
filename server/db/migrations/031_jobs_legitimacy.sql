-- ============================================
-- Job-Hunt Agent — Migration 031: jobs.legitimacy_tier + legitimacy_signals
-- (Career-Ops integration, Brick 1 — posting-legitimacy signal, ADR-055)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- Deterministic, Python-computed signal (services/job_legitimacy.py) for
-- whether a posting looks like a real, active opening — inspired by
-- career-ops's Block G, adapted to be Golden-Rule-2-clean: every signal is
-- computed from data already on this row (posted_at, description, salary,
-- redirect_url), no LLM call in this tier.
--
-- Closed vocabulary, same posture as work_type (019) and category (027):
-- the client renders these as fixed badge states (StatusPill's
-- PillContext.legitimacy), so a stray fourth value would have nowhere to
-- render.
alter table jobs
  add column if not exists legitimacy_tier text
  check (legitimacy_tier in ('high_confidence', 'proceed_with_caution', 'suspicious'));

-- The individual signals that produced the tier (word count, salary
-- presence, freshness, spam-pattern match, contractor-language note) —
-- diagnostics for the badge's detail view and for retuning the heuristic
-- later, same spirit as guardrail_atom_log (025).
alter table jobs add column if not exists legitimacy_signals jsonb;

-- NULL means "not scored yet" (a row from before this migration, or one
-- inserted by a path this brick hasn't reached) — the client renders no
-- badge for NULL rather than guessing a tier for it.
create index if not exists jobs_legitimacy_tier_idx
  on jobs (legitimacy_tier) where legitimacy_tier is not null;

-- No SQL backfill: services/job_legitimacy.py needs its own Python function
-- to run (word counts and regex signals aren't reasonably expressed in a
-- migration), so existing rows are backfilled via
-- job_ingestion.backfill_job_legitimacy(), safe to call repeatedly like
-- every other backfill in this codebase (backfill_job_embeddings,
-- backfill_tech_categories).
