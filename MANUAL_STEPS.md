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
- [x] **⚠️ `server/db/migrations/030_match_preference_boost.sql` — ADR-054.
      MUST BE APPLIED *BEFORE* THE NEXT CLOUD RUN DEPLOY.** Adds
      `matches.raw_fit_score` and `matches.role_alignment` (both nullable, no
      backfill). Not safe to apply after the code: `services/matching.py::
      rerank_shortlist` now writes both columns on every insert, so with the
      new code live and the columns missing **every match insert 500s** — the
      Matches board stops updating for everyone. Applying it first is harmless
      to the currently deployed code (old code never writes either column).
      Existing cached matches simply won't benefit from a preference-only
      rescore (`rescore_cached_matches`) until they're re-ranked from scratch,
      which already happens for any job not yet cached.
      **Applied 2026-08-02** (confirmed live: re-rank error against the local
      dev server cleared after running it). Was briefly numbered 029 and
      collided with a concurrent session's `029_jobs_expires_at.sql` — renamed
      to 030 before this commit; the SQL content itself (and what you already
      ran in the Supabase SQL Editor) is unchanged, only the filename moved.

- [ ] `server/db/migrations/029_jobs_expires_at.sql` — daily expiry sweep. Adds
      `jobs.expires_at` (nullable) + a partial index. **Safe to apply in either
      order** relative to the deploy, unlike 027/028: the column is nullable with
      no default and old code simply never writes it, while new code treats a
      missing deadline as "fall back to the age rule". Nothing 500s either way.

      Until applied, `retire_expired_jobs()` still runs but every row takes the
      age branch — so Unstop postings are judged on age rather than on the real
      `end_date`, which is exactly the imprecision this column removes.

- [ ] **Career-ops integration, Bricks 1-6 (2026-08-03) — NONE of these are
      applied yet, and NONE of this code is pushed/deployed yet either
      (confirmed: working tree has 20+ modified files and 30+ untracked new
      files, `git push --dry-run` has no remote credentials in this
      session). Run ALL FIVE below before redeploying (§3) — every one is
      pure `create table if not exists` / new nullable columns, so, like
      029 above, they're safe to apply in EITHER order relative to the
      deploy — old code just never writes the new columns/tables.**
  - [ ] `server/db/migrations/031_jobs_legitimacy.sql` — ADR-055. Adds
        `jobs.legitimacy_tier`/`legitimacy_signals`. Applying this alone does
        **not** retroactively badge your existing job pool — `score_posting()`
        only runs at ingestion time. After applying + redeploying, either wait
        for the next daily cron (new jobs only) or call
        `POST /jobs/backfill-legitimacy` once to score the existing pool (see
        the new bullet under §3 below).
  - [ ] `server/db/migrations/032_cover_letters.sql` — ADR-056. Creates
        `cover_letters`. Until applied AND redeployed, every
        `POST /cover-letters/{job_id}` 404s (the route itself doesn't exist on
        whatever's currently live) or 500s (table missing) — "could not draft
        cover letter" is this.
  - [ ] `server/db/migrations/033_application_emails.sql` — ADR-057. Creates
        `application_emails`. Same failure mode as 032 for
        `/application-emails/*` — this is also why `AppDetailScreen` now shows
        an error loading the "APPLICATION EMAILS" section on old/undeployed
        code.
  - [ ] `server/db/migrations/034_interview_stories.sql` — ADR-058. Creates
        `interview_stories`. Same failure mode for `/interview-prep/*` and
        `/interview-stories` — "could not load your stories" is this.
  - [ ] `server/db/migrations/035_offer_reviews.sql` — ADR-059. Creates
        `offer_reviews`. Same failure mode for `/offer-reviews/*`.

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
- [ ] `ENABLE_GLOBAL_REMOTE=true` — **optional, and read the numbers first**
      (ADR-062). Turns on We Work Remotely + Remotive. These are publisher feeds,
      not scraping, so there's no ADR-003 sign-off to wait on — but the yield is
      ~1-3 jobs/day, and on the day it was built the honest count was **zero**
      genuine fresher roles (215 WWR postings → 1 gate pass → that one a false
      positive; Remotive's entire feed → 0). Turn it on if you want the handful
      of genuinely-remote USD roles it does surface; leave it off if you're
      expecting it to grow the pool, because it won't. Single digits in the
      ingestion health log are correct behaviour here, not an incident.
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

- [ ] **Career-ops integration, Bricks 1-6 — this session's work is NOT on
      this revision.** Nothing in `git log` reflects it (uncommitted +
      unpushed as of 2026-08-03), so the currently-live Cloud Run revision
      is still the pre-Brick-1 code. This is the actual cause of every
      "could not load / draft / not found" error reported against the
      deployed app — the routes genuinely don't exist there yet, it isn't a
      config issue. In order:
      1. Commit + push `main` (this session committed locally; push still
         needs to happen from a machine with GitHub credentials).
      2. Apply the five migrations under §1's new Brick 1-6 entry, in
         Supabase SQL Editor, in order (031 → 035). Safe before or after
         the deploy.
      3. `cd server && gcloud run deploy jobhunt-agent-server --source . --region=asia-south1`
      4. Once live, call `POST /jobs/backfill-legitimacy` once (with an
         authenticated request — Postman, curl with a bearer token, or the
         app once signed in) to score the existing job pool for Brick 1's
         legitimacy badges. Without this, badges only appear on jobs
         ingested by the next daily cron run, not on anything already in
         the pool — this is why "no badge in jobs" shows even after the
         deploy if this step is skipped.
      5. Re-test all six bricks against the live Cloud Run URL (not
         localhost) using the steps already given in chat.

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

## 5. Plan 21 — referral system + match gating (ADR-061)

**Order matters: migration BEFORE deploy.** The new code reads
`profiles.referral_code` / `bonus_match_quota`; deploying first would 500
`GET /referrals/me` and `GET /matches` until the migration lands.

1. Apply `server/db/migrations/036_referral_system.sql` in the Supabase SQL
   Editor. (Numbered 036, not the plan's 019 — 019-035 were taken.)
2. Verify the backfill before deploying:
   ```sql
   select count(*) from profiles where referral_code is null;  -- expect 0
   select count(*), count(distinct referral_code) from profiles; -- expect equal
   ```
3. `cd server && gcloud run deploy jobhunt-agent-server --source . --region=asia-south1`
4. Re-test against the live Cloud Run URL: Profile → "Invite friends" shows a
   7-character code; sharing works; redeeming an invalid code shows an inline
   error rather than failing silently.

**No new environment variables.** `BASE_FREE_MATCH_LIMIT` (3),
`REFERRAL_BONUS_MATCHES` (5) and `MAX_BONUS_MATCH_QUOTA` (50) all have
defaults in `config.py` — only set them on Cloud Run to override.

**Plan 21 Phase 3 (beta comms) is NOT needed — deliberately.** The plan
assumed beta users' match lists would visibly shrink to 3 and wanted a
heads-up push sent. Per ADR-061 the beta stays on `subscription_tier='pro'`,
which bypasses the quota entirely, so *nothing shrinks for anyone* and there
is no behaviour change to announce. The comms task becomes live only if/when
profiles are moved to `'free'` — do not skip it then.

**The gate is inert until a `'free'` tier exists.** To sanity-check it end to
end before that, flip one test profile:
```sql
update profiles set subscription_tier = 'free' where id = '<test-profile-id>';
```
That profile should then see 3 unblurred match cards plus locked teasers.
Set it back to `'pro'` afterwards.
