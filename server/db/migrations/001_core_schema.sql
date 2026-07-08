-- ============================================
-- Job-Hunt Agent — Migration 001: core schema
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- Prereq: Database → Extensions → enable "vector"
-- ============================================

create extension if not exists vector;

-- ---------- profiles (one per user; single-user until Brick 9) ----------
create table if not exists profiles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid,                          -- null until auth in Brick 9
  name text,
  headline text,
  skills jsonb default '[]',             -- ["flutter","python",...]
  experience jsonb default '[]',         -- [{role, company, duration, bullets[]}]
  projects jsonb default '[]',
  education jsonb default '[]',
  raw_resume_text text,                  -- full text for guardrail source-matching
  embedding vector(768),                 -- text-embedding-004 output
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- ---------- jobs (deduplicated pool from all sources) ----------
create table if not exists jobs (
  id uuid primary key default gen_random_uuid(),
  source text not null,                  -- 'adzuna' | 'jsearch' | 'manual'
  external_id text,
  title text not null,
  company text,
  location text,
  description text,
  salary_min numeric,
  salary_max numeric,
  redirect_url text,                     -- always link to original posting
  dedup_key text unique,                 -- normalized title|company|location
  embedding vector(768),
  posted_at timestamptz,
  ingested_at timestamptz default now()
);
create index if not exists jobs_embedding_idx
  on jobs using ivfflat (embedding vector_cosine_ops) with (lists = 100);

-- ---------- matches (output of the two-stage RAG pipeline) ----------
create table if not exists matches (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references profiles(id) on delete cascade,
  job_id uuid references jobs(id) on delete cascade,
  similarity real,                       -- stage 1: cosine similarity
  fit_score int,                         -- stage 2: LLM 0-100
  strengths jsonb default '[]',
  gaps jsonb default '[]',
  compensators jsonb default '[]',
  verdict text check (verdict in ('apply','stretch','skip')),
  one_line_reason text,
  ranked_at timestamptz default now(),
  unique (profile_id, job_id)            -- re-rank each job once (cache)
);

-- ---------- applications (Kanban pipeline; Brick 7) ----------
create table if not exists applications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references profiles(id) on delete cascade,
  job_id uuid references jobs(id) on delete cascade,
  state text not null default 'saved'
    check (state in ('saved','applied','replied','interview','offer','rejected')),
  resume_version_id uuid,                -- which tailored resume was used
  notes text,
  state_changed_at timestamptz default now(),
  created_at timestamptz default now()
);

-- ---------- tailored_resumes (Brick 6; guardrail results included) ----------
create table if not exists tailored_resumes (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references profiles(id) on delete cascade,
  job_id uuid references jobs(id) on delete cascade,
  bullets jsonb not null,                -- [{original, tailored, keyword, guardrail_pass}]
  guardrail_flags int default 0,         -- count of untraceable bullets
  approved boolean default false,
  created_at timestamptz default now()
);

-- ---------- llm_calls (Golden Rule 5: log everything) ----------
create table if not exists llm_calls (
  id bigint generated always as identity primary key,
  task text not null,                    -- 'parse' | 'rerank' | 'tailor' | 'followup'
  model text,
  prompt_hash text,
  tokens_in int,
  tokens_out int,
  latency_ms int,
  validation_passed boolean,
  retried boolean default false,
  created_at timestamptz default now()
);

-- ---------- helper: stage-1 vector shortlist ----------
-- usage: select * from match_jobs_by_similarity('<profile_id>', 50);
create or replace function match_jobs_by_similarity(p_profile_id uuid, p_limit int default 50)
returns table (job_id uuid, similarity real)
language sql stable as $$
  select j.id, 1 - (j.embedding <=> p.embedding) as similarity
  from jobs j, profiles p
  where p.id = p_profile_id and j.embedding is not null
  order by j.embedding <=> p.embedding
  limit p_limit;
$$;
