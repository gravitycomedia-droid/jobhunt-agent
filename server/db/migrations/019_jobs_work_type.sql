-- ============================================
-- Job-Hunt Agent — Migration 019: jobs.work_type (frontend rebuild v2, Phase 4)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- The remote/hybrid/onsite classification the filter sheet (§4.4) and
-- GET /jobs/facets need. `jobs.source` deliberately has no CHECK (sources come
-- and go); work_type DOES, because it's a closed 3-value vocabulary the client
-- renders as fixed filter chips. NULL = unknown/unclassified — an honest
-- "we couldn't tell", never a silent default to 'onsite'.
alter table jobs
  add column if not exists work_type text
  check (work_type in ('remote', 'hybrid', 'onsite'));

-- Backfill: services/job_filter.py::is_remote already computes remoteness at
-- ingestion time (for the location gate) and then throws the answer away — this
-- persists it. SQL can't run that Python, so this is the lenient location-text
-- approximation of _REMOTE_LOCATION; new rows get the precise classification
-- from job_ingestion.py going forward. Hybrid/onsite stay NULL here: the
-- existing pool carries no reliable signal to separate them, and guessing
-- 'onsite' would be the exact silent-default this column exists to avoid.
update jobs
  set work_type = 'remote'
  where work_type is null
    and (
      location ~* '\m(remote|work[ -]?from[ -]?home|wfh|anywhere)\M'
      or title ~* '\mremote\M'
    );
