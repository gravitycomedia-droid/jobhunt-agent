-- ============================================
-- Job-Hunt Agent — Migration 012: form_fills history (Phase 6)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- One row per POST /forms/fill: the parsed form, the mapped answers (after
-- the deterministic choice-membership guardrail), and the prefill URL the
-- user opened. History only — nothing here is ever submitted server-side
-- (the human taps Google's own Submit button in their browser).
create table if not exists form_fills (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  form_url text not null,
  form_title text,
  answers jsonb not null,
  prefill_url text,
  created_at timestamptz not null default now()
);

create index if not exists form_fills_profile_id_idx on form_fills(profile_id);

-- Same defense-in-depth posture as 004/006/009: the server scopes by
-- profile_id itself; this only matters for direct anon-key access.
alter table form_fills enable row level security;
drop policy if exists "form_fills: owner read" on form_fills;
create policy "form_fills: owner read" on form_fills
  for select using (profile_id in (select id from profiles where user_id = auth.uid()));
