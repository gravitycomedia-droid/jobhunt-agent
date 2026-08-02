-- ============================================
-- Job-Hunt Agent — Migration 030: location/salary preference boost (ADR-054)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- services/matching.py previously stored ONLY the final, already-boosted
-- fit_score — the raw LLM verdict and role_alignment were discarded after
-- computing it. That made the boost a one-way door: if the candidate edited
-- target_locations/target_roles/min_salary AFTER a job was scored, the only
-- way to reflect the new preference was a full LLM re-rank (cost + latency),
-- even though the boost itself is pure Python arithmetic (Golden Rule 2).
--
-- Splitting the columns lets a preference change trigger a CHEAP, LLM-free
-- rescore of every cached match: raw_fit_score + role_alignment (the LLM's
-- understanding) stay fixed, while the location/salary boost and the
-- displayed fit_score/verdict get recomputed in Python from current profile
-- preferences. `fit_score` keeps its existing meaning (the boosted, displayed
-- number) — nothing downstream needs to change.
--
-- Nullable, no backfill: matches ranked before this migration simply won't
-- benefit from a preference-only rescore until they're re-ranked from
-- scratch (which already happens for any job not yet cached).
alter table matches
  add column if not exists raw_fit_score int,
  add column if not exists role_alignment real;
