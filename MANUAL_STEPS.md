# MANUAL_STEPS.md — things you must do yourself

Steps that cannot be done from code in this repo. Work top to bottom; each
is idempotent.

## 1. Supabase — apply SQL migrations (SQL Editor, in order)

Dashboard → SQL Editor → paste and run each file:

- [ ] `server/db/migrations/009_background_tasks.sql` — Phase 1A/2. Until
      applied, POST /matches/rerank, /pipeline/run-mine and /tailor/{job_id}
      (all now async) will 500.
- [ ] `server/db/migrations/010_salary_currency.sql` — Phase 1D. Adds
      `jobs.salary_currency`, backfills INR, deletes stale (> 60 days)
      postings that no application references.
- [ ] `server/db/migrations/011_onboarding_step.sql` — Phase 3B. Adds
      `profiles.onboarding_step`, backfills existing users to 'done'.
- [ ] `server/db/migrations/012_form_fills.sql` — Phase 6. Fill history
      table; POST /forms/fill 500s without it.

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

No Google Cloud Console change needed — Google redirects to Supabase's own
`/auth/v1/callback`, which is already configured.

## 3. Render

- [ ] Push `main` to GitHub (`git push`) and confirm the
      `jobhunt-agent-server` service redeploys (auto-deploy) or trigger a
      manual deploy. The new code needs `reportlab` (now in
      requirements.txt) — the Docker build installs it automatically.
- [ ] No new env vars are required. Optional: `MAX_JOB_AGE_DAYS` (defaults
      to 60 in code).

## 4. Local verification server (already running this session)

- `uvicorn` is serving the updated backend at `http://localhost:8000`
  (LAN: `http://192.168.31.79:8000`). To point the app at it:
  `flutter run --dart-define=API_BASE_URL=http://192.168.31.79:8000`
- Note: a physical Android device blocks cleartext HTTP by default — for
  device testing against the LAN server either use the Render URL or add
  `android:usesCleartextTraffic="true"` temporarily to AndroidManifest.
  An Android emulator can also use `http://10.0.2.2:8000`.
- Reminder: the new endpoints 500 until the migrations in §1 are applied —
  they run against the same Supabase project as production.
