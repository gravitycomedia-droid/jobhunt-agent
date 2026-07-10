# MANUAL_STEPS.md — things you must do yourself

Steps that cannot be done from code in this repo. Work top to bottom; each
is idempotent. (Appended to as phases land — final consolidation in Phase 7.)

## 1. Supabase — apply SQL migrations

Dashboard → SQL Editor → paste and run, in order (each is `if not exists`-safe):

- [ ] `server/db/migrations/009_background_tasks.sql` — required by Phase 1A
      (async rerank / "Run agent now"). Until applied, POST /matches/rerank
      and POST /pipeline/run-mine will 500.
- [ ] `server/db/migrations/010_salary_currency.sql` — Phase 1D. Adds
      `jobs.salary_currency`, backfills INR on existing salaried rows, and
      deletes stale (> 60 days) postings that no application references.

## 2. Supabase — fix Google OAuth redirect (Phase 1B)

The "lands on localhost:5173" bug is dashboard config, not code:

Dashboard → Authentication → URL Configuration:

- [ ] **Additional Redirect URLs** → add exactly:
      `com.jobhuntagent.jobhunt_agent://login-callback/`
      (trailing slash included — Supabase matches these literally).
- [ ] **Site URL** → change from `http://localhost:5173` to
      `https://jobhunt-agent-server.onrender.com` (or the deep link above).
      Site URL is the *fallback* when a redirect isn't allow-listed; it must
      never point at a dev server.

No Google Cloud Console change needed — the Google side redirects to
Supabase's own `/auth/v1/callback`, which is already configured.

## 3. Render

- [ ] Nothing yet for Phase 1. (Redeploy happens automatically on push if
      auto-deploy is on; otherwise trigger a manual deploy so the 202 task
      endpoints go live before you test the app against them.)
