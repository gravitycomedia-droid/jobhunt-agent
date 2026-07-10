-- ============================================
-- Job-Hunt Agent — Migration 010: salary currency + stale-job cleanup (Phase 1D)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- Adzuna reports salaries in the search country's currency (INR for
-- country=in); JSearch sends an explicit currency field. The app was
-- rendering every salary with "$" — store the ISO 4217 code so it can
-- format correctly (₹ with Indian digit grouping for INR).
alter table jobs
  add column if not exists salary_currency text;

-- Existing rows were all fetched with adzuna_country=in (see server/.env),
-- so INR is the correct backfill wherever a salary exists. Skip rows with
-- no salary at all — no currency to attribute.
update jobs
  set salary_currency = 'INR'
  where salary_currency is null
    and (salary_min is not null or salary_max is not null)
    and source in ('adzuna', 'jsearch');

-- One-off cleanup for the freshness bug ("2591d ago"): ingestion now skips
-- postings older than 60 days (config.max_job_age_days), but stale rows
-- already in the pool linger and keep surfacing in matches. Delete them,
-- EXCEPT jobs someone is actively tracking an application against —
-- 001_core_schema.sql cascades jobs → applications, and a user's pipeline
-- history must survive the posting going stale.
-- Review the count first if you want:
--   select count(*) from jobs where posted_at < now() - interval '60 days';
delete from jobs
  where posted_at < now() - interval '60 days'
    and id not in (select job_id from applications where job_id is not null);
