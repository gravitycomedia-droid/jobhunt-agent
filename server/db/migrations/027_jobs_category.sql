-- ============================================
-- Job-Hunt Agent — Migration 027: jobs.category (ADR-003 v3, broad Unstop pool)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- Context: until now the ingestion relevance gate guaranteed every row in `jobs`
-- was a fullstack/frontend/cloud role, so "what kind of job is this?" needed no
-- answer. ADR-003 v3 drops the role gate for Unstop specifically, so the pool now
-- carries sales, marketing, finance, design and operations postings alongside
-- engineering ones. This column is what keeps the app's job list navigable —
-- without it the broad pool is an undifferentiated wall.
--
-- Closed vocabulary with a CHECK, same posture as work_type in migration 019
-- (and unlike `source`, which has none because sources come and go). It's mirrored
-- in services/job_category.py::CATEGORIES and in the app's filter chips; adding a
-- value means changing all three.
--
-- NOT NULL is deliberately NOT set: classify_category() always returns a value
-- for new rows, but pre-existing rows are backfilled below on a best-effort basis
-- and a stray NULL must not break reads.
alter table jobs
  add column if not exists category text
  check (category in (
    'engineering', 'data', 'design', 'product', 'marketing', 'sales',
    'finance', 'operations', 'hr', 'content', 'legal', 'other'
  ));

-- The app filters by category on every job-list read, so this index is not
-- optional at 100-200 new rows/day. Partial on NOT NULL: NULL rows are never
-- filtered *for*, only displayed, so they don't need to be in the index.
create index if not exists jobs_category_idx on jobs (category) where category is not null;

-- Backfill. SQL can't run job_category.py's regexes, so this is a deliberately
-- coarse approximation covering only the highest-volume, least ambiguous buckets;
-- everything it can't place stays NULL rather than being guessed into 'other'
-- (a wrong label is worse than an honest absent one — 'other' is a real bucket
-- users can browse, so mislabelling hides jobs there).
--
-- Ordering mirrors job_category.py's priority: the CASE arms are evaluated top to
-- bottom, so `data` and `design` claim their rows before the broader engineering
-- and sales patterns can.
update jobs
  set category = case
    when title ~* '\m(data (scien|analy|engineer)|machine learning|deep learning|nlp|power ?bi|tableau)' then 'data'
    when title ~* '\m(ui ?/? ?ux|ux|graphic design|product design|figma|interior design)' then 'design'
    when title ~* '\m(full ?stack|front ?end|back ?end|software (engineer|develop)|sde|web develop|react|angular|node|android|flutter|devops|cloud (engineer|architect)|qa)' then 'engineering'
    when title ~* '\m(sales|business develop|account (manage|execut)|telecall)' then 'sales'
    when title ~* '\m(marketing|seo|social media|campus ambassador|brand)' then 'marketing'
    when title ~* '\m(financ|account(ing|ant)|audit|taxation)' then 'finance'
    when title ~* '\m(human resource|hr|recruit|talent acquisition)' then 'hr'
    when title ~* '\m(content (writ|creat)|copywrit|writer|editor)' then 'content'
    when title ~* '\m(engineer|developer|programmer)' then 'engineering'
    else null
  end
  where category is null;
