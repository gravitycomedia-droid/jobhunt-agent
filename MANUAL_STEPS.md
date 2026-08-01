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
- [x] `server/db/migrations/016_llm_calls_provider.sql` — Phase 14 / ADR-023.
      Adds `llm_calls.provider` (default `'gemini'`, backfills existing rows).
      **Additive with a default, so it's safe to apply BEFORE the new code
      deploys** — old code simply doesn't write the column. Until applied, the
      new code's every LLM call 500s on insert (it now writes `provider`), so
      apply this one first if you're sequencing.
- [x] `server/db/migrations/017_rate_limits.sql` — Phase 14 / ADR-027. Creates
      `rate_limit_events`. Until applied, the six rate-limited endpoints
      (`/matches/rerank`, `/tailor/{id}`, `/pipeline/run-mine`, `/resume/parse`,
      `/jobs/manual/parse`, `/jobs/from-jd/parse`, `/jobs/refresh`) 500 on their
      first request.
- [x] **⚠️ `server/db/migrations/026_profile_contact.sql` — ADR-046. MUST BE
      APPLIED *BEFORE* THE NEXT CLOUD RUN DEPLOY.** Adds
      `profiles.email/phone/location/linkedin_url/github_url/website_url` (the
      résumé PDF's contact header). Unlike most migrations here, this one is
      **not** safe to apply after the code: `routers/resume.py::_upsert_profile`
      writes whichever of these the parser found on the uploaded résumé, so with
      the new code live and the columns missing, **POST /resume/parse 500s for
      any résumé that prints an email** — i.e. résumé upload, and therefore
      onboarding, is broken for everyone. Applying it first is harmless to the
      currently-deployed code (old code simply never writes the columns).
- [x] **⚠️ `server/db/migrations/027_jobs_category.sql` — ADR-003 v3. MUST BE
      APPLIED *BEFORE* THE NEXT CLOUD RUN DEPLOY.** Adds `jobs.category` (+ a
      CHECK, an index, and a coarse backfill of existing rows). Not safe to
      apply after the code: `_dedup_embed_insert()` now writes `category` on
      every ingested row, so with the new code live and the column missing
      **every job insert 500s** — the daily pipeline lands zero postings and
      `POST /jobs/refresh` fails. Applying it first is harmless to the currently
      deployed code (old code simply never writes the column).
- [x] **⚠️ `server/db/migrations/028_tech_category_and_is_active.sql` — ADR-003
      v4. MUST BE APPLIED *BEFORE* THE NEXT CLOUD RUN DEPLOY.** Same failure mode
      as 027, for the same reason: `_dedup_embed_insert()` now writes
      `tech_category` on every ingested row, so with the new code live and the
      column missing **every job insert 500s**. Adds:
      - `jobs.tech_category` (+ CHECK, index, title-only backfill of existing
        engineering/data rows),
      - `jobs.is_active` (boolean, `not null default true`) — the soft-delete
        flag driving stale-job retirement,
      - a redefinition of `match_jobs_by_similarity()` adding `and j.is_active`.
        **This part is not optional**: without it, retired postings keep being
        shortlisted and re-ranked (spending tokens) and keep showing up as fresh
        matches, even though `GET /jobs` hides them.

      Applying it first is harmless to the currently deployed code — old code
      never writes either column, and `is_active` defaults to true so the
      redefined RPC behaves identically until something retires a row.

## 1a1. Cloud Run — Unstop volume env vars (ADR-003 v3)

These four control the broad pool. All have working defaults in `config.py`, so
the deploy is safe without them — but the defaults are the *new* behaviour, so
set them explicitly if you want anything else.

- [ ] `ENABLE_INDIA_SOURCES=true` — **check this first.** It is absent from
      `server/.env`, which means it defaults to `false` and Unstop is fetching
      NOTHING today. Everything else here is moot until this is on.
- [ ] `UNSTOP_MAX_RESULTS=1000` (was 20) — a runaway guard, not a target; the
      freshness early-stop is the real volume control.
- [ ] `UNSTOP_OPPORTUNITY_TYPES=internships,jobs` — adds the 1,186-posting
      `jobs` catalogue.
- [ ] `UNSTOP_SEARCH_TERMS=` (blank) — blank means crawl the whole catalogue.
- [ ] `INGESTION_GATE_OVERRIDES=unstop:entry` — keeps the entry-level gate,
      drops role+location for Unstop only. See ADR-003 v3 for the measured
      volume of each combination.

**Watch the first run.** It's a cold crawl of ~21 requests taking ~77s, and it
inserts ~790 rows — versus ~3 requests and ~87 rows/day afterwards. The cron
route `POST /pipeline/run` is synchronous, so if Cloud Scheduler's attempt
deadline is tight, that first run is where it would time out. Either raise the
deadline for one day, or trigger the first crawl manually and let the cron pick
up from the cheap steady state.

## 1a2. Cloud Run — Internshala/Instahyre env vars (ADR-003 v4)

All have working defaults in `config.py`, so the deploy is safe without them.
Three **removed** vars are the thing to actually action:

- [ ] **Delete `APIFY_INTERNSHALA_ACTOR_ID`, `APIFY_INTERNSHALA_WEEKDAYS` and
      `INTERNSHALA_MAX_RESULTS`** from the Cloud Run service if they are set.
      Internshala no longer uses Apify at all (ADR-003 v4) and these settings no
      longer exist in `config.py`. Pydantic-settings ignores unknown env vars, so
      leaving them set is harmless — but it will read as "Internshala is still
      costing Apify credits" to a future you, and it isn't.
- [x] `ENABLE_INDIA_SOURCES=true` — **already set on Cloud Run** (verified
      2026-07-27 against the live service, not the checklist). Master kill switch
      for all three India boards (Internshala, Instahyre, Unstop).
- [ ] `INSTAHYRE_MAX_RESULTS=300` — runaway guard, not a target. Note the cap is
      shared across both job types and internships are crawled FIRST for a
      reason (see the comment on `INSTAHYRE_JOB_TYPES`): full-time is ~7,900 rows
      of which ~100% fails the entry-level gate, so if it runs first it eats the
      whole cap and the ~8 internships — the only rows that can pass — are never
      fetched. That shipped once and made Instahyre insert 0 rows while
      reporting 300 fetched.
- [ ] `INTERNSHALA_PAGES_PER_SLUG=1` — 50 cards/page; 1 page × 12 slugs × 2 stems
      is already ~1,200 cards/day before dedup.
- [ ] `ENABLE_TECH_CATEGORY_LLM=true` — set `false` to make ingestion do zero LLM
      calls (unresolved rows become `other_it`). Measured 96% of rows never reach
      the LLM anyway, so leaving it on costs about one small DeepSeek call/day.

**Expected first run:** Internshala ~24 requests (12 slugs × 2 stems), Instahyre
a handful. Both are far cheaper than Unstop's cold crawl, so no attempt-deadline
concern like §1a1 had.

## 1a3. Cloud Scheduler — 7:00 AM IST (VERIFIED, no action needed)

- [x] **Verified live 2026-07-27.** The job is correct as-is:

      ```
      jobhunt-daily-pipeline   0 7 * * *   Asia/Kolkata   ENABLED
      ```

      The timezone was set explicitly at creation, so `0 7 * * *` really is
      7:00 AM IST. The concern previously recorded here — that Cloud Scheduler
      defaults to UTC and would therefore be firing at 12:30 PM IST — did not
      apply. Kept as a note because `DAILY_PIPELINE_HOUR` in `config.py` is
      genuinely NOT what schedules the run (it is only read for display/logic),
      so if the cron time ever looks wrong, this job is the thing to check:

      ```bash
      gcloud scheduler jobs describe jobhunt-daily-pipeline --location=asia-south1 \
        --format="value(schedule,timeZone)"
      ```

## 1a. Cloud Run — new secret (Phase 14 / ADR-023)

- [x] Add `DEEPSEEK_API_KEY` to the deploy's secrets (Secret Manager on Cloud
      Run), exactly like `GEMINI_API_KEY`. **Never** ship it
      to the Flutter app. Without it the server still boots and works — every
      DeepSeek-routed task (rerank, extract, followup, skill-growth, forms)
      transparently falls back to Gemini — but you get none of the cost saving,
      and `GET /stats/costs` will show a 100%-Gemini split, which is how you'll
      notice the key is missing.
