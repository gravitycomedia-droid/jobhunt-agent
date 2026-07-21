-- ============================================
-- Job-Hunt Agent — Migration 018: per-source ingestion health log (plan 15, Phase F)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- One row per source per pipeline run, recording how many raw items that source
-- returned that day (BEFORE dedup/freshness/relevance — this measures the
-- SOURCE's health, not the pool's yield). The daily cron writes these rows and
-- then reads the trailing window back to decide whether a source has quietly
-- gone dark. See services/ingestion_health.py.
--
-- Why item_count is the RAW fetched count, not the inserted count: a source can
-- be perfectly healthy and still insert zero new rows on a day when everything
-- it returned was a duplicate of yesterday's pool. Alerting on inserted==0 would
-- cry wolf constantly; alerting on fetched==0 catches the actual failure mode
-- (actor deprecated, endpoint moved, credentials rotated, source blocked us).
create table if not exists source_ingestion_log (
  id bigint generated always as identity primary key,
  source text not null,
  run_date date not null,
  item_count integer not null default 0,
  -- 'ok'    = the fetch ran and we recorded item_count (may legitimately be 0)
  -- 'error' = the fetch RAISED; item_count is 0 and error_message says why.
  -- Anomaly classification ('zero'/'low') is DERIVED at alert time from
  -- item_count + the trailing average — deliberately not frozen into a column,
  -- because "low" only means anything relative to history that changes daily.
  status text not null default 'ok',
  error_message text,
  created_at timestamptz not null default now()
);

-- The health check's one hot query is "rows for this source over the trailing N
-- days", and the daily insert/read both key on run_date — this composite serves
-- both without a second index.
create index if not exists source_ingestion_log_lookup_idx
  on source_ingestion_log(source, run_date);

-- Internal ops telemetry with no per-user read path, so RLS is enabled with NO
-- policy: that denies the anon key outright. The server reads/writes with the
-- service-role key (which bypasses RLS), exactly like rate_limit_events (017).
alter table source_ingestion_log enable row level security;
