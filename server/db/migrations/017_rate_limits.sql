-- ============================================
-- Job-Hunt Agent — Migration 017: Postgres-backed rate limiting (Phase 14, ADR-027)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- Why Postgres and not an in-memory counter: Cloud Run can run more than one
-- instance, and an in-process dict would let each instance grant the full
-- quota independently — the limit would silently multiply by the instance
-- count. Supabase is already the single source of truth every instance shares,
-- so a table gives one honest global count with zero new infrastructure.
--
-- One row per allowed request; the limiter COUNTS rows in the trailing window
-- for (subject, endpoint) and inserts one more when it lets a request through.
-- See services/rate_limit.py.
--
-- `subject` is a plain text key, NOT a FK to profiles, on purpose: most
-- endpoints key on the caller's profile id, but POST /resume/parse runs BEFORE
-- a profile row exists (that call is what creates it), so it keys on the
-- Supabase auth user id instead. A FK would make the pre-profile case
-- impossible and would also block the opportunistic prune. These rows are
-- throwaway counters that get pruned continuously — they don't need referential
-- integrity, they need to be cheap.
create table if not exists rate_limit_events (
  id bigint generated always as identity primary key,
  subject text not null,
  endpoint text not null,
  created_at timestamptz not null default now()
);

-- The limiter's hot query is "count rows for (subject, endpoint) since now() -
-- window", and its prune is "delete rows older than the window" — this
-- composite index serves both.
create index if not exists rate_limit_events_lookup_idx
  on rate_limit_events(subject, endpoint, created_at);

-- These are internal counter rows with no per-user read use case, so RLS is
-- enabled with NO policy: that denies the anon key entirely. The server
-- connects with the service-role key (which bypasses RLS) and does all the
-- counting itself, same as every other table's real enforcement path.
alter table rate_limit_events enable row level security;
