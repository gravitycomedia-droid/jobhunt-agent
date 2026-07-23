-- ============================================
-- Job-Hunt Agent — Migration 025: guardrail atom log (Track B, R1 / ADR-033)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- R1 replaced the whole-bullet fuzzy guardrail with an atom-level check: each
-- tailored bullet is decomposed into factual atoms (numbers, tech, proper
-- nouns) that must each trace to something real in the profile. When an atom
-- can't be traced it's flagged on the stored bullet (that's the enforcement)
-- AND recorded here (this is diagnostics, not enforcement).
--
-- Why a table: the atom extractor and its tech lexicon are hand-maintained and
-- deliberately non-exhaustive. The words the guardrail keeps tripping on tell
-- us where the extractor is wrong (a real skill missing from the lexicon = a
-- false positive to fix) and seed the R-E golden set. services/guardrail.py
-- writes here best-effort via routers/tailor.py; a write failure never blocks
-- a tailor run.
create table if not exists guardrail_atom_log (
  id bigint generated always as identity primary key,
  profile_id uuid not null references profiles(id) on delete cascade,
  job_id uuid references jobs(id) on delete set null,
  atom text not null,                       -- the untraceable token, verbatim
  kind text not null,                       -- 'number' | 'tech' | 'proper_noun'
  created_at timestamptz not null default now()
);

create index if not exists guardrail_atom_log_kind_idx
  on guardrail_atom_log(kind, created_at desc);
create index if not exists guardrail_atom_log_profile_idx
  on guardrail_atom_log(profile_id, created_at desc);

-- Owner-only read (same posture as every other profile-scoped table). No app
-- surface reads this yet — it's an analysis table — but RLS stays on so a
-- future read is safe by default. Server writes bypass RLS via the service key.
alter table guardrail_atom_log enable row level security;
drop policy if exists "guardrail_atom_log: owner read" on guardrail_atom_log;
create policy "guardrail_atom_log: owner read" on guardrail_atom_log
  for select using (profile_id in (select id from profiles where user_id = auth.uid()));
