-- ============================================
-- Job-Hunt Agent — Migration 009: background_tasks (async job pattern)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- Long-running endpoints (POST /matches/rerank, POST /pipeline/run-mine)
-- used to hold the client's HTTP connection open for minutes of sequential
-- Gemini calls — Android's network stack / Render free tier drops the
-- socket ("Software caused connection abort"). They now return 202 with a
-- task id immediately and do the work in a FastAPI background task; the
-- client polls GET /tasks/{id} against this table instead.
create table if not exists background_tasks (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  task_type text not null,
  status text not null default 'pending'
    check (status in ('pending', 'running', 'done', 'failed')),
  result jsonb,
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists background_tasks_profile_id_idx
  on background_tasks(profile_id);

-- Same defense-in-depth posture as 004/006: the server connects with the
-- service-role key and enforces ownership itself (GET /tasks/{id} checks
-- profile_id against the caller). This policy only matters if something
-- ever queries Supabase directly with the anon key.
alter table background_tasks enable row level security;
drop policy if exists "background_tasks: owner read" on background_tasks;
create policy "background_tasks: owner read" on background_tasks
  for select using (profile_id in (select id from profiles where user_id = auth.uid()));
