-- ============================================
-- Job-Hunt Agent — Migration 007: real follow-up sending (Phase 4)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- contact_email is the recruiter/hiring-manager address "Approve & send"
-- delivers to. followup_sent_at is null until a send actually succeeds via
-- Resend (see services/email.py) — drafting alone never sets it.
alter table applications
  add column if not exists contact_email text,
  add column if not exists followup_sent_at timestamptz;
