-- ============================================
-- Job-Hunt Agent — Migration 024: chat threads + messages (frontend rebuild v2, Phase 4)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- The grounded career-assistant chat (§ chat, services/chat.py). A thread is
-- one conversation; messages are its turns. Kept as two tables (not a jsonb
-- blob on the thread) so an individual assistant turn can be logged, retried,
-- and paged independently, and so GET /chat/threads can list without loading
-- every message.
create table if not exists chat_threads (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  -- Short human label for the list ("Resume questions"), derived from the first
  -- user message. Nullable until the first turn names it.
  title text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()  -- bumped on each new message; list orders by this
);

create table if not exists chat_messages (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references chat_threads(id) on delete cascade,
  -- Denormalised so message-level RLS and per-profile scoping don't need a join
  -- back through the thread on every read.
  profile_id uuid not null references profiles(id) on delete cascade,
  -- Only the two roles this app persists. No 'system': the grounding prompt is
  -- built server-side per call (services/chat.py), never stored as a turn.
  role text not null check (role in ('user', 'assistant')),
  content text not null,
  created_at timestamptz not null default now()
);

-- Threads listed newest-active first; messages read oldest-first within a thread.
create index if not exists chat_threads_profile_updated_idx
  on chat_threads(profile_id, updated_at desc);
create index if not exists chat_messages_thread_created_idx
  on chat_messages(thread_id, created_at);

alter table chat_threads enable row level security;
create policy "chat_threads: owner read" on chat_threads
  for select using (profile_id in (select id from profiles where user_id = auth.uid()));

alter table chat_messages enable row level security;
create policy "chat_messages: owner read" on chat_messages
  for select using (profile_id in (select id from profiles where user_id = auth.uid()));
