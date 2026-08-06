-- ============================================
-- Job-Hunt Agent — Migration 033: application_emails
-- (Career-Ops integration, Brick 3 — application email drafts, ADR-057)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- Distinct from `applications.followup_subject/body` (migration 002): a
-- follow-up is a single nudge sent 7+ days after applying with no reply,
-- always exactly one live draft per application (the columns get
-- overwritten on redraft). An application email is a FIRST-CONTACT draft —
-- a formal application, a referral request, or a cold outreach — and a
-- candidate reasonably wants more than one on file (redrafted for a
-- different contact, or kept as history), so this is its own table with a
-- new row per draft rather than columns that get overwritten.
create table if not exists application_emails (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references applications(id) on delete cascade,
  -- Denormalised so ownership scoping doesn't need a join back through
  -- applications on every read — same reasoning as chat_messages.profile_id
  -- (migration 024).
  profile_id uuid not null references profiles(id) on delete cascade,
  -- Closed vocabulary (mirrors career-ops's email mode's three variants):
  -- 'application' = formal recruiter/HR inbox email, 'referral' = addressed
  -- to a known contact asking them to forward/refer, 'cold' = a hiring
  -- manager or generic inbox with no prior connection. Changes tone and
  -- content in the prompt, not which facts are available.
  kind text not null check (kind in ('application', 'referral', 'cold')),
  subject text not null,
  body text not null,
  -- Same atom-level guardrail as cover letter paragraphs / résumé bullets
  -- (services/guardrail.py, ADR-033/056), applied once to the whole body
  -- since an application email is one short block, not several paragraphs.
  guardrail_pass boolean not null default true,
  flagged_atoms jsonb not null default '[]'::jsonb,
  -- Same "Approve & send" gate as applications.followup_sent_at — null
  -- until a real Resend send succeeds (routers/application_emails.py).
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

-- Hot query: "this application's drafts, newest first" (the review list).
create index if not exists application_emails_application_created_idx
  on application_emails(application_id, created_at desc);

alter table application_emails enable row level security;
create policy "application_emails: owner read/write" on application_emails
  for all using (profile_id in (select id from profiles where user_id = auth.uid()));
