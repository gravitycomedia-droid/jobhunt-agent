-- ============================================
-- Job-Hunt Agent — Migration 035: offer_reviews
-- (Career-Ops integration, Brick 5 — offer-prep contract reader, ADR-059)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- A clause-by-clause plain-English read of one offer letter/contract,
-- paired with the Kanban's existing 'offer' state (migration 001). Hard
-- guards copied directly from career-ops's own offer-prep mode because
-- they're correct: this feature NEVER outputs a verdict ("safe to sign" /
-- a risk score) and NEVER states law from memory — jurisdiction-dependent
-- points are routed to questions_for_lawyer instead of answered inline
-- (services/llm.py::OFFER_REVIEW_SYSTEM_PROMPT). The schema below has no
-- verdict/score column to write one into even if a future prompt change
-- tried — the guard is structural, not just a prompt request.
create table if not exists offer_reviews (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  application_id uuid not null references applications(id) on delete cascade,
  raw_text text not null,
  -- [{clause_text, category, plain_english, grounded}] — `grounded` is a
  -- deterministic Python post-check (services/offer_review.py::
  -- verify_clause_grounding), NOT the LLM's own claim: true only when
  -- clause_text is actually found (normalized) inside raw_text, so a
  -- clause the model paraphrased or invented is flagged rather than
  -- silently trusted (Golden Rule 4's spirit, applied to a reading task
  -- instead of a generation task).
  clauses jsonb not null default '[]'::jsonb,
  questions_for_lawyer jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);

-- Hot query: "this application's offer reads, newest first" — a user may
-- paste a revised offer after negotiating, so this is insert-only like
-- application_emails, not an overwrite-in-place single row.
create index if not exists offer_reviews_application_created_idx
  on offer_reviews(application_id, created_at desc);

alter table offer_reviews enable row level security;
create policy "offer_reviews: owner read/write" on offer_reviews
  for all using (profile_id in (select id from profiles where user_id = auth.uid()));
