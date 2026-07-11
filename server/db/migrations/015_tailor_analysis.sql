-- ADR-019: the resume-tailoring flow now runs the full JD-analysis framework,
-- not just bullet rephrasing. Two new columns on tailored_resumes hold that
-- output. Both are nullable so pre-existing rows (bullet-only tailoring) still
-- read fine — resume_pdf.py falls back to the profile's own summary/skills and
-- a single-column layout when `analysis` is null.

alter table tailored_resumes
  -- { role_type, culture_signal, jd_title, summary_line,
  --   hard_requirements: [str], skills_ordered: [str] }
  add column if not exists analysis jsonb,
  -- [str] — JD hard requirements the candidate can't back up (computed in
  -- Python by services/guardrail.compute_gaps). Disclosed to the user in the
  -- diff screen; NEVER written onto the resume (same posture as a
  -- guardrail-flagged bullet).
  add column if not exists gaps jsonb;
