-- ============================================
-- Job-Hunt Agent — Migration 008: notification prefs (Phase 4, Settings)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- Gates two calls that already exist in jobs/daily_pipeline.py::_process_profile
-- (send_push_notification, _draft_pending_followups) — not new pipeline
-- behavior, just an on/off switch on behavior that already runs unconditionally.
alter table profiles
  add column if not exists notification_prefs jsonb not null default '{"alerts": true, "followup_nudge": true}';
