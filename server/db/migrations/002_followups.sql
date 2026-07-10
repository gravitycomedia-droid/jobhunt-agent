-- ============================================
-- Job-Hunt Agent — Migration 002: follow-up drafts (Brick 8)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

alter table applications
  add column if not exists followup_subject text,
  add column if not exists followup_body text,
  add column if not exists followup_drafted_at timestamptz;
