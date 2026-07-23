-- ============================================
-- Job-Hunt Agent — Migration 023: notifications (frontend rebuild v2, Phase 4)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- The in-app notification feed (§4.13). The daily pipeline already sends an FCM
-- push on each run (Brick 8); this table is the persistent, in-app record of
-- those events so the bell icon has history and an unread count — a push is
-- ephemeral, this survives. GET /notifications reads it; the pipeline writes it.
create table if not exists notifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  -- Coarse category for the icon/grouping ('matches','followup','system',...).
  -- Free-text, no CHECK: new kinds ship from the server without a migration.
  kind text not null,
  title text not null,
  body text not null,
  -- Optional deep-link target: what tapping the notification opens. action_type
  -- names the destination ('match','application','chat',...) and action_ref is
  -- the row it points at. Both nullable — a purely informational notice needs
  -- neither. uuid (not FK): the referenced row may be in any table and may be
  -- deleted out from under the notice, which should not cascade-delete history.
  action_type text,
  action_ref uuid,
  read_at timestamptz,   -- NULL = unread; set on mark-read
  created_at timestamptz not null default now()
);

-- Hot query: "this profile's notifications, newest first" + the unread count.
create index if not exists notifications_profile_created_idx
  on notifications(profile_id, created_at desc);

alter table notifications enable row level security;
create policy "notifications: owner read" on notifications
  for select using (profile_id in (select id from profiles where user_id = auth.uid()));
