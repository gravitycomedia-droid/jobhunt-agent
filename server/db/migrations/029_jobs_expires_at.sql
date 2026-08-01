-- ============================================
-- Job-Hunt Agent — Migration 029: jobs.expires_at (daily expiry sweep)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- Context: `is_fresh()` runs only at INGESTION. Nothing ages a row out
-- afterwards, so the pool accumulated stale postings indefinitely — measured
-- 2026-08-01, 362 of 1,539 active rows (23%) were already older than the
-- 10-day freshness rule they were admitted under, and 48 had no posted_at at
-- all and could never age out by any rule.
--
-- This column stores the source's OWN stated deadline where it publishes one,
-- so expiry becomes a fact we were told rather than a guess from age.
--
-- Unstop is the motivating case and 79% of the pool: every opportunity carries
-- an `end_date` (registration deadline), and its search API only ever returns
-- status=LIVE / regn_open=1 — sampled 100/100 on 2026-08-01. Median
-- registration window is 13 days and the max observed is 56, which is exactly
-- why age is a BAD proxy here: a 12-day-old Unstop posting is routinely still
-- open, and a 40-day-old one occasionally is too.
--
-- NULL means "this source publishes no deadline" (Adzuna, JSearch, LinkedIn,
-- Indeed, Naukri, Greenhouse, Lever) — those fall back to an age rule in
-- services/job_ingestion.py::retire_expired_jobs. NULL is not "never expires".
alter table jobs add column if not exists expires_at timestamptz;

-- The daily sweep's one hot query is "active rows whose deadline has passed".
-- Partial on the rows that HAVE a deadline: NULL rows are handled by the age
-- branch and would only bloat the index.
create index if not exists jobs_expires_at_idx
  on jobs (expires_at) where expires_at is not null;

-- No backfill. Existing rows keep expires_at NULL and are judged by the age
-- fallback until the next crawl re-upserts them with a real deadline. Guessing
-- a deadline for a posting whose source never told us one would be inventing
-- data, and the age rule already handles that case honestly.
--
-- Note the sweep only ever sets is_active = false; it never deletes. Migration
-- 028 explains why at length — `jobs` rows are referenced by `applications`,
-- `matches` and `tailored_resumes`, and a user's tracked history must survive a
-- company taking its listing down.
