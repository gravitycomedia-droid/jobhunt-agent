-- ============================================
-- Job-Hunt Agent — Migration 003: FCM device token (Brick 8)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

alter table profiles
  add column if not exists fcm_token text;
