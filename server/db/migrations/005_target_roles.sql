-- ============================================
-- Job-Hunt Agent — Migration 005: per-user target roles (frontend rebuild, Phase 1)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

alter table profiles
  add column if not exists target_roles jsonb default '[]',
  add column if not exists min_salary numeric;
