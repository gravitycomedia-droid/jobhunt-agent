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
- [ ] `server/db/migrations/013_fix_job_embedding_relevance.sql` — drops
      the `jobs_embedding_idx` ANN index (see the migration's own comment):
      it was trained on an empty table back in migration 001 and never
      retrained, so stage-1 similarity search was matching against near-
      random centroids — the root cause of "jobs shown don't match the
      resume at all." Falls back to an exact nearest-neighbor scan, fine at
      current beta job-pool sizes.
- [ ] `server/db/migrations/014_student_info.sql` — adds
      `profiles.employment_type`/`usn` and inserts the new `student_info`
      onboarding step into the `onboarding_step` CHECK constraint. Until
      applied, PATCH /resume/profile/student-info 500s and PATCH
      /resume/profile/onboarding-step rejects `'student_info'`.
- [ ] `server/db/migrations/016_llm_calls_provider.sql` — Phase 14 / ADR-023.
      Adds `llm_calls.provider` (default `'gemini'`, backfills existing rows).
      **Additive with a default, so it's safe to apply BEFORE the new code
      deploys** — old code simply doesn't write the column. Until applied, the
      new code's every LLM call 500s on insert (it now writes `provider`), so
      apply this one first if you're sequencing.
- [ ] `server/db/migrations/017_rate_limits.sql` — Phase 14 / ADR-027. Creates
      `rate_limit_events`. Until applied, the six rate-limited endpoints
      (`/matches/rerank`, `/tailor/{id}`, `/pipeline/run-mine`, `/resume/parse`,
      `/jobs/manual/parse`, `/jobs/from-jd/parse`, `/jobs/refresh`) 500 on their
      first request.

## 1a. Cloud Run / Render — new secret (Phase 14 / ADR-023)

- [ ] Add `DEEPSEEK_API_KEY` to the deploy's secrets (Secret Manager on Cloud
      Run, env var on Render), exactly like `GEMINI_API_KEY`. **Never** ship it
      to the Flutter app. Without it the server still boots and works — every
      DeepSeek-routed task (rerank, extract, followup, skill-growth, forms)
      transparently falls back to Gemini — but you get none of the cost saving,
      and `GET /stats/costs` will show a 100%-Gemini split, which is how you'll
      notice the key is missing.
- [ ] Optional: `TAILOR_PROVIDER` (defaults to `gemini`). Leave it until the
      guardrail-pass A/B in ADR-023 is done.
- [ ] `openai` is a new pip dependency (now in requirements.txt) — the Docker
      build installs it automatically.

## 2. Supabase — fix Google OAuth redirect

Still broken as of 2026-07-11, now landing on the *old Render page*
instead of localhost — this section's previous fix (below) is what caused
that: it pointed the fallback Site URL at Render, and Render is still live
(ADR-014) even after the Cloud Run migration, so the stale fallback still
resolves. Fixing this properly this time means the fallback can never again
point at a web backend that might itself get migrated/decommissioned:

Dashboard → Authentication → URL Configuration:

- [ ] **Additional Redirect URLs** → confirm this exact entry is present
      (trailing slash included — Supabase matches these literally):
      `com.jobhuntagent.jobhunt_agent://login-callback/`
- [ ] **Site URL** → change to the same deep link:
      `com.jobhuntagent.jobhunt_agent://login-callback/`
      Do **not** point Site URL at any backend URL (Render, Cloud Run, or
      future replacements) — it's the fallback used whenever the redirect
      isn't allow-listed, so it should always resolve back into the app,
      never onto a web page. This is what actually fixes the "lands on a
      server page after Google login" bug for good, independent of which
      backend host is live at any given time.

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