- [ ] Optional: `TAILOR_PROVIDER` (defaults to `gemini`). Leave it until the
      guardrail-pass A/B in ADR-023 is done.
- [ ] `openai` is a new pip dependency (now in requirements.txt) — the Docker
      build installs it automatically.

## 1b. Cloud Run — update job-targeting env vars

These live as env vars on the Cloud Run service, so editing `.env.example` (or
your local `server/.env`) changes nothing in production until you push them up.

- [x] `TARGET_ROLES=fullstack developer,frontend developer`
- [x] `TARGET_LOCATIONS=hyderabad,bangalore,remote`

Why they changed: both lists fan out into API calls per refresh — Adzuna is
`roles × ADZUNA_LOCATIONS × 2`, JSearch is `roles × TARGET_LOCATIONS` against a
**200 requests/month** free-tier cap. The old values (5 roles × 4 locations,
where `bengaluru` and `bangalore` were the same city twice) came to ~600
JSearch calls/month, so JSearch was blowing its quota around day 10 and then
silently 429ing for the rest of the month. The new values land at 180/month.

Note the split: `settings.target_roles` only decides which jobs get **fetched**
into the pool. The re-ranker scores against `profiles.target_roles` in the DB
(per-user, set from the app's Profile screen). If a user's profile roles still
say flutter/python/mobile while ingestion only fetches fullstack/frontend, the
match board will be scoring the wrong pool against the wrong target — keep the
two aligned.

## 1c. Apify — scraped sources (ADR-003 amended). LOCAL DONE, DEPLOY PENDING

Phases 1–3 are **built, tested (231 pass), and verified against the live Apify
API**. Locally it works: a real run inserted 9 Naukri jobs into the pool with
embeddings and numeric INR salaries. What's left is deploying it.

Local state (already done — listed so you can reproduce it elsewhere):

- [x] Apify account + API token, in `server/.env` as `APIFY_API_TOKEN`.
      (You'd pasted it as `APIFY_API_KEY`; the code reads `..._TOKEN`.)
- [x] Actors hand-tested live and pinned in `.env`:
      `curious_coder~linkedin-jobs-scraper`, `misceres~indeed-scraper`,
      `makework36~naukri-scraper` — all no-login.
- [x] Per-source cadence + caps set (~$4.33/mo, see `.env.example` for the math).

**Still to do:**

- [x] **Secret created:** `APIFY_API_TOKEN` in Secret Manager (version 1).
- [x] **Cloud Run plain env vars set** (revision `00010`): the three actor IDs,
      three weekday lists, three per-source caps, `APIFY_MAX_CONCURRENT_RUNS`.
      Note the ADR-014 comma gotcha applies — the weekday lists contain commas,
      so they were set with the `^:^` alternate-delimiter syntax.
- [x] **Code deployed** (revision `00011`, `gcloud run deploy --source .`).
      `/health` returns 200.

- [ ] **⚠️ ONLY REMAINING STEP — grant the runtime SA access to the secret, then
      attach it.** A new secret does NOT inherit the other secrets' IAM bindings,
      so until this runs, `APIFY_API_TOKEN` is unreadable and the scraped sources
      no-op (logged, safe degrade — the free sources still ingest daily).

      ```bash
      gcloud secrets add-iam-policy-binding APIFY_API_TOKEN \
        --member="serviceAccount:380742808186-compute@developer.gserviceaccount.com" \
        --role="roles/secretmanager.secretAccessor"

      gcloud run services update jobhunt-agent-server --region=asia-south1 \
        --update-secrets=APIFY_API_TOKEN=APIFY_API_TOKEN:latest
      ```
      (Same SA and role the other seven secrets already use.)

- [ ] **Confirm the Apify spend cap.** Console → Settings → Billing. You're on
      the FREE plan, which hard-caps usage at **$5/month** and returns HTTP 402
      on everything past it. Current cycle: **$0.91 used** (all of it hand-test
      verification), resets **2026-08-12**. The shipped config budgets ~$4.33/mo
      — it fits, but there is little headroom, so don't raise a cadence or a cap
      without redoing the math in `.env.example`.
- [ ] **Watch the first Monday run.** Monday is the only day all three sources
      fire. Look for the `Scraped sources due today: ...` log line — it prints
      the call count and the billable-result ceiling *before* the money is spent.

**Known behaviour, not a bug:** `TARGET_LOCATIONS` includes `remote`, and
LinkedIn's remote search is worldwide — so a remote query legitimately returns
jobs in Dublin, São Paulo, New York. They're real remote roles; the re-ranker
scores them against the profile like anything else. Drop `remote` from
`TARGET_LOCATIONS` if you only want India-based postings.

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

## 3. Cloud Run (deploy)

Since ADR-014 the server runs on Google Cloud Run, **not** Render. A `git push`
deploys nothing on its own — deployment is a manual build-and-deploy the user
must run and approve (see the `gcloud run deploy --source .` command recorded in
§2 above / `MANUAL_STEPS.md:102`).

- [ ] After pushing `main` to GitHub, run the manual Cloud Run deploy so the new
      code goes live. The `server/Dockerfile` build installs `reportlab` and
      `poppler-utils` automatically.
- [ ] Confirm the deploy landed on a **new revision** (`gcloud run services
      describe jobhunt-agent-server --region=asia-south1`) before assuming a
      change is live — a stale revision is the usual cause of "still broken."
- [ ] No new env vars are required. Optional: `MAX_JOB_AGE_DAYS` (defaults
      to 10 in code).

## 4. Local verification server (already running this session)

- `uvicorn` is serving the updated backend at `http://localhost:8000`
  (LAN: `http://192.168.31.79:8000`). To point the app at it:
  `flutter run --dart-define=API_BASE_URL=http://192.168.31.79:8000`
- Note: a physical Android device blocks cleartext HTTP by default — for
  device testing against the LAN server either use the Cloud Run URL or add
  `android:usesCleartextTraffic="true"` temporarily to AndroidManifest.
  An Android emulator can also use `http://10.0.2.2:8000`.
- Reminder: the new endpoints 500 until the migrations in §1 are applied —
  they run against the same Supabase project as production.
