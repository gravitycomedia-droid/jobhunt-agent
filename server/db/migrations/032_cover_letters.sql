-- ============================================
-- Job-Hunt Agent — Migration 032: cover_letters
-- (Career-Ops integration, Brick 2 — cover letter generation, ADR-056)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- Mirrors tailored_resumes (001_core_schema.sql) deliberately closely: same
-- profile_id/job_id ownership shape, same unapproved-until-reviewed posture,
-- same guardrail_flags count. A SEPARATE table rather than a column on
-- tailored_resumes because a cover letter and a tailored résumé have
-- independent lifecycles — a user may regenerate one without touching the
-- other, and either may exist without the other ever having been generated.
create table if not exists cover_letters (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references profiles(id) on delete cascade,
  job_id uuid references jobs(id) on delete cascade,
  -- [{role: 'opening'|'body'|'closing', text, guardrail_pass, flagged_atoms}],
  -- same per-item guardrail shape as tailored_resumes.bullets so the diff-style
  -- review screen can reuse the same red-flag pattern the résumé diff uses.
  paragraphs jsonb not null,
  guardrail_flags int not null default 0,
  approved boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists cover_letters_profile_job_idx
  on cover_letters(profile_id, job_id, created_at desc);

-- Same defense-in-depth posture as tailored_resumes/applications: the server
-- connects with the service-role key and scopes by profile_id itself
-- (routers/cover_letters.py). This policy only matters for direct anon-key
-- access.
alter table cover_letters enable row level security;
create policy "cover_letters: owner read/write" on cover_letters
  for all using (profile_id in (select id from profiles where user_id = auth.uid()));
