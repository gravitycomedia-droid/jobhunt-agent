-- ============================================
-- Job-Hunt Agent — Migration 034: interview_stories
-- (Career-Ops integration, Brick 4 — interview-prep v1 + story bank, ADR-058)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- The "story bank" career-ops accumulates across evaluations. Distinct from
-- an interview PACK (routers/interview_prep.py's POST /interview-prep/{id}):
-- a pack is generated fresh per job and never stored — disposable, the LLM
-- call is cheap enough to just re-run — while a story is something the user
-- explicitly chose to keep because it's a real, reusable answer. It persists
-- and grows across every job the user preps for, independent of any one
-- application.
create table if not exists interview_stories (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  situation text not null,
  task text not null,
  action text not null,
  result text not null,
  -- Deliberately never LLM-generated: nothing in this app can know how a
  -- real interview actually went. Null until the user adds their own
  -- postmortem note (what worked, what they'd change next time).
  reflection text,
  -- Which job prompted this story, if any — nullable because a user can
  -- also add a story manually, unprompted by any generated pack. ON DELETE
  -- SET NULL (not CASCADE): losing the source job shouldn't delete a story
  -- the user is still reusing for other interviews.
  source_job_id uuid references jobs(id) on delete set null,
  created_at timestamptz not null default now()
);

-- Hot query: "my stories, newest first" (the story bank list).
create index if not exists interview_stories_profile_created_idx
  on interview_stories(profile_id, created_at desc);

alter table interview_stories enable row level security;
create policy "interview_stories: owner read/write" on interview_stories
  for all using (profile_id in (select id from profiles where user_id = auth.uid()));
