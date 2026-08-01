-- ============================================
-- Job-Hunt Agent — Migration 028: jobs.tech_category + jobs.is_active
-- (ADR-003 v4 — Internshala/Instahyre technical ingestion)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- ---------------------------------------------------------------------------
-- 1. tech_category — the technical SUB-specialism.
-- ---------------------------------------------------------------------------
-- This does NOT replace `category` (migration 027). The two answer different
-- questions and both are needed:
--
--     category      = which FUNCTION      → engineering | sales | hr | design | …
--     tech_category = which SPECIALISM    → frontend | backend | ai_ml | …
--
-- 027's vocabulary is what keeps the broad Unstop pool navigable (an SDE
-- internship vs. a telecalling one). It cannot express "Frontend vs. Backend",
-- because every one of those collapses to `engineering`. Overloading 027's
-- column to carry specialisms instead would have thrown away the ability to
-- label and browse non-engineering roles at all — so this is a second column,
-- deliberately, rather than a redefinition of the first.
--
-- NULL is meaningful and is the correct value for a NON-TECHNICAL posting.
-- There is no 'non_it' member: a sales role's answer to "which engineering
-- specialism?" is "not applicable", and `category` already says it's sales.
-- That keeps the plan's "non-IT is stored, never dropped" rule — such rows stay
-- in `jobs` with category='sales', tech_category=NULL — without inventing a
-- second, redundant way to spell "not an engineering job".
alter table jobs
  add column if not exists tech_category text
  check (tech_category in (
    'frontend', 'backend', 'full_stack', 'mobile', 'ai_ml', 'data_science',
    'devops_cloud', 'cybersecurity', 'qa_testing', 'blockchain', 'other_it'
  ));

-- Partial on NOT NULL for the same reason 027's index is: NULL rows are never
-- filtered *for*, only displayed.
create index if not exists jobs_tech_category_idx on jobs (tech_category) where tech_category is not null;

-- ---------------------------------------------------------------------------
-- 2. is_active — soft-delete flag driving stale-job retirement.
-- ---------------------------------------------------------------------------
-- Internshala and Instahyre expose no reliable per-listing expiry date, so a
-- posting is retired when it stops appearing in that source's daily fetch
-- (services/job_ingestion.py::retire_stale_jobs).
--
-- SOFT delete, never a DELETE. A `jobs` row is referenced by `applications`,
-- `matches` and `tailored_resumes`; hard-deleting one would either violate the
-- FK or destroy a user's own tracked history because a company took a listing
-- down. Flipping a flag makes the posting vanish from browsing and matching
-- while everything the user already interacted with still resolves.
--
-- DEFAULT true + NOT NULL: every existing row is active, and no read anywhere
-- has to handle a three-valued `is_active`.
alter table jobs
  add column if not exists is_active boolean not null default true;

-- The job list, matching and shortlist queries all filter on this, so it pairs
-- with essentially every read. Partial on the TRUE side: retired rows are only
-- ever excluded, never selected for, so they don't need to be in the index.
create index if not exists jobs_is_active_idx on jobs (is_active) where is_active;

-- ---------------------------------------------------------------------------
-- 3. Teach the stage-1 shortlist about retirement.
-- ---------------------------------------------------------------------------
-- Adding `is_active` to the table is not enough on its own: the two-stage RAG
-- match starts inside THIS function, so without the predicate here a retired
-- posting would keep being shortlisted, re-ranked (costing tokens) and shown as
-- a fresh match. Redefined from 001_core_schema.sql with one extra condition
-- and nothing else changed.
--
-- Note this is a DISCOVERY read, which is exactly the class of query that must
-- exclude retired rows. Reads that hydrate a job the user already interacted
-- with (applications, matches, tailored resumes) deliberately do NOT filter —
-- that asymmetry is the whole reason retirement is a soft flag.
create or replace function match_jobs_by_similarity(p_profile_id uuid, p_limit int default 50)
returns table (job_id uuid, similarity real)
language sql stable as $$
  select j.id, 1 - (j.embedding <=> p.embedding) as similarity
  from jobs j, profiles p
  where p.id = p_profile_id and j.embedding is not null and j.is_active
  order by j.embedding <=> p.embedding
  limit p_limit;
$$;

-- ---------------------------------------------------------------------------
-- 4. Backfill of tech_category.
-- ---------------------------------------------------------------------------
-- Deliberately coarse and title-only — SQL can't run job_tech_category.py's
-- regexes, and the app re-classifies on ingest from here on. Only unambiguous
-- title matches are claimed; anything else stays NULL rather than being guessed
-- into 'other_it', because a wrong specialism label is worse than an absent one.
--
-- Scoped to the engineering/data rows: asking "which engineering specialism?" of
-- a marketing posting is a category error, and the CASE would occasionally find
-- a false match in one ("Growth Engineer").
--
-- Arm order mirrors job_tech_category.py's priority: full_stack before the bare
-- frontend/backend arms, and ai_ml before data_science.
update jobs
  set tech_category = case
    when title ~* '\m(full[ .-]?stack|mern|mean)\M' then 'full_stack'
    when title ~* '\m(machine learning|deep learning|nlp|computer vision|llm|generative ai|ai/ml)\M' then 'ai_ml'
    when title ~* '\m(data (scien|analy)|data engineer|business intelligence|power ?bi|tableau)\M' then 'data_science'
    when title ~* '\m(devops|sre|site reliability|cloud (engineer|architect)|kubernetes|platform engineer)\M' then 'devops_cloud'
    when title ~* '\m(cyber ?security|security (engineer|analyst)|penetration test)\M' then 'cybersecurity'
    when title ~* '\m(qa|quality assurance|test(ing)? engineer|automation engineer|sdet)\M' then 'qa_testing'
    when title ~* '\m(blockchain|web3|solidity|smart contract)\M' then 'blockchain'
    when title ~* '\m(android|ios develop|flutter|react native|mobile app)\M' then 'mobile'
    when title ~* '\m(front ?end|react|angular|vue|ui develop)\M' then 'frontend'
    when title ~* '\m(back ?end|node|django|flask|spring|api develop)\M' then 'backend'
    else null
  end
  where tech_category is null
    and category in ('engineering', 'data');
