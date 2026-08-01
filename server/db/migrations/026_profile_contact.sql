-- ============================================
-- Job-Hunt Agent — Migration 026: résumé contact details
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- The contact block that goes at the top of a compiled résumé PDF
-- (services/resume_pdf.py::_header_flowables). Until now the PDF header only
-- carried the name, so a recruiter opening a tailored résumé had no way to
-- reach the candidate — the single most important thing on the page.
--
-- Sourced two ways, both already in the app: the résumé parser extracts
-- whatever is printed on the uploaded résumé (services/llm.py
-- PARSE_SYSTEM_PROMPT), and the user can add/correct any of them later from
-- Settings → Contact details. All nullable — every existing profile predates
-- these columns and must stay valid without a backfill, and a résumé that
-- genuinely has no GitHub must render without one rather than with a blank
-- label.
alter table profiles
  add column if not exists email text,          -- contact email (NOT the auth email)
  add column if not exists phone text,
  add column if not exists location text,       -- city / address line on the résumé
  add column if not exists linkedin_url text,
  add column if not exists github_url text,
  add column if not exists website_url text;    -- personal site / portfolio
