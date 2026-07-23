# Codebase State Audit — 2026-07-22

Read-only snapshot of the Job-Hunt Agent repo as it exists at commit `3bad610`.
Every claim below traces to a file opened during the audit. Absence is recorded
explicitly as `NOT FOUND`.

---

## Section 1 — Git state

**Current branch:** `main`

**`git log --oneline -20`:**

```
3bad610 fix(brick-10): annualize Unstop stipends with a missing pay_in as monthly
7cd2fac feat(brick-10): cost stats by-provider breakdown (Gemini vs DeepSeek)
d0a90ce feat(brick-10): India source expansion (Internshala + Unstop) + ingestion health alerting
6682c11 fix(auth): OAuth deep-link scheme was invalid — underscores are illegal in a URI scheme
75f7cad feat(brick-10): animated splash, branded loader, and a shared shimmer clock
6adeb81 feat(brick-10): FirstRole rebrand + signed release build for Play closed testing
e1b0ad1 docs(env): correct Adzuna fan-out comment (3 query wordings, not 2)
1ecb346 feat(jobs): relevance gate — fresher/intern, fullstack/frontend/cloud, Hyd+Blr, 10d
fd2493a feat(scraping): target internships/fresher roles on the scraped sources
4eca40f docs(manual-steps): record Apify deploy — secret created, env vars + code live
9758379 feat(scraping): LinkedIn/Indeed/Naukri fetchers on per-source paid cadence
e1964a0 chore(secrets): ignore .env.* variants so a stray .env.bak can't be committed
91ac1a4 feat(scraping): ADR-003 amendment + Apify config and generic actor client
1f72773 docs(manual-steps): tick off Phase 14 deploy — migrations, secret, targeting env
7d37f1f docs(manual-steps): record Cloud Run job-targeting env update
51ee22d chore(config): narrow target roles to fullstack/frontend, document API fan-out
769c76f feat(phase-14): DeepSeek provider, rate limiting, and input hardening
a492cce fix(jobs): allow display-name override for Greenhouse boards
e8fe800 perf+feat(matching): kill Gemini thinking tokens, batch+role-aware rerank
a2e07f6 fix(jobs): batch job-pool inserts to stop /jobs/refresh timeouts
```

**`git status --porcelain`:** *(empty — zero lines of output)*

| Count | Value |
|---|---|
| Modified | 0 |
| Deleted | 0 |
| Untracked | 0 |
| Staged | 0 |
| **Total porcelain lines** | **0** |

**Is the large uncommitted frontend working tree still present?**
**No.** The working tree is completely clean. Every file in `app/lib/` is committed.
There are no untracked or modified paths anywhere in the repo. (Counts of what
is committed under `app/lib/`: 27 screens, 24 widgets, 13 models, 6 services,
2 theme files, 1 config file, plus `main.dart` and `firebase_options.dart`.)

---

## Section 2 — Database schema (authoritative)

Source of truth: `server/db/migrations/*.sql`. There is no migration runner —
`MANUAL_STEPS.md` documents that these are applied by hand in the Supabase SQL
Editor. **This audit reconstructs schema from migration files, not from the live
database.** Whether each migration has actually been applied is unverifiable
from the repo (see the final section).

### 2.1 Migration list (numeric order)

| File | What it adds |
|---|---|
| `001_core_schema.sql` | `vector` extension; tables `profiles`, `jobs`, `matches`, `applications`, `tailored_resumes`, `llm_calls`; ivfflat index `jobs_embedding_idx`; SQL function `match_jobs_by_similarity`. |
| `002_followups.sql` | `applications.followup_subject`, `followup_body`, `followup_drafted_at`. |
| `003_fcm_token.sql` | `profiles.fcm_token`. |
| `004_auth.sql` | `UNIQUE (profiles.user_id)`; enables RLS + owner policies on `profiles`/`matches`/`applications`/`tailored_resumes`; authenticated-read policy on `jobs`. |
| `005_target_roles.sql` | `profiles.target_roles jsonb`, `profiles.min_salary numeric`. |
| `006_llm_calls_profile.sql` | `llm_calls.profile_id` (nullable FK), index, RLS owner-read policy. |
| `007_followup_send.sql` | `applications.contact_email`, `applications.followup_sent_at`. |
| `008_notification_prefs.sql` | `profiles.notification_prefs jsonb NOT NULL`. |
| `009_background_tasks.sql` | Table `background_tasks` + index + RLS owner-read policy. |
| `010_salary_currency.sql` | `jobs.salary_currency`; backfills `'INR'`; deletes postings older than 60 days not referenced by an application. |
| `011_onboarding_step.sql` | `profiles.onboarding_step` (NOT NULL, CHECK); backfills existing rows to `'done'`. |
| `012_form_fills.sql` | Table `form_fills` + index + RLS owner-read policy. |
| `013_fix_job_embedding_relevance.sql` | `drop index if exists jobs_embedding_idx;` (ivfflat trained on an empty table). |
| `014_student_info.sql` | `profiles.employment_type` (CHECK), `profiles.usn`; rewrites the `onboarding_step` CHECK to insert `'student_info'`. |
| `015_tailor_analysis.sql` | `tailored_resumes.analysis jsonb`, `tailored_resumes.gaps jsonb`. |
| `016_llm_calls_provider.sql` | `llm_calls.provider text NOT NULL default 'gemini'` + index + backfill. |
| `017_rate_limits.sql` | Table `rate_limit_events` + composite index; RLS enabled with **no policy**. |
| `018_source_ingestion_log.sql` | Table `source_ingestion_log` + composite index; RLS enabled with **no policy**. |

### 2.2 Reconstructed current columns

#### `profiles`

| Column | Type | Nullable | Default | Added by |
|---|---|---|---|---|
| `id` | uuid | no (PK) | `gen_random_uuid()` | 001 |
| `user_id` | uuid | yes | — | 001 (UNIQUE added in 004) |
| `name` | text | yes | — | 001 |
| `headline` | text | yes | — | 001 |
| `skills` | jsonb | yes | `'[]'` | 001 |
| `experience` | jsonb | yes | `'[]'` | 001 |
| `projects` | jsonb | yes | `'[]'` | 001 |
| `education` | jsonb | yes | `'[]'` | 001 |
| `raw_resume_text` | text | yes | — | 001 |
| `embedding` | vector(768) | yes | — | 001 |
| `created_at` | timestamptz | yes | `now()` | 001 |
| `updated_at` | timestamptz | yes | `now()` | 001 |
| `fcm_token` | text | yes | — | 003 |
| `target_roles` | jsonb | yes | `'[]'` | 005 |
| `min_salary` | numeric | yes | — | 005 |
| `notification_prefs` | jsonb | **no** | `'{"alerts": true, "followup_nudge": true}'` | 008 |
| `onboarding_step` | text | **no** | `'welcome'` — CHECK in `('welcome','resume','review','student_info','roles','done')` | 011, CHECK rewritten by 014 |
| `employment_type` | text | yes | — CHECK in `('student','experienced')` | 014 |
| `usn` | text | yes | — | 014 |

#### `jobs`

| Column | Type | Nullable | Default | Added by |
|---|---|---|---|---|
| `id` | uuid | no (PK) | `gen_random_uuid()` | 001 |
| `source` | text | **no** | — | 001 |
| `external_id` | text | yes | — | 001 |
| `title` | text | **no** | — | 001 |
| `company` | text | yes | — | 001 |
| `location` | text | yes | — | 001 |
| `description` | text | yes | — | 001 |
| `salary_min` | numeric | yes | — | 001 |
| `salary_max` | numeric | yes | — | 001 |
| `redirect_url` | text | yes | — | 001 |
| `dedup_key` | text | yes (UNIQUE) | — | 001 |
| `embedding` | vector(768) | yes | — | 001 |
| `posted_at` | timestamptz | yes | — | 001 |
| `ingested_at` | timestamptz | yes | `now()` | 001 |
| `salary_currency` | text | yes | — | 010 |

`jobs.source` has **no CHECK constraint**. Values written by code:
`adzuna`, `jsearch`, `greenhouse`, `lever`, `linkedin`, `indeed`, `naukri`,
`internshala`, `unstop`, `manual`, `jd_paste`.

#### `matches`

| Column | Type | Nullable | Default |
|---|---|---|---|
| `id` | uuid | no (PK) | `gen_random_uuid()` |
| `profile_id` | uuid | yes | — (FK `profiles(id) on delete cascade`) |
| `job_id` | uuid | yes | — (FK `jobs(id) on delete cascade`) |
| `similarity` | real | yes | — |
| `fit_score` | int | yes | — |
| `strengths` | jsonb | yes | `'[]'` |
| `gaps` | jsonb | yes | `'[]'` |
| `compensators` | jsonb | yes | `'[]'` |
| `verdict` | text | yes | — CHECK in `('apply','stretch','skip')` |
| `one_line_reason` | text | yes | — |
| `ranked_at` | timestamptz | yes | `now()` |

Plus `unique (profile_id, job_id)`.

#### `applications`

| Column | Type | Nullable | Default | Added by |
|---|---|---|---|---|
| `id` | uuid | no (PK) | `gen_random_uuid()` | 001 |
| `profile_id` | uuid | yes | — (FK cascade) | 001 |
| `job_id` | uuid | yes | — (FK cascade) | 001 |
| `state` | text | **no** | `'saved'` — CHECK in `('saved','applied','replied','interview','offer','rejected')` | 001 |
| `resume_version_id` | uuid | yes | — | 001 |
| `notes` | text | yes | — | 001 |
| `state_changed_at` | timestamptz | yes | `now()` | 001 |
| `created_at` | timestamptz | yes | `now()` | 001 |
| `followup_subject` | text | yes | — | 002 |
| `followup_body` | text | yes | — | 002 |
| `followup_drafted_at` | timestamptz | yes | — | 002 |
| `contact_email` | text | yes | — | 007 |
| `followup_sent_at` | timestamptz | yes | — | 007 |

#### `tailored_resumes`

| Column | Type | Nullable | Default | Added by |
|---|---|---|---|---|
| `id` | uuid | no (PK) | `gen_random_uuid()` | 001 |
| `profile_id` | uuid | yes | — (FK cascade) | 001 |
| `job_id` | uuid | yes | — (FK cascade) | 001 |
| `bullets` | jsonb | **no** | — | 001 |
| `guardrail_flags` | int | yes | `0` | 001 |
| `approved` | boolean | yes | `false` | 001 |
| `created_at` | timestamptz | yes | `now()` | 001 |
| `analysis` | jsonb | yes | — | 015 |
| `gaps` | jsonb | yes | — | 015 |

#### `llm_calls`

| Column | Type | Nullable | Default | Added by |
|---|---|---|---|---|
| `id` | bigint | no (PK) | `generated always as identity` | 001 |
| `task` | text | **no** | — | 001 |
| `model` | text | yes | — | 001 |
| `prompt_hash` | text | yes | — | 001 |
| `tokens_in` | int | yes | — | 001 |
| `tokens_out` | int | yes | — | 001 |
| `latency_ms` | int | yes | — | 001 |
| `validation_passed` | boolean | yes | — | 001 |
| `retried` | boolean | yes | `false` | 001 |
| `created_at` | timestamptz | yes | `now()` | 001 |
| `profile_id` | uuid | yes | — (FK `profiles(id) on delete set null`) | 006 |
| `provider` | text | **no** | `'gemini'` | 016 |

### 2.3 Tables added since `008` (four of them)

#### `background_tasks` (009)

| Column | Type | Nullable | Default |
|---|---|---|---|
| `id` | uuid | no (PK) | `gen_random_uuid()` |
| `profile_id` | uuid | **no** | — (FK `profiles(id) on delete cascade`) |
| `task_type` | text | **no** | — |
| `status` | text | **no** | `'pending'` — CHECK in `('pending','running','done','failed')` |
| `result` | jsonb | yes | — |
| `error` | text | yes | — |
| `created_at` | timestamptz | **no** | `now()` |
| `updated_at` | timestamptz | **no** | `now()` |

#### `form_fills` (012)

| Column | Type | Nullable | Default |
|---|---|---|---|
| `id` | uuid | no (PK) | `gen_random_uuid()` |
| `profile_id` | uuid | **no** | — (FK cascade) |
| `form_url` | text | **no** | — |
| `form_title` | text | yes | — |
| `answers` | jsonb | **no** | — |
| `prefill_url` | text | yes | — |
| `created_at` | timestamptz | **no** | `now()` |

#### `rate_limit_events` (017)

| Column | Type | Nullable | Default |
|---|---|---|---|
| `id` | bigint | no (PK) | `generated always as identity` |
| `subject` | text | **no** | — |
| `endpoint` | text | **no** | — |
| `created_at` | timestamptz | **no** | `now()` |

#### `source_ingestion_log` (018)

| Column | Type | Nullable | Default |
|---|---|---|---|
| `id` | bigint | no (PK) | `generated always as identity` |
| `source` | text | **no** | — |
| `run_date` | date | **no** | — |
| `item_count` | integer | **no** | `0` |
| `status` | text | **no** | `'ok'` |
| `error_message` | text | yes | — |
| `created_at` | timestamptz | **no** | `now()` |

### 2.4 The specific-columns checklist

| Looking for | Exists? | Table / column name |
|---|---|---|
| job posting date / freshness | **Yes** | `jobs.posted_at` (timestamptz, source-reported) and `jobs.ingested_at` (timestamptz, our fetch time). Age gate is `settings.max_job_age_days` (default `10`) applied in `services/job_ingestion.py::is_fresh`, not a column. |
| salary currency code | **Yes** | `jobs.salary_currency` (text, migration 010) |
| salary min / max as separate numerics | **Yes** | `jobs.salary_min numeric`, `jobs.salary_max numeric` (migration 001) |
| normalized job source | **Partial** | `jobs.source text NOT NULL` exists, but it is free text with **no CHECK constraint and no lookup table**. Normalization is by convention in the fetcher code only. |
| work type (remote / hybrid / onsite) | **NOT FOUND** | No column on any table. Remote-ness is *derived at ingestion time* by `services/job_filter.py::is_remote` and then discarded — only the pass/fail result affects whether the row is inserted. |
| job source URL | **Yes** | `jobs.redirect_url` (text) |
| per-profile target locations | **NOT FOUND** | `profiles.target_roles` and `profiles.min_salary` exist (005), but there is no per-profile locations column. Locations are global: `settings.target_locations` / `settings.adzuna_locations` in `server/config.py`. |
| user type (student / professional) | **Yes** | `profiles.employment_type` — CHECK in `('student','experienced')` (014) |
| student fields — usn | **Yes** | `profiles.usn` (text, 014) |
| student fields — college | **Partial** | No dedicated column. Written into `profiles.education` jsonb as `education[0].institution` (`routers/resume.py::update_student_info`). |
| student fields — branch, grad year, cgpa | **NOT FOUND** | No columns. `education` jsonb items carry `{degree, institution, year}` per `routers/resume.py:204`; there is no branch or CGPA field anywhere. |
| professional fields — company | **NOT FOUND** as a column. Present only inside `profiles.experience` jsonb entries. |
| professional fields — experience | **Partial** | `profiles.experience` jsonb (resume work history). No numeric years-of-experience column. |
| professional fields — employment type | **Yes** | `profiles.employment_type` (but its two allowed values are `student`/`experienced`, not full-time/contract) |
| professional fields — notice period | **NOT FOUND** | No column anywhere. |
| subscription / tier / plan | **NOT FOUND** | No such column or table in any migration. |
| any wallet, credit, or balance column | **NOT FOUND** | No such column or table in any migration. |
| notification persistence table | **NOT FOUND** | No table stores delivered notifications. Only `profiles.fcm_token` (003) and `profiles.notification_prefs` (008) exist; `services/notify.py::send_push_notification` sends and does not persist. |
| any score history / snapshot table | **NOT FOUND** | `matches` has `unique (profile_id, job_id)` and a single `ranked_at` — a re-rank overwrites in place, so no history survives. |
| onboarding step / resume-progress column | **Yes** | `profiles.onboarding_step` (011, CHECK rewritten by 014) |

### 2.5 SQL functions / RPCs

Exactly one, defined in `001_core_schema.sql`:

```sql
create or replace function match_jobs_by_similarity(p_profile_id uuid, p_limit int default 50)
returns table (job_id uuid, similarity real)
language sql stable as $$
  select j.id, 1 - (j.embedding <=> p.embedding) as similarity
  from jobs j, profiles p
  where p.id = p_profile_id and j.embedding is not null
  order by j.embedding <=> p.embedding
  limit p_limit;
$$;
```

Called from `routers/matches.py:20` and `services/matching.py::_stage1_shortlist`.

### 2.6 RLS policies currently defined

| Table | Policy name | Type | Predicate |
|---|---|---|---|
| `profiles` | `"profiles: owner read/write"` | `for all` | `using (auth.uid() = user_id) with check (auth.uid() = user_id)` |
| `matches` | `"matches: owner read/write"` | `for all` | `using (profile_id in (select id from profiles where user_id = auth.uid()))` |
| `applications` | `"applications: owner read/write"` | `for all` | `using (profile_id in (select id from profiles where user_id = auth.uid()))` |
| `tailored_resumes` | `"tailored_resumes: owner read/write"` | `for all` | `using (profile_id in (select id from profiles where user_id = auth.uid()))` |
| `jobs` | `"jobs: authenticated read"` | `for select` | `using (auth.role() = 'authenticated')` |
| `llm_calls` | `"llm_calls: owner read"` | `for select` | `using (profile_id in (select id from profiles where user_id = auth.uid()))` |
| `background_tasks` | `"background_tasks: owner read"` | `for select` | `using (profile_id in (select id from profiles where user_id = auth.uid()))` |
| `form_fills` | `"form_fills: owner read"` | `for select` | `using (profile_id in (select id from profiles where user_id = auth.uid()))` |
| `rate_limit_events` | *(none)* | — | RLS **enabled with no policy** — denies the anon key outright (017) |
| `source_ingestion_log` | *(none)* | — | RLS **enabled with no policy** (018) |

`004_auth.sql` states in a comment that RLS is *not* the enforcement boundary:
the server connects with the service-role key (bypasses RLS) and scopes every
query itself in `services/auth.py`.

### 2.7 Indexes

| Index | Table | Status |
|---|---|---|
| `jobs_embedding_idx` (ivfflat, lists=100) | `jobs` | **DROPPED** by `013_fix_job_embedding_relevance.sql` — no ANN index exists today; stage-1 similarity is an exact brute-force scan. |
| `llm_calls_profile_id_idx` | `llm_calls` | live (006) |
| `background_tasks_profile_id_idx` | `background_tasks` | live (009) |
| `form_fills_profile_id_idx` | `form_fills` | live (012) |
| `llm_calls_provider_idx` | `llm_calls` | live (016) |
| `rate_limit_events_lookup_idx (subject, endpoint, created_at)` | `rate_limit_events` | live (017) |
| `source_ingestion_log_lookup_idx (source, run_date)` | `source_ingestion_log` | live (018) |

---

## Section 3 — API surface

`server/main.py` is 37 lines: it registers nine routers, adds a wide-open CORS
middleware (`allow_origins=["*"]`), and defines `GET /health`.

### 3.1 Full endpoint table

| Method | Path | Router file | Auth dependency | Purpose |
|---|---|---|---|---|
| GET | `/health` | `main.py` | **none** | Liveness + server time. |
| POST | `/resume/parse` | `routers/resume.py` | `get_current_user_id` + `enforce_rate_limit_by_user("resume_parse", 3, 300)` | Vision-parse an uploaded resume PDF; creates/updates the caller's profile. |
| GET | `/resume/profile` | `routers/resume.py` | `get_current_user_id` | Caller's profile, or `null` pre-upload (soft-missing, not 404). |
| PATCH | `/resume/profile` | `routers/resume.py` | `get_current_profile` | Edit parsed profile fields; re-embeds; advances onboarding to `student_info`. |
| PATCH | `/resume/profile/student-info` | `routers/resume.py` | `get_current_profile` | student/experienced + USN + college backfill; advances to `roles`. |
| PATCH | `/resume/profile/fcm-token` | `routers/resume.py` | `get_current_profile` | Register this device's FCM token (no re-embed). |
| PATCH | `/resume/profile/target-roles` | `routers/resume.py` | `get_current_profile` | Target roles + min salary; **re-embeds** (ADR-021); advances to `done`. |
| PATCH | `/resume/profile/onboarding-step` | `routers/resume.py` | `get_current_profile` | Forward-only explicit step advance (skip buttons). |
| PATCH | `/resume/profile/notification-prefs` | `routers/resume.py` | `get_current_profile` | Toggle `alerts` / `followup_nudge`. |
| POST | `/jobs/refresh` | `routers/jobs.py` | `get_current_user_id` + `enforce_rate_limit_by_user("jobs_refresh", 10, 300)` | Refresh the **shared** job pool from the four free sources. |
| GET | `/jobs` | `routers/jobs.py` | `get_current_user_id` | Paginated job pool, newest `ingested_at` first. |
| POST | `/jobs/backfill-embeddings` | `routers/jobs.py` | `get_current_user_id` | One-off embed of rows where `embedding is null`. |
| POST | `/jobs/manual/parse` | `routers/jobs.py` | `get_current_profile` + `enforce_rate_limit("manual_parse", 5, 300)` | Fetch a pasted URL server-side (SSRF-guarded) and LLM-extract job fields. |
| POST | `/jobs/manual` | `routers/jobs.py` | `get_current_user_id` | Create (or return dedup-matched) job from user-reviewed fields. |
| POST | `/jobs/from-jd/parse` | `routers/jobs.py` | `get_current_profile` + `enforce_rate_limit("manual_parse", 5, 300)` | JD-paste builder step 1: text or PDF → structured fields (Gemini lite tier). |
| POST | `/jobs/from-jd` | `routers/jobs.py` | `get_current_profile` | Create a `source='jd_paste'` job + a `'saved'` application row. |
| GET | `/matches/shortlist` | `routers/matches.py` | `get_current_profile` | Stage-1 pgvector cosine shortlist via `match_jobs_by_similarity`. |
| POST | `/matches/rerank` | `routers/matches.py` | `get_current_profile` + `enforce_rate_limit("rerank", 5, 300)` | **202 + task id.** Stage-2 LLM re-rank in a background task. |
| GET | `/matches` | `routers/matches.py` | `get_current_profile` | Cached stage-2 results, best fit first. |
| POST | `/tailor/{job_id}` | `routers/tailor.py` | `get_current_profile` + `enforce_rate_limit("tailor", 5, 300)` | **202 + task id.** Tailor bullets + guardrail, stored unapproved. |
| GET | `/tailor/{job_id}` | `routers/tailor.py` | `get_current_profile` | Most recent tailored resume for a job. |
| GET | `/tailor/{tailored_resume_id}/pdf` | `routers/tailor.py` | `get_current_profile` | Raw `application/pdf` bytes (documented envelope exception). |
| PATCH | `/tailor/{tailored_resume_id}/approve` | `routers/tailor.py` | `get_current_profile` | Human approval gate + per-bullet accept/reject. |
| POST | `/applications` | `routers/applications.py` | `get_current_profile` | Add job to Kanban; idempotent per (profile, job). |
| GET | `/applications` | `routers/applications.py` | `get_current_profile` | All tracked applications with job details joined. |
| PATCH | `/applications/{application_id}` | `routers/applications.py` | `get_current_profile` | Move stage / update notes / set contact email. |
| POST | `/applications/{application_id}/followup` | `routers/applications.py` | `get_current_profile` | On-demand follow-up draft (LLM). Drafts only. |
| POST | `/applications/{application_id}/followup/send` | `routers/applications.py` | `get_current_profile` | The one outbound-send action, via Resend. |
| POST | `/pipeline/run` | `routers/pipeline.py` | `verify_pipeline_cron` (`X-Pipeline-Secret` **or** Cloud Scheduler OIDC) | All-users batch agent loop. Deliberately exempt from rate limiting. |
| POST | `/pipeline/run-mine` | `routers/pipeline.py` | `get_current_profile` + `enforce_rate_limit("pipeline_mine", 5, 300)` | **202 + task id.** "Run agent now" for the caller only. |
| GET | `/stats/costs` | `routers/stats.py` | `get_current_profile` | This-month LLM spend by task **and** by provider. |
| GET | `/stats/activity` | `routers/stats.py` | `get_current_profile` | Merged activity feed from applications + tailored resumes. |
| GET | `/stats/skill-growth` | `routers/stats.py` | `get_current_profile` | Skills-to-learn clustered from real match gaps (LLM). |
| GET | `/tasks/{task_id}` | `routers/tasks.py` | `get_current_profile` | Poll a background task; other people's ids 404. |
| POST | `/forms/parse` | `routers/forms.py` | `get_current_profile` | Fetch + parse a form URL (deterministic for Google Forms, LLM otherwise). |
| POST | `/forms/fill` | `routers/forms.py` | `get_current_profile` | Map profile → answers, verify choices, return a prefill URL. |
| PATCH | `/forms/fills/{fill_id}` | `routers/forms.py` | `get_current_profile` | Persist the user's final edited answers for history reuse. |

### 3.2 Long-running synchronous endpoints (hold the HTTP connection open)

**202 + polling IS implemented** (via `services/background_tasks.py` + `GET /tasks/{id}`, ADR-011) for exactly three endpoints:

| Endpoint | Pattern |
|---|---|
| `POST /matches/rerank` | `status_code=202`, `background.add_task(run_task, ...)` |
| `POST /tailor/{job_id}` | `status_code=202`, `background.add_task(run_task, ...)` |
| `POST /pipeline/run-mine` | `status_code=202`, `background.add_task(run_task, ...)` |

**202 + polling is NOT implemented** for these, which all block on the request thread:

| Endpoint | What it blocks on | 202 pattern? |
|---|---|---|
| `POST /pipeline/run` | The **entire** all-users agent loop — job fetch across 4+ sources, batch embeddings, ingestion health, then per-profile re-rank + follow-up drafting for every profile. Synchronous by design (`routers/pipeline.py:20`, `summary = await run_daily_pipeline_for_all()`). | **No** — deliberate; the docstring notes the cron runner has no socket-timeout problem. |
| `POST /resume/parse` | PDF rasterize + Gemini vision call + embedding + DB upsert. | **No** |
| `POST /jobs/refresh` | `asyncio.gather` over Adzuna/JSearch/Greenhouse/Lever + batched embedding + upsert. Client timeout is 120s. | **No** |
| `POST /jobs/manual/parse` | Outbound URL fetch (15s per hop, up to 6 hops) + one LLM extraction. | **No** |
| `POST /jobs/from-jd/parse` | One LLM extraction on up to 50k chars. | **No** |
| `POST /applications/{id}/followup` | One LLM call. | **No** |
| `GET /stats/skill-growth` | One LLM call over up to 50 matches; the Flutter client allows **3 minutes** for it. | **No** |
| `POST /forms/parse` | Outbound fetch + up to **two** LLM calls (form extraction, then job extraction if the description ≥600 chars). | **No** |
| `POST /forms/fill` | One LLM call; client timeout 90s. | **No** |

---

## Section 4 — Services and LLM routing

### 4.1 `server/services/` inventory

| File | Lines | Responsibility |
|---|---|---|
| `activity.py` | 71 | Builds the "what the agent did" feed from `applications` + `tailored_resumes` rows (no dedicated activity table). |
| `apify_client.py` | 87 | Generic Apify actor runner (`run-sync-get-dataset-items`); never raises, returns `[]` on every failure. |
| `auth.py` | 74 | `get_current_user_id` (Supabase JWT), `get_current_profile`, `verify_pipeline_cron` (shared secret **or** Google OIDC). |
| `background_tasks.py` | 88 | ADR-011 async job pattern: `create_task` / `get_task` / `run_task` over the `background_tasks` table. |
| `cost_stats.py` | 106 | Prices `llm_calls` rows and aggregates by task and by provider. |
| `dedup.py` | 31 | `make_dedup_key` (slugified title\|company\|location) + `is_duplicate` (rapidfuzz, threshold 90). |
| `email.py` | 84 | Resend client: `send_followup_email` and `send_ops_alert`. |
| `embeddings.py` | 129 | `gemini-embedding-001` batched embedding (batch 50, 768-dim pinned) + the profile/job embedding-text builders. |
| `form_parser.py` | 226 | Deterministic Google Forms parser (`FB_PUBLIC_LOAD_DATA_`), choice-membership guardrail, prefill-URL builder, answer-history reuse. |
| `guardrail.py` | 114 | ADR-004 anti-fabrication post-check (`verify_bullets`, threshold 85), `verify_skills` (80), `compute_gaps`. |
| `ingestion_health.py` | 205 | Pure `evaluate_ingestion_health` + `record_and_alert_ingestion`; flags a source at <20% of its 7-day trailing average. |
| `job_filter.py` | 127 | The relevance gate: role regex, seniority veto, entry-level, Hyd/Blr-or-remote. Pure functions. |
| `job_ingestion.py` | 523 | Freshness gate, SSRF-guarded manual fetch, dedup→embed→upsert back-half, `refresh_job_pool`, `refresh_scraped_sources`, `refresh_unstop`, weekday cadence. |
| `job_sources.py` | 836 | All nine fetchers + city canonicalization + Adzuna currency map. |
| `llm.py` | 886 | Every prompt, both provider clients, and the single validate→retry-once→log runner. |
| `matching.py` | 262 | Stage-1 shortlist, role-aware pre-screen, batched re-rank (batch 10), Python final scoring and verdict. |
| `notify.py` | 64 | firebase-admin FCM push; degrades to log-only when unconfigured. |
| `pdf_safety.py` | 121 | ADR-026 upload bounds: magic bytes, 10MB, 20 pages, 60s render timeout. |
| `rate_limit.py` | 127 | ADR-027 Postgres trailing-window limiter; two dependency factories (by profile / by user). |
| `resume_pdf.py` | 279 | ReportLab ATS PDF compiler; deterministic layout/accent/one-page fit. |
| `salary.py` | 208 | Free-text salary parsing + annualization + `infer_currency`. |
| `skill_growth.py` | 42 | Aggregates real match gaps into skills-to-learn (counting in Python, LLM only labels). |

### 4.2 LLM provider routing as the code stands today

Authoritative source: `server/services/llm.py:299-347`.

```python
_TASK_PROVIDERS: dict[str, str] = {
    "parse": GEMINI,  # vision-required — DeepSeek is text-only
    "rerank": DEEPSEEK,
    "extract_job": DEEPSEEK,
    "followup": DEEPSEEK,
    "skill_growth": DEEPSEEK,
    "extract_form": DEEPSEEK,
    "form_fill": DEEPSEEK,
}
```

```python
def _model_for(provider: str) -> str:
    return settings.deepseek_model if provider == DEEPSEEK else settings.gemini_model
```

| Task function | Provider (default) | Model | Where the model name is configured |
|---|---|---|---|
| `parse_resume` | Gemini (hard-pinned — vision) | `gemini-2.5-flash` | `settings.gemini_model`, `config.py:6` |
| `rerank_jobs` | DeepSeek | `deepseek-v4-flash` | `settings.deepseek_model`, `config.py:30` |
| `tailor_resume` | **Gemini** | `gemini-2.5-flash` | `settings.tailor_provider` (`config.py:37`, default `"gemini"`) + `settings.gemini_model` |
| `generate_followup_draft` | DeepSeek | `deepseek-v4-flash` | `settings.deepseek_model` |
| `extract_job_from_text` | DeepSeek | `deepseek-v4-flash` | `settings.deepseek_model` |
| `generate_skill_growth` | DeepSeek | `deepseek-v4-flash` | `settings.deepseek_model` |
| `extract_form_from_text` | DeepSeek | `deepseek-v4-flash` | `settings.deepseek_model` |
| `map_profile_to_form` | DeepSeek | `deepseek-v4-flash` | `settings.deepseek_model` |
| Embeddings (`embed_texts`) | Gemini — **never routes through `llm.py`** | `gemini-embedding-001`, `output_dimensionality=768`, `task_type="SEMANTIC_SIMILARITY"` | `settings.gemini_embed_model`, `config.py:7`; dims hardcoded in `embeddings.py:51` |

**Per-call overrides** (`provider` and `model` must travel together, `llm.py:538-541`):
- `routers/jobs.py::parse_jd` pins `model=settings.gemini_model_lite, provider="gemini"` → `gemini-3.1-flash-lite`.
- `routers/tailor.py::tailor_and_store` pins the same pair when `job["source"] == "jd_paste"`.

**Fallback:** `_provider_for` returns `GEMINI` whenever DeepSeek is routed but
`settings.deepseek_api_key` is empty. `llm_calls.provider` records the provider
that *actually* served the call, so the fallback shows up in `GET /stats/costs`.

### 4.3 DeepSeek migration — what landed vs. what didn't

| Item | Landed in code? |
|---|---|
| Second provider behind one validate/retry/log flow (`_run_llm_task`) | **Yes** — `llm.py:510-606`, one implementation for both providers. |
| `_call_deepseek` with `extra_body={"thinking": {"type": "disabled"}}` on every call | **Yes** — `llm.py:489`. |
| Per-task routing table | **Yes** — `_TASK_PROVIDERS`, `llm.py:299`. |
| Graceful fallback on a missing key | **Yes** — `_provider_for`, `llm.py:341-343`. |
| `llm_calls.provider` column + backfill + index | **Yes** — migration `016`. |
| `GET /stats/costs` by-provider breakdown | **Yes** — `cost_stats.py::summarize_costs` returns `by_provider`; rendered by `app/lib/screens/cost_stats_screen.dart:137`. |
| DeepSeek pricing rows | **Yes** — `deepseek-v4-flash` and `deepseek-v4-pro` in `_PRICING_PER_MILLION_TOKENS`. |
| **Moving `tailor` to DeepSeek** | **No** — `settings.tailor_provider` still defaults to `"gemini"` (`config.py:37`). ADR-023 gates it on a guardrail-pass A/B that has not been recorded anywhere in the repo. `MANUAL_STEPS.md:53` still shows this unchecked. |
| `DEEPSEEK_API_KEY` present in production | **Unverifiable from the repo.** `MANUAL_STEPS.md:46` is ticked `[x]` for creating the secret on Cloud Run, but the repo cannot confirm it. |

### 4.4 Rate limiting, input validation, SSRF

| Control | Implemented? | Where |
|---|---|---|
| Rate limiting | **Yes** | `services/rate_limit.py` + migration `017`. Postgres trailing-window count (prune → count → insert). Applied to 6 route groups: `/matches/rerank` (5), `/tailor/{id}` (5), `/pipeline/run-mine` (5), `/resume/parse` (3, keyed on user id), `/jobs/manual/parse` + `/jobs/from-jd/parse` (5, shared `manual_parse` key), `/jobs/refresh` (10). Window 300s. All configurable via `config.py:229-235`. **Not applied to** `/forms/parse`, `/forms/fill`, `/applications/{id}/followup`, `/stats/skill-growth` — all of which make LLM calls. |
| Request-body validation | **Yes** | `models/common.py` — `StrictModel` (`extra="forbid"`) + 22 length/collection caps. Literal types for `onboarding_step` and `employment_type` in `routers/resume.py:36-39`. |
| SSRF protection | **Yes** | `services/job_ingestion.py::_assert_public_url` (`:70-103`) — scheme allowlist `("http","https")`, `socket.getaddrinfo` on **every** resolved address, `ip.is_global` check. Redirects followed manually (`_MAX_REDIRECTS = 5`) so each hop is re-validated rather than trusting httpx. DNS rebinding documented as a residual gap. |
| SSRF on the **forms** path | **Partial / gap** | `services/form_parser.py::fetch_form_html` is a separate fetcher and does **not** call `_assert_public_url`. `POST /forms/parse` takes `class ParseFormRequest(BaseModel): url: str` — a plain `BaseModel`, **not** `StrictModel`, with no length cap. |
| PDF upload safety | **Yes** | `services/pdf_safety.py` — `MAX_UPLOAD_BYTES = 10MB`, `MAX_PDF_PAGES = 20`, `PDF_RENDER_TIMEOUT_SECONDS = 60`, magic-byte check `b"%PDF-"`. |
| Prompt-injection wrapping | **Yes, best-effort only** | `llm.py::wrap_untrusted` (`:363-379`). ADR-025 explicitly states this is a documented residual risk, not a boundary. |

### 4.5 `_PRICING_PER_MILLION_TOKENS` (verbatim, `services/cost_stats.py:19-29`)

```python
_PRICING_PER_MILLION_TOKENS: dict[str, tuple[float, float]] = {
    "gemini-2.5-flash": (0.30, 2.50),
    # old lite tier kept for pricing historical llm_calls rows; new lite
    # tier assumed same list price until Google publishes otherwise.
    "gemini-2.5-flash-lite": (0.10, 0.40),
    "gemini-3.1-flash-lite": (0.10, 0.40),
    "gemini-embedding-001": (0.15, 0.0),
    "deepseek-v4-flash": (0.14, 0.28),
    "deepseek-v4-pro": (0.435, 0.87),
}
_FALLBACK_PRICING = (0.30, 2.50)
```

**Are thinking/reasoning tokens accounted for?** **Yes.**
- Gemini: `_call_gemini` returns `tokens_out = (usage.candidates_token_count or 0) + (usage.thoughts_token_count or 0)` (`llm.py:452`), and `thinking_budget=0` is passed on every call (`llm.py:445`).
- DeepSeek: `tokens_out` is `usage.completion_tokens`, which the docstring notes includes reasoning tokens, and `thinking` is explicitly disabled per call.
- DeepSeek input is priced entirely at the cache-**miss** rate — a deliberate overestimate, documented at `cost_stats.py:13-18`.

---

## Section 5 — Job sources and the scraping gate

### 5.1 Fetchers in `server/services/job_sources.py`

| Function | Source | API / actor | Returns |
|---|---|---|---|
| `fetch_adzuna()` | Adzuna | `https://api.adzuna.com/v1/api/jobs/{country}/search/1` | `list[JobIn]`. Fans out roles × `_adzuna_locations()` × **3 query wordings** (`role`, `role intern`, `role fresher`), 20 results per query. |
| `fetch_jsearch()` | JSearch (RapidAPI) | `https://jsearch.p.rapidapi.com/search-v2` | `list[JobIn]`. One query per role×location (`"{role} intern in {location}"`) — deliberately not two, because the free tier caps at 200 req/month. |
| `fetch_linkedin_apify(role, location, max_results)` | LinkedIn | Apify actor from `settings.apify_linkedin_actor_id`. Docstring names `curious_coder~linkedin-jobs-scraper` ($0.001/result). Builds a `https://www.linkedin.com/jobs/search/` URL. | `list[JobIn]`; salary parsed from free text. `count` floored at 10. |
| `fetch_indeed_apify(role, location, max_results)` | Indeed | Apify actor from `settings.apify_indeed_actor_id`. Docstring names `misceres~indeed-scraper` ($0.006/result). | `list[JobIn]`; drops `isExpired` rows. |
| `fetch_naukri_apify(role, location, max_results)` | Naukri | Apify actor from `settings.apify_naukri_actor_id`. Docstring names `makework36~naukri-scraper` ($0.0095/result). | `list[JobIn]`; native `experienceMin=0`/`experienceMax` filter; `fetchDetails` for full JDs, 280s timeout. |
| `fetch_internshala_apify(role, location, max_results)` | Internshala | Apify actor from `settings.apify_internshala_actor_id`. Docstring names `blackfalcondata~internshala-scraper` ($0.0015/result). `listingType` fixed to `"internship"`. | `list[JobIn]`; stipends annualized via `_internshala_salary`. |
| `fetch_unstop_internships(max_results)` | Unstop | **Direct httpx**, not Apify: `https://unstop.com/api/public/opportunity/search-result` | `list[JobIn]`; paginated (`per_page` ≤ 100), one search per configured role, browser-like headers, every response level type-checked. |
| `fetch_greenhouse()` | Greenhouse | `https://boards-api.greenhouse.io/v1/boards/{slug}/jobs?content=true` | `list[JobIn]`; no salary data. |
| `fetch_lever()` | Lever | `https://api.lever.co/v0/postings/{slug}?mode=json` | `list[JobIn]`; no salary data. |

Support functions in the same file: `_roles()`, `_locations()`, `_adzuna_locations()`, `_slug_name_pairs()`, `_greenhouse_boards()`, `_lever_companies()`, `_strip_html()`, `_primary_city()`, `_linkedin_search_url()`, `_internshala_salary()`, `_unstop_posted_at()`, `_unstop_row_to_job()`.

### 5.2 Where each source runs

| Source | Daily cron (`POST /pipeline/run`) | Manual refresh (`POST /jobs/refresh`) | "Run agent now" (`POST /pipeline/run-mine`) | Notes |
|---|---|---|---|---|
| Adzuna | Yes | Yes | Yes | In `_FREE_SOURCES` (`job_ingestion.py:272-277`) |
| JSearch | Yes | Yes | Yes | In `_FREE_SOURCES` |
| Greenhouse | Yes | Yes | Yes | In `_FREE_SOURCES` |
| Lever | Yes | Yes | Yes | In `_FREE_SOURCES` |
| LinkedIn | **Cron only**, weekday-gated | No | No | `refresh_scraped_sources` is called only from `_refresh_scraped_if_due`, which only `run_daily_pipeline_for_all` calls |
| Indeed | **Cron only**, weekday-gated | No | No | same |
| Naukri | **Cron only**, weekday-gated | No | No | same |
| Internshala | **Cron only**, weekday-gated **and** `enable_india_sources`-gated | No | No | Added to `configured` only inside `if settings.enable_india_sources:` |
| Unstop | **Cron only**, `enable_india_sources`-gated, **no weekday cadence** | No | No | `refresh_unstop()` self-gates; free endpoint so no cost cadence |

As shipped in the repo, **all five scraped sources are dormant by default**:
`apify_api_token`, `apify_linkedin_actor_id`, `apify_indeed_actor_id`,
`apify_naukri_actor_id` and `apify_internshala_actor_id` all default to `""` in
`config.py`, and `enable_india_sources` defaults to `False`. `server/.env` exists
in the working tree but was not opened (Golden Rule 5 of this audit).

### 5.3 Are all five implemented?

| Source | Implemented? | Exact actor ID / endpoint |
|---|---|---|
| LinkedIn | **Yes** | Actor ID from `settings.apify_linkedin_actor_id` (default `""`). Docstring: `curious_coder~linkedin-jobs-scraper`. Search URL constant `LINKEDIN_JOBS_SEARCH = "https://www.linkedin.com/jobs/search/"`. |
| Indeed | **Yes** | `settings.apify_indeed_actor_id` (default `""`). Docstring: `misceres~indeed-scraper`. |
| Naukri | **Yes** | `settings.apify_naukri_actor_id` (default `""`). Docstring: `makework36~naukri-scraper`. |
| Unstop | **Yes** | `UNSTOP_SEARCH_URL = "https://unstop.com/api/public/opportunity/search-result"` — direct httpx, no Apify. |
| Internshala | **Yes** | `settings.apify_internshala_actor_id` (default `""`). Docstring: `blackfalcondata~internshala-scraper`. |
| Adzuna | **Yes** | `ADZUNA_BASE = "https://api.adzuna.com/v1/api/jobs"` → `{ADZUNA_BASE}/{country}/search/1` |
| JSearch | **Yes** | `JSEARCH_URL = "https://jsearch.p.rapidapi.com/search-v2"` |

The actor IDs above come from **docstrings in `job_sources.py` and comments in
`.env.example`** — they are not code defaults. The code defaults are all `""`.

### 5.4 The limited-user scraping gate — how it is actually implemented

**There is no per-user allowlist of any kind. `NOT FOUND`:** no allowlist table,
no hardcoded user list, no user-count check, no invite-code field, no per-user
feature flag. ADR-003 v2's "invite-only to known individuals, soft ceiling of
~100 users" is a **policy stated in `DECISIONS.md` with zero code enforcement.**

What actually exists is four *source-level* gates. Here they are verbatim.

**Gate 1 — the master kill switch for the two new India sources**
(`server/services/job_ingestion.py:360-373`):

```python
    # India source expansion (ADR-003 v2, 2026-07-20): Internshala only enters
    # the rotation when the master switch is on, even if its actor ID and
    # weekdays are set. This is the ADR sign-off gate expressed in code — the
    # source cannot go live by config alone.
    if settings.enable_india_sources:
        configured.append(
            (
                "internshala",
                settings.apify_internshala_actor_id,
                fetch_internshala_apify,
                settings.apify_internshala_weekdays,
                settings.internshala_max_results,
            )
        )
```

and (`server/services/job_ingestion.py:488-490`):

```python
    if not settings.enable_india_sources:
        logger.info("Unstop skipped: ENABLE_INDIA_SOURCES is false")
        return {"fetched": 0, "inserted": 0, "by_source": {}, "errors": {}, "skipped": "disabled"}
```

Backed by `server/config.py:194`:

```python
    enable_india_sources: bool = False
```

**Gate 2 — the token + actor-ID + weekday-cadence filter**
(`server/services/job_ingestion.py:375-385`):

```python
    return [
        (name, fetcher, cap)
        for name, actor_id, fetcher, weekdays, cap in configured
        if actor_id.strip() and _is_due(weekdays, now)
    ]


def should_scrape_today(now: datetime | None = None) -> bool:
    """True when ANY scraped source is due today — the cheap check the daily
    pipeline uses to skip the whole paid path without building task lists."""
    return bool(settings.apify_api_token) and bool(_scraped_sources_due(now))
```

with (`server/services/job_ingestion.py:316-325`):

```python
_WEEKDAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")


def _is_due(weekdays: str, now: datetime | None = None) -> bool:
    """True when today falls in a comma-separated weekday list. Empty → never."""
    allowed = {d.strip().lower() for d in weekdays.split(",") if d.strip()}
    if not allowed:
        return False
    return _WEEKDAYS[(now or datetime.now(timezone.utc)).weekday()] in allowed
```

and (`server/services/job_ingestion.py:399-401`):

```python
    if not settings.apify_api_token:
        logger.info("Scraped sources skipped: APIFY_API_TOKEN not set")
        return {"fetched": 0, "inserted": 0, "calls": 0, "skipped": "no_token"}
```

**Gate 3 — the "cron path only, never user-triggerable" structural gate.**
`_refresh_scraped_if_due()` is called from `run_daily_pipeline_for_all()` only;
`_refresh_and_backfill()` (shared with the per-user path) contains no scraping.
From `server/jobs/daily_pipeline.py:140-153`:

```python
async def _refresh_scraped_if_due() -> dict:
    """The scraped sources, gathered here so they run ONLY from
    run_daily_pipeline_for_all — the cron path — and never from
    _refresh_and_backfill(), which is shared with run_daily_pipeline_for_profile()
    (the app's "Run agent now" button). Putting scraping in the shared helper
    would let any user spend real Apify money — or hit Unstop — on demand by
    tapping a button; the rate limiter would cap the rate, not the fact of it.
```

**Gate 4 — a second, independent token check inside the actor client**
(`server/services/apify_client.py:38-43`):

```python
    if not settings.apify_api_token:
        logger.warning("Apify actor %s skipped: APIFY_API_TOKEN is not set", actor_id)
        return []
    if not actor_id:
        logger.warning("Apify run skipped: no actor ID configured for this source")
        return []
```

### 5.5 Per-query caps, spend caps, throttles

| Control | Value | Configured in |
|---|---|---|
| LinkedIn results per role×location call | `10` (actor floor; `LINKEDIN_MIN_COUNT = 10`) | `config.py:135` `apify_linkedin_max_results` |
| Indeed results per call | `5` | `config.py:136` |
| Naukri results per call | `8` | `config.py:137` |
| Internshala results per call | `10` | `config.py:199` `internshala_max_results` |
| Unstop results per role search | `20` | `config.py:200` `unstop_max_results` |
| Apify concurrent runs | `3` (asyncio.Semaphore, `job_ingestion.py:431`) | `config.py:176` `apify_max_concurrent_runs` |
| LinkedIn cadence | `mon,wed,fri` | `config.py:131` |
| Indeed cadence | `mon,thu` | `config.py:132` |
| Naukri cadence | `mon` | `config.py:133` |
| Internshala cadence | `tue,fri` | `config.py:198` |
| Unstop cadence | none — runs every cron day when enabled | `job_ingestion.py::refresh_unstop` |
| Adzuna results per query | `20` (`results_per_page`) | hardcoded, `job_sources.py:154` |
| JSearch results | `page=1, num_pages=1` | hardcoded, `job_sources.py:199-200` |
| Job freshness cap | `10` days | `config.py:64` `max_job_age_days` |
| Naukri actor timeout | `280` s with `fetchDetails`, else `120` s | `job_sources.py:471` |
| Apify default actor timeout | `120` s | `apify_client.py:26` |
| **Dollar spend cap** | **NOT FOUND in code.** The `$5/month` Apify free-plan ceiling is enforced by Apify, and `MANUAL_STEPS.md:120` lists "Confirm the Apify spend cap" as an **unchecked** manual step. The `.env.example` and `config.py` budget math (~$4.33/mo) is a comment, not a runtime check. |

---

## Section 6 — Config

### 6.1 `Settings` fields (`server/config.py`)

| Field | Type | Default |
|---|---|---|
| `gemini_api_key` | `str` | *(required — no default)* |
| `gemini_model` | `str` | `"gemini-2.5-flash"` |
| `gemini_embed_model` | `str` | `"gemini-embedding-001"` |
| `gemini_model_lite` | `str` | `"gemini-3.1-flash-lite"` |
| `deepseek_api_key` | `str` | `""` |
| `deepseek_model` | `str` | `"deepseek-v4-flash"` |
| `deepseek_base_url` | `str` | `"https://api.deepseek.com"` |
| `tailor_provider` | `str` | `"gemini"` |
| `supabase_url` | `str` | *(required)* |
| `supabase_service_key` | `str` | *(required)* |
| `supabase_anon_key` | `str` | `""` |
| `adzuna_app_id` | `str` | `""` |
| `adzuna_app_key` | `str` | `""` |
| `adzuna_country` | `str` | `"in"` |
| `rapidapi_key` | `str` | `""` |
| `fcm_service_account_path` | `str` | `"./firebase-service-account.json"` |
| `resend_api_key` | `str` | `""` |
| `resend_from_email` | `str` | `"onboarding@resend.dev"` |
| `max_job_age_days` | `int` | `10` |
| `daily_pipeline_hour` | `int` | `7` |
| `target_roles` | `str` | `""` |
| `target_locations` | `str` | `""` |
| `adzuna_locations` | `str` | `""` |
| `environment` | `str` | `"development"` |
| `greenhouse_boards` | `str` | `"postman,groww,razorpaysoftwareprivatelimited:Razorpay,phonepe"` |
| `lever_companies` | `str` | `"cred:CRED,meesho:Meesho,zeta:Zeta,freshworks:Freshworks"` |
| `apify_api_token` | `str` | `""` |
| `apify_linkedin_actor_id` | `str` | `""` |
| `apify_indeed_actor_id` | `str` | `""` |
| `apify_naukri_actor_id` | `str` | `""` |
| `apify_linkedin_weekdays` | `str` | `"mon,wed,fri"` |
| `apify_indeed_weekdays` | `str` | `"mon,thu"` |
| `apify_naukri_weekdays` | `str` | `"mon"` |
| `apify_linkedin_max_results` | `int` | `10` |
| `apify_indeed_max_results` | `int` | `5` |
| `apify_naukri_max_results` | `int` | `8` |
| `apify_linkedin_query_suffix` | `str` | `"intern"` |
| `apify_indeed_query_suffix` | `str` | `"intern"` |
| `apify_naukri_max_experience_years` | `int` | `2` |
| `apify_max_concurrent_runs` | `int` | `3` |
| `apify_naukri_fetch_details` | `bool` | `True` |
| `enable_india_sources` | `bool` | `False` |
| `apify_internshala_actor_id` | `str` | `""` |
| `apify_internshala_weekdays` | `str` | `"tue,fri"` |
| `internshala_max_results` | `int` | `10` |
| `unstop_max_results` | `int` | `20` |
| `ops_alert_email` | `str` | `""` |
| `pipeline_secret` | `str` | `""` |
| `pipeline_oidc_service_account` | `str` | `""` |
| `pipeline_oidc_audience` | `str` | `""` |
| `rate_limit_window_seconds` | `int` | `300` |
| `rate_limit_rerank` | `int` | `5` |
| `rate_limit_tailor` | `int` | `5` |
| `rate_limit_pipeline_mine` | `int` | `5` |
| `rate_limit_resume_parse` | `int` | `3` |
| `rate_limit_manual_parse` | `int` | `5` |
| `rate_limit_jobs_refresh` | `int` | `10` |

`model_config = SettingsConfigDict(env_file=".env")`.

### 6.2 `.env.example` variable names, in file order and grouping

**Google Gemini:** `GEMINI_API_KEY`, `GEMINI_MODEL`, `GEMINI_EMBED_MODEL`
**DeepSeek (ADR-023):** `DEEPSEEK_API_KEY`, `DEEPSEEK_MODEL`, `DEEPSEEK_BASE_URL`, `TAILOR_PROVIDER`
**Supabase:** `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `SUPABASE_ANON_KEY`
**Adzuna:** `ADZUNA_APP_ID`, `ADZUNA_APP_KEY`, `ADZUNA_COUNTRY`
**JSearch via RapidAPI:** `RAPIDAPI_KEY`
**Apify (LinkedIn/Indeed/Naukri):** `APIFY_API_TOKEN`, `APIFY_LINKEDIN_ACTOR_ID`, `APIFY_INDEED_ACTOR_ID`, `APIFY_NAUKRI_ACTOR_ID`, `APIFY_LINKEDIN_WEEKDAYS`, `APIFY_INDEED_WEEKDAYS`, `APIFY_NAUKRI_WEEKDAYS`, `APIFY_LINKEDIN_MAX_RESULTS`, `APIFY_INDEED_MAX_RESULTS`, `APIFY_NAUKRI_MAX_RESULTS`, `APIFY_MAX_CONCURRENT_RUNS`
**India source expansion (gated):** `ENABLE_INDIA_SOURCES`, `APIFY_INTERNSHALA_ACTOR_ID`, `APIFY_INTERNSHALA_WEEKDAYS`, `INTERNSHALA_MAX_RESULTS`, `UNSTOP_MAX_RESULTS`
**Ingestion health alerting:** `OPS_ALERT_EMAIL`
**Firebase Cloud Messaging:** `FCM_SERVICE_ACCOUNT_PATH`
**Resend:** `RESEND_API_KEY`, `RESEND_FROM_EMAIL`
**App config:** `DAILY_PIPELINE_HOUR`, `TARGET_ROLES`, `TARGET_LOCATIONS`, `ADZUNA_LOCATIONS`, `ENVIRONMENT`
**Pipeline cron auth:** `PIPELINE_SECRET`
**Job freshness:** `MAX_JOB_AGE_DAYS`
**Lite Gemini tier (commented out):** `GEMINI_MODEL_LITE`

**Present in `Settings` but absent from `.env.example`:** `GREENHOUSE_BOARDS`,
`LEVER_COMPANIES`, `APIFY_LINKEDIN_QUERY_SUFFIX`, `APIFY_INDEED_QUERY_SUFFIX`,
`APIFY_NAUKRI_MAX_EXPERIENCE_YEARS`, `APIFY_NAUKRI_FETCH_DETAILS`,
`PIPELINE_OIDC_SERVICE_ACCOUNT`, `PIPELINE_OIDC_AUDIENCE`, and all seven
`RATE_LIMIT_*` variables.

---

## Section 7 — Flutter app inventory

### 7.1 `app/lib/` tree (two levels)

```
app/lib
├── config/
├── models/
├── screens/
├── services/
├── theme/
├── widgets/
├── firebase_options.dart
└── main.dart
```

No sub-subdirectories exist — every directory is flat.

### 7.2 `screens/` — 27 files

| File | Purpose |
|---|---|
| `activity_log_screen.dart` | "What the agent did on your behalf" feed. |
| `add_job_screen.dart` | Paste a posting URL → server extracts → review/edit → add to pool. |
| `app_detail_screen.dart` | Application detail; replaces the old stage-picker bottom sheet. |
| `applications_body.dart` | Track tab body — horizontally-scrolling Kanban board. |
| `auth_gate.dart` | Root below `JobHuntAgentApp`; three top-level states (no session / onboarding / main). |
| `auth_screen.dart` | Email+password and Google OAuth sign-in. |
| `cost_stats_screen.dart` | This month's LLM spend by task and by provider. |
| `form_fill_screen.dart` | Paste a form URL → parse → map profile → prefill URL. |
| `home_body.dart` | Home tab body — greeting, new-matches stat, recent activity. |
| `jd_resume_screen.dart` | JD-paste resume builder (text or PDF). |
| `jobs_list_body.dart` | Jobs tab body + bookmark toggle + entry points to Add Job / JD builder / Form fill. |
| `main_tab_screen.dart` | Signed-in shell: one `AppShell` with a 5-tab bottom nav over an `IndexedStack`. |
| `matches_body.dart` | Matches tab body — two-stage RAG results. |
| `matching_loading_screen.dart` | Transitional screen between target-roles submit and the main shell. |
| `onboarding_flow.dart` | Onboarding steps as an enum mirroring `profiles.onboarding_step`. |
| `profile_body.dart` | Profile tab body — account home, resume re-edit, links to cost stats / skill growth / settings. |
| `profile_review_screen.dart` | Edit the parsed resume profile (per-item controller bundles). |
| `resume_diff_screen.dart` | Bullet-by-bullet tailored-vs-original diff with guardrail flags. |
| `resume_preview_screen.dart` | Compiled tailored-resume preview + PDF share. |
| `resume_upload_screen.dart` | PDF picker + upload (not skippable during onboarding). |
| `settings_screen.dart` | Notification prefs only (the prototype's "Agent" group deliberately dropped). |
| `shortlist_screen.dart` | Saved-state applications, filtered client-side. |
| `skill_growth_screen.dart` | Skills-to-learn from real match gaps. |
| `splash_screen.dart` | Animated brand cover before a session exists. |
| `student_info_screen.dart` | student/experienced + USN + college onboarding step. |
| `target_roles_screen.dart` | "What are you looking for?" — target roles + min salary. |
| `welcome_screen.dart` | Shown once right after first sign-in. |

### 7.3 `widgets/` — 24 files

| File | Purpose |
|---|---|
| `activity_log_item.dart` | One activity entry with a timeline rail. |
| `activity_style.dart` | Icon + color map for an `ActivityItem`. |
| `app_banner.dart` | Inline tone-colored contextual message with optional action/dismiss. |
| `app_form_field.dart` | Labeled text input with hint + error states. |
| `app_icon.dart` | Maps design-system icon names onto Material glyphs. |
| `app_loader.dart` | Three ascending bars echoing the launcher icon. |
| `app_shell.dart` | Portrait app frame: optional app bar + scrollable content + bottom nav. |
| `application_card.dart` | Compact card for a Kanban lane. |
| `background_task_dialog.dart` | Informational "this runs in the background" dialog. |
| `brand_mark.dart` | The FirstRole staircase mark. |
| `chip_input.dart` | Token/tag input for target roles. |
| `diff_row.dart` | One original-vs-tailored bullet pair. |
| `empty_state.dart` | Shared zero-data pattern. |
| `job_card.dart` | Base job card (logo, title, company, location, source chip). |
| `kanban_column.dart` | One pipeline lane with stage pill + count. |
| `loading_skeleton.dart` | Shimmer primitive driven by one shared ticker. |
| `match_card.dart` | `JobCard` + score ring + verdict pill + strength/gap chips. |
| `page_header.dart` | The one header every screen uses instead of an AppBar. |
| `page_skeletons.dart` | Structure-matched skeletons, one per screen shape. |
| `score_ring.dart` | Circular match-score gauge (≥75 apply / ≥50 stretch / <50 skip). |
| `similarity_bar.dart` | Horizontal 0–100 bar. |
| `stale_banner.dart` | "Showing saved data · last updated 2h ago" + Retry. |
| `status_pill.dart` | One pill, three semantic contexts (verdict / guardrail / stage). |
| `task_toast.dart` | Global `ScaffoldMessenger` key for background-task completion toasts. |

### 7.4 `models/` — 13 files

| File | Purpose |
|---|---|
| `activity_item.dart` | One row from `GET /stats/activity`. |
| `application_item.dart` | One row from `GET /applications` (job + Kanban state). |
| `background_task.dart` | Mirrors a `background_tasks` row. |
| `cost_stats.dart` | `GET /stats/costs` — includes `CostProviderItem` / `byProvider`. |
| `form_fill.dart` | Mirrors `server/models/form.py`. |
| `health_status.dart` | `GET /health` shape. |
| `job.dart` | Mirrors the `jobs` table; owns `salaryLabel` / `postedAtLabel`. |
| `job_extraction.dart` | `POST /jobs/manual/parse` response. |
| `match_item.dart` | One row from `GET /matches` (both RAG stages). |
| `resume_profile.dart` | Mirrors `server/models/resume.py`; has `toJson` for PATCH. |
| `shortlist_item.dart` | One row from `GET /matches/shortlist`. |
| `skill_growth_item.dart` | One entry from `GET /stats/skill-growth`. |
| `tailored_resume.dart` | One bullet from `tailored_resumes.bullets`. |

### 7.5 `services/` — 6 files

| File | Purpose |
|---|---|
| `api_client.dart` | The single place that knows the server base URL; every screen goes through it. |
| `cache_service.dart` | Stale-while-revalidate cache over `SharedPreferences`, namespaced by user id. |
| `match_feed.dart` | Single source of truth for the ranked-matches list (shared by Home + Matches). |
| `push_service.dart` | Firebase init, permission request, FCM token registration. |
| `refresh_throttle.dart` | `RefreshThrottle` pull-to-refresh debouncer + `lastUpdatedLabel`. |
| `task_center.dart` | Tracks in-flight background tasks and fires completion toasts. |

### 7.6 `theme/` and `config/`

| File | Purpose |
|---|---|
| `theme/app_tokens.dart` | Design tokens translated 1:1 from the design system's `tokens/*.css`. |
| `theme/app_theme.dart` | Assembles `ThemeData` from `AppTokens`. |
| `config/supabase_config.dart` | Supabase project URL + anon key for client-side auth only. |

### 7.7 `pubspec.yaml` dependencies

**`environment: sdk: ^3.11.5`**

| Dependency | Constraint |
|---|---|
| `flutter` | sdk |
| `cupertino_icons` | `^1.0.8` |
| `http` | `^1.6.0` |
| `file_picker` | `^11.0.2` |
| `http_parser` | `^4.1.2` |
| `google_fonts` | `^6.2.1` |
| `firebase_core` | `^3.6.0` |
| `firebase_messaging` | `^15.1.3` |
| `supabase_flutter` | `^2.8.0` |
| `url_launcher` | `^6.3.0` |
| `share_plus` | `^10.1.0` |
| `path_provider` | `^2.1.4` |
| `shared_preferences` | `^2.3.2` |

| Dev dependency | Constraint |
|---|---|
| `flutter_test` | sdk |
| `flutter_lints` | `^6.0.0` |
| `flutter_launcher_icons` | `^0.14.3` |

### 7.8 State management

**NOT FOUND.** Grepping `lib/` and `pubspec.yaml` for `riverpod`, `flutter_bloc`,
`get_it`, `getx`, `provider` (as a package) returns zero package matches — every
hit is either `path_provider`, `SingleTickerProviderStateMixin`, `OAuthProvider`,
or an LLM-*provider* domain field. State is plain `StatefulWidget` + `setState`,
with two hand-rolled singletons (`MatchFeed`, `TaskCenter`) for cross-screen
sharing.

### 7.9 Routing

**No routing package.** `go_router` and `auto_route` are `NOT FOUND` in
`pubspec.yaml` and in `lib/`. Navigation is 30 imperative
`Navigator.of(context).push(MaterialPageRoute(...))` calls spread across 12
screens. `MaterialApp` declares no `routes:` map and no `onGenerateRoute:` —
only `home: const AuthGate()`.

### 7.10 Theme — is there a dark theme?

**No.** `app_theme.dart` exposes exactly one getter, `AppTheme.light`, and the
only `Brightness` reference in the whole `theme/` directory is
`brightness: Brightness.light` at `app_theme.dart:19`. `MaterialApp` sets no
`darkTheme` and no `themeMode`.

`MaterialApp` configuration verbatim (`app/lib/main.dart:41-50`):

```dart
    return MaterialApp(
      title: 'FirstRole',
      theme: AppTheme.light,
      // Phase 2: TaskCenter's completion toasts fire through this global
      // key so they show on whatever screen/tab the user is on when a
      // background task finishes.
      scaffoldMessengerKey: appScaffoldMessengerKey,
      home: const AuthGate(),
    );
```

### 7.11 `api_client.dart` base URL

**Cloud Run, not Render.** Verbatim (`app/lib/services/api_client.dart:34-38`):

```dart
  static String get _baseUrl {
    const override = String.fromEnvironment('API_BASE_URL');
    if (override.isNotEmpty) return override;
    return 'https://jobhunt-agent-server-380742808186.asia-south1.run.app';
  }
```

The `--dart-define` override key is `API_BASE_URL`.

### 7.12 Timeouts longer than 60 seconds

| Method | Timeout | Line |
|---|---|---|
| `refreshJobs` | `Duration(seconds: 120)` | `api_client.dart:208` |
| `fillForm` | `Duration(seconds: 90)` | `api_client.dart:721` |
| `fetchSkillGrowth` | `Duration(minutes: 3)` | `api_client.dart:675` |

(For completeness, exactly-60s: `rerankShortlist`, `getTaskStatus`,
`tailorResume`, `runPipeline`, `parseForm`, `downloadResumePdf`. Under 60s:
`parseManualJobUrl` and `parseJd` at 45s, `draftFollowup` and `sendFollowup`
at 30s. Every other method has **no `.timeout()` at all.**)

### 7.13 `shared_preferences`

It is a **runtime dependency**, not a dev dependency (`pubspec.yaml:52`, with an
explicit comment that it "was wrongly in dev_dependencies"). It is used in
exactly one file: `services/cache_service.dart` (imported at line 3, called at
lines 56, 83, 102, 112).

### 7.14 Client-side caching and refresh throttling

Both exist.

- **Caching:** `services/cache_service.dart` — stale-while-revalidate over
  `SharedPreferences`. `CacheEntry.staleAfter = Duration(hours: 24)`. Keys:
  `profile`, `matches`, `jobs`, `applications`, `cost_stats`, `activity`, each
  namespaced `<userId>:<key>`, with a `clearForUser` wipe on sign-out.
- **Throttling:** `services/refresh_throttle.dart` (ADR-028) —
  `RefreshThrottle(cooldown: Duration(seconds: 3))` debounces pull-to-refresh,
  plus `lastUpdatedLabel()` for surfacing cache age.
- `widgets/stale_banner.dart` renders the "Showing saved data" fallback.

### 7.15 Haptic feedback

**NOT FOUND.** Grepping `lib/` for `HapticFeedback` and `vibrate` returns zero
matches. There is no haptic feedback anywhere in the app.

---

## Section 8 — Deployment

### 8.1 Cloud Run or Render?

**Cloud Run.** Evidence, in order of directness:

1. `app/lib/services/api_client.dart:37` returns
   `https://jobhunt-agent-server-380742808186.asia-south1.run.app` — a
   `*.run.app` Cloud Run URL — as the shipped default.
2. `DECISIONS.md` ADR-014 "Migrated Render → Google Cloud Run" documents the
   move: project `jobhunteragent-502002`, region `asia-south1`, same Dockerfile.
3. `server/services/auth.py::_verify_scheduler_oidc` implements Google-signed
   OIDC verification for the cron endpoint — the Cloud Scheduler path.
4. `MANUAL_STEPS.md:97-117` records `gcloud run services update jobhunt-agent-server --region=asia-south1` and `gcloud secrets add-iam-policy-binding`.
5. `server/Dockerfile` is host-agnostic: `python:3.11-slim` + `poppler-utils` +
   `uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000}`.

**Render is not fully decommissioned in code.** `settings.pipeline_secret` and
the `X-Pipeline-Secret` branch of `verify_pipeline_cron` are still live, and
ADR-014 states Render itself "is still live — not paused or deleted."
`MANUAL_STEPS.md` §3 is still titled "Render."

### 8.2 Infrastructure-as-code

**NOT FOUND.** No `cloudbuild.yaml`, no `service.yaml`, no `*.tf`, no
`render.yaml`, no `Procfile`, no `app.yaml`, no deploy script of any kind. The
only deployment artifact in the repo is `server/Dockerfile` (14 lines) and
`server/.dockerignore`. Deployment is the manual `gcloud` commands recorded in
`MANUAL_STEPS.md`.

### 8.3 Daily cron

- **Endpoint:** `POST /pipeline/run`, guarded by
  `services/auth.py::verify_pipeline_cron`.
- **Two accepted credentials:** the `X-Pipeline-Secret` header matching
  `settings.pipeline_secret` (the legacy Render cron), **or** a Google-signed
  OIDC bearer token verified against `settings.pipeline_oidc_audience` and
  `settings.pipeline_oidc_service_account`.
- **Where it is configured:** **outside this repo.** ADR-014 names a Cloud
  Scheduler job authenticating as
  `pipeline-scheduler@jobhunteragent-502002.iam.gserviceaccount.com`. There is no
  scheduler definition file in the repo. `settings.daily_pipeline_hour` (default
  `7`) exists in `config.py` but **is never read by any code** — it is
  documentation of schedule *intent*, not the schedule itself.

### 8.4 Production secrets

Per ADR-014: Google Secret Manager, mounted as env vars on the Cloud Run
service — `GEMINI_API_KEY`, `SUPABASE_SERVICE_KEY`, `SUPABASE_ANON_KEY`,
`ADZUNA_APP_KEY`, `RAPIDAPI_KEY`, `PIPELINE_SECRET`, `FCM_SERVICE_ACCOUNT_JSON`,
plus `DEEPSEEK_API_KEY` (`MANUAL_STEPS.md:46`) and `APIFY_API_TOKEN`
(`MANUAL_STEPS.md:97`). Non-secret config goes in as plain env vars via
`--env-vars-file`. Locally, `config.py` loads `server/.env`.

**Note:** `MANUAL_STEPS.md:105-117` records one **unchecked** step — granting the
runtime service account `secretmanager.secretAccessor` on `APIFY_API_TOKEN` and
attaching it. If that is still true, the Apify sources no-op in production.

### 8.5 Android release signing

**Not the debug keystore.** A real upload key is wired in, and release builds
hard-fail without it. Verbatim (`app/android/app/build.gradle.kts:22-28, 55-81`):

```kotlin
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}
val hasUploadKey = keystorePropertiesFile.exists()
```

```kotlin
    signingConfigs {
        if (hasUploadKey) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storePassword = keystoreProperties.getProperty("storePassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
            }
        }
    }

    buildTypes {
        release {
            if (hasUploadKey) {
                signingConfig = signingConfigs.getByName("release")
            }
            // R8: strip unused code and resources, and obfuscate. Flutter, Firebase
            // and the plugins ship their own consumer ProGuard rules; proguard-rules.pro
            // holds only what those don't cover.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
```

plus the hard failure (`build.gradle.kts:86-94`):

```kotlin
gradle.taskGraph.whenReady {
    val buildingRelease = allTasks.any { it.name.contains("Release") }
    if (buildingRelease && !hasUploadKey) {
        throw GradleException(
            "Release build requested but android/key.properties is missing. " +
                "Restore it from your password manager (see docs/PLAY_CONSOLE.md).",
        )
    }
}
```

`app/android/key.properties` is present in the working tree (untracked by git —
it is gitignored, and `git status` is clean).

### 8.6 CI configuration

**NOT FOUND.** There is no `.github/` directory at all, and no CI configuration
of any kind (no GitLab CI, CircleCI, Jenkins, or Codemagic file).

---

## Section 9 — Tests

### 9.1 Python — `server/tests/` (23 files, plus `server/conftest.py`)

| File | Lines | Covers |
|---|---|---|
| `test_activity.py` | 58 | `build_activity_feed` merge/ordering. |
| `test_apify_client.py` | 135 | `run_actor` failure modes (no token, no actor, non-2xx, timeout, non-JSON, non-list). |
| `test_background_tasks.py` | 81 | `create_task`/`get_task`/`run_task` state transitions. |
| `test_cost_stats.py` | 87 | Pricing, task + provider breakdowns, pct math. |
| `test_dedup.py` | 56 | `make_dedup_key`, `is_duplicate` fuzzy threshold. |
| `test_deepseek_provider.py` | 215 | Provider routing, thinking-disabled param, Gemini fallback, image rejection. |
| `test_embeddings.py` | 33 | Batching + embedding-text builders. |
| `test_form_parser.py` | 162 | Google Forms parse, choice guardrail, prefill URL, answer history. |
| `test_guardrail.py` | 91 | `verify_bullets`, `verify_skills`, `compute_gaps`. |
| `test_ingestion_health.py` | 261 | `evaluate_ingestion_health` thresholds, alert formatting, trailing averages. |
| `test_job_filter.py` | 119 | Role/seniority/city/remote gates. |
| `test_job_freshness.py` | 33 | `is_fresh` boundaries. |
| `test_job_sources.py` | 123 | Adzuna/JSearch/Greenhouse/Lever mapping. |
| `test_job_sources_apify.py` | 416 | LinkedIn/Indeed/Naukri mapping + city canonicalization. |
| `test_matching.py` | 132 | Pre-screen, batching, final score, verdict thresholds. |
| `test_pdf_safety.py` | 97 | Magic bytes, size, page count, render timeout. |
| `test_rate_limit.py` | 141 | Window counting, off-by-one, prune, both key flavors. |
| `test_request_validation.py` | 73 | `StrictModel` extra-field rejection + length caps. |
| `test_resume_pdf.py` | 115 | Bullet compilation, layout selection, one-page fit. |
| `test_salary.py` | 111 | Free-text parsing + annualization + `infer_currency`. |
| `test_scraped_sources.py` | 282 | Cadence gating, concurrency, token kill switch, per-source counts. |
| `test_ssrf.py` | 70 | `_assert_public_url` on private/loopback/link-local/redirect chains. |
| `test_unstop.py` | 303 | Unstop row mapping, `approved_date` parsing, stipend annualization, WAF-shape defenses. |

**`pytest` result (raw summary line):**

```
314 passed, 1 warning in 11.79s
```

(One `DeprecationWarning` from `google/genai/types.py` about `_UnionGenericAlias`.)

### 9.2 Dart — `app/test/` (2 files)

| File | Covers |
|---|---|
| `job_model_test.dart` | `Job.salaryLabel` (currency symbols, unknown/missing currency, no salary) and `Job.postedAtLabel` (relative dates, the 2591d implausible-age case, missing date). |
| `widget_test.dart` | Splash renders with no session; splash → auth navigation; jobs-list skeletons before load. |

**`flutter analyze` result (raw summary lines):**

```
   info • 'anonKey' is deprecated and shouldn't be used. Use publishableKey instead. anonKey will be removed in a future major version • lib/main.dart:17:54 • deprecated_member_use
   info • 'anonKey' is deprecated and shouldn't be used. Use publishableKey instead. anonKey will be removed in a future major version • test/widget_test.dart:19:64 • deprecated_member_use

2 issues found. (ran in 3.6s)
```

**`flutter test` result (raw summary line):**

```
00:01 +12: All tests passed!
```

Nothing was fixed. There are **no widget tests for any of the other 25 screens**,
and **no tests for `api_client.dart`, `cache_service.dart`, `refresh_throttle.dart`,
`match_feed.dart`, or `task_center.dart`.**

---

## Section 10 — Documentation drift

### 10.1 ADR index

| # | Title | Date (as stated in `DECISIONS.md`) |
|---|---|---|
| 001 | Two-stage RAG matching (embeddings filter → LLM re-rank) | project start |
| 002 | pgvector inside Supabase instead of a dedicated vector DB | project start |
| 003 | Job APIs + scoped scraping via Apify | project start · amended 2026-07-13 · amended v2 2026-07-20 |
| 004 | Anti-fabrication guardrail with deterministic post-check | project start |
| 005 | Switched from gemini-2.0-flash to gemini-2.5-flash | 2026-07-08 |
| 006 | Switched from text-embedding-004 to gemini-embedding-001 | 2026-07-09 |
| 007 | Stubbed FCM push, cron via Render, manual `/pipeline/run` trigger | 2026-07-09 |
| 008 | Supabase Auth (Google OAuth) for multi-tenancy, service-role scoping over RLS enforcement | 2026-07-09 |
| 009 | Frontend rebuild from the design-system prototype, phased execution | 2026-07-10 |
| 010 | Render deployment + first working APK build | **no `**Date:**` line** |
| 011 | Async background-task pattern for long LLM endpoints (202 + poll) | **no `**Date:**` line** |
| 012 | ATS resume PDF via ReportLab (deterministic, server-side) | **no `**Date:**` line** |
| 013 | Form autofill = prefill URL + human submit, deterministic Google Forms parse | **no `**Date:**` line** |
| 014 | Migrated Render → Google Cloud Run | **no `**Date:**` line** |
| 015 | Bug batch — job-match relevance, tailoring concurrency, stale OAuth fallback | **no `**Date:**` line** |
| 016 | Onboarding — student/experienced + USN/college; form-fill answer reuse | **no `**Date:**` line** |
| 017 | JD-paste resume builder — a standalone entry point into the existing tailoring pipeline | **no `**Date:**` line** |
| 018 | Job source expansion — Adzuna India-tuning + Greenhouse/Lever fetchers | **no `**Date:**` line** |
| 019 | Resume tailoring framework — JD analysis, layout selection, gap disclosure | **no `**Date:**` line** |
| 020 | Gemini thinking disabled on every task — the invisible majority of the bill | **no `**Date:**` line** |
| 021 | Batched, role-aware re-ranking — cost and match quality had the same root cause | **no `**Date:**` line** |
| 022 | The tailored-resume PDF bug was a stale deploy, not a code bug | **no `**Date:**` line** |
| 023 | DeepSeek as a second provider — one validate/retry/log flow, per-task routing, thinking disabled | **no `**Date:**` line** |
| 024 | Input validation hardening — SSRF, length caps, strict request models | **no `**Date:**` line** |
| 025 | Prompt injection stays a documented residual risk, not a solved problem | **no `**Date:**` line** |
| 026 | PDF upload safety — resource bounds, and poppler does NOT execute embedded JS (measured) | **no `**Date:**` line** |
| 027 | Postgres-backed rate limiting, not in-memory | **no `**Date:**` line** |
| 028 | Client-side refresh throttling — extend the SWR cache, don't add a second one | **no `**Date:**` line** |
| 029 | The app ships as "FirstRole", not "JobHunt Agent" | 2026-07-14 |
| 030 | Release signing, R8, and why the release build is verified on-device | 2026-07-14 |
| 031 | The OAuth deep-link scheme must not match applicationId | 2026-07-14 |
| 032 | Duplicate signups fail silently unless you check `identities` | 2026-07-14 |

**Structural finding: ADRs 010 through 028 (19 consecutive entries) carry no
`**Date:**` line at all**, breaking the format every other ADR follows.

### 10.2 Documentation contradicting the code

Each pair is quoted verbatim on both sides. No attempt is made to resolve them.

---

**Drift 1 — Hosting provider (CLAUDE.md)**

> Doc — `CLAUDE.md:40`:
> `- **Hosting:** Render (web service + cron job)`

> Code — `app/lib/services/api_client.dart:37`:
> `    return 'https://jobhunt-agent-server-380742808186.asia-south1.run.app';`

---

**Drift 2 — Hosting provider (project-knowledge pack)**

> Doc — `docs/claude-project-knowledge/12-deployment-and-infra.md:3-5`:
> `## Backend hosting — Render`
> `- Service: jobhunt-agent-server (free plan, Singapore region), deployed from **server/Dockerfile**...`
>
> and `:17`:
> `- Live base URL, also the Flutter app's default: https://jobhunt-agent-server.onrender.com.`

> Code — `app/lib/services/api_client.dart:37` (above), and
> `server/services/auth.py:62-74`, which implements Cloud Scheduler OIDC verification:
> `def _verify_scheduler_oidc(authorization: str | None) -> bool:`

---

**Drift 3 — Hosting provider (architecture doc)**

> Doc — `docs/claude-project-knowledge/01-architecture-and-tech-stack.md:58`:
> `| Hosting | Render | Web service (Dockerfile-based, ...) + a cron-triggered pipeline endpoint. No render.yaml ... |`
>
> and `:31`:
> `│   ├── jobs/daily_pipeline.py  ← the agent loop, triggered by Render cron`

> Code — `DECISIONS.md` ADR-014 title: `## ADR-014: Migrated Render → Google Cloud Run`, and `MANUAL_STEPS.md:115`:
> `gcloud run services update jobhunt-agent-server --region=asia-south1 \`

---

**Drift 4 — Cron trigger mechanism**

> Doc — `docs/claude-project-knowledge/12-deployment-and-infra.md:18-20`:
> `- A cron job (external to the repo, configured in Render) hits POST`
> `  /pipeline/run on a schedule, authenticated via the X-Pipeline-Secret`
> `  header`

> Code — `server/services/auth.py:55-59`:
> ```python
>     if settings.pipeline_secret and x_pipeline_secret == settings.pipeline_secret:
>         return
>     if _verify_scheduler_oidc(authorization):
>         return
>     raise HTTPException(status_code=401, detail="Invalid or missing pipeline credentials")
> ```

---

**Drift 5 — Embedding model (BRICKS.md)**

> Doc — `docs/BRICKS.md:67`:
> `1. server/services/embeddings.py: embed_text() using text-embedding-004,`

> Code — `server/config.py:7`:
> `    gemini_embed_model: str = "gemini-embedding-001"`
>
> and `server/services/embeddings.py:51`:
> `            config=types.EmbedContentConfig(task_type="SEMANTIC_SIMILARITY", output_dimensionality=768),`

---

**Drift 6 — Embedding model + generation model (CLAUDE_PROJECT_SETUP.md)**

> Doc — `docs/CLAUDE_PROJECT_SETUP.md:63`:
> `  (gemini-2.0-flash + text-embedding-004) + Supabase Postgres with pgvector.`

> Code — `server/config.py:6-7`:
> ```python
>     gemini_model: str = "gemini-2.5-flash"
>     gemini_embed_model: str = "gemini-embedding-001"
> ```

---

**Drift 7 — LLM provider (architecture doc: Gemini named as the only provider)**

> Doc — `docs/claude-project-knowledge/01-architecture-and-tech-stack.md:52`:
> `| LLM (generation) | Google Gemini gemini-2.5-flash | All text/vision generation tasks — resume parsing, re-ranking, tailoring, follow-up drafts, job extraction, skill-growth clustering. |`

> Code — `server/services/llm.py:299-307`:
> ```python
> _TASK_PROVIDERS: dict[str, str] = {
>     "parse": GEMINI,  # vision-required — DeepSeek is text-only
>     "rerank": DEEPSEEK,
>     "extract_job": DEEPSEEK,
>     "followup": DEEPSEEK,
>     "skill_growth": DEEPSEEK,
>     "extract_form": DEEPSEEK,
>     "form_fill": DEEPSEEK,
> }
> ```

---

**Drift 8 — LLM provider (03-llm-and-prompts.md)**

> Doc — `docs/claude-project-knowledge/03-llm-and-prompts.md:7`:
> `| All generative tasks (text + vision) | gemini-2.5-flash | Settings.gemini_model, server/config.py — read from config, never hardcoded in a prompt function |`

> Code — same `_TASK_PROVIDERS` block as Drift 7.

---

**Drift 9 — Pricing table (03-llm-and-prompts.md)**

> Doc — `docs/claude-project-knowledge/03-llm-and-prompts.md:89`:
> `- _PRICING_PER_MILLION_TOKENS = {"gemini-2.5-flash": (0.30, 2.50), "gemini-embedding-001": (0.15, 0.0)}` (USD per 1M tokens, in/out), with a fallback rate for unknown models.`

> Code — `server/services/cost_stats.py:19-28` has **seven** entries, including
> `"gemini-2.5-flash-lite"`, `"gemini-3.1-flash-lite"`, `"deepseek-v4-flash"`,
> and `"deepseek-v4-pro"`.

---

**Drift 10 — Scraping policy (master prompt)**

> Doc — `docs/jobhunt-agent-master-prompt.md:12`:
> `6. No scraping of LinkedIn/Naukri/Indeed. Legal APIs and user-pasted content only.`

> Code — `server/services/job_sources.py:341-342`:
> ```python
> async def fetch_linkedin_apify(role: str, location: str, max_results: int) -> list[JobIn]:
>     """LinkedIn via curious_coder~linkedin-jobs-scraper (no-login, $0.001/result).
> ```

---

**Drift 11 — Scraping policy (CLAUDE_PROJECT_SETUP.md)**

> Doc — `docs/CLAUDE_PROJECT_SETUP.md:73`:
> `- No scraping, no auto-apply, no LangChain in v1, no Docker in v1,`

> Code — `server/services/job_sources.py:385-386` and `:439-440`:
> ```python
> async def fetch_indeed_apify(role: str, location: str, max_results: int) -> list[JobIn]:
>     """Indeed via misceres~indeed-scraper (no-login, $0.006/result ...
> ```
> ```python
> async def fetch_naukri_apify(role: str, location: str, max_results: int) -> list[JobIn]:
>     """Naukri via makework36~naukri-scraper (no-login).
> ```
> (Also `server/Dockerfile` exists, contradicting "no Docker in v1" in the same doc line.)

---

**Drift 12 — Scraping policy (decisions-log summary in the knowledge pack)**

> Doc — `docs/claude-project-knowledge/08-decisions-log.md:21`:
> `layer, legal APIs only, no scraping of LinkedIn/Indeed/Naukri, plus a manual`

> Code — three Apify fetchers plus `fetch_internshala_apify` and
> `fetch_unstop_internships` in `server/services/job_sources.py`.

---

**Drift 13 — Job-source list (CLAUDE.md omits Internshala and Unstop)**

> Doc — `CLAUDE.md:38`:
> `- **Jobs data:** Adzuna API (primary) + JSearch via RapidAPI (secondary) + Greenhouse/Lever public boards. Supplementary: LinkedIn/Indeed/Naukri via no-login **Apify** actors, daily-cron cadence only (ADR-003, amended 2026-07-13). No login-based scraping, ever.`

> Code — `server/services/job_sources.py` defines two further fetchers:
> `async def fetch_internshala_apify(role: str, location: str, max_results: int) -> list[JobIn]:` (`:542`)
> `async def fetch_unstop_internships(max_results: int) -> list[JobIn]:` (`:684`)

---

**Drift 14 — Job-source list (12-deployment-and-infra.md third-party table)**

> Doc — `docs/claude-project-knowledge/12-deployment-and-infra.md:58-65` lists six
> services (Gemini, Adzuna, JSearch, Resend, Supabase, Firebase) and no Apify,
> no DeepSeek, no Unstop.

> Code — `server/config.py:29` (`deepseek_api_key`), `:99` (`apify_api_token`),
> `server/services/job_sources.py:25` (`UNSTOP_SEARCH_URL`).

---

**Drift 15 — Android release signing**

> Doc — `docs/claude-project-knowledge/12-deployment-and-infra.md:82-83`:
> `- Release build uses the **debug signing config** — not production-ready for`
> `  Play Store submission yet (needs a real upload keystore).`
>
> and `docs/claude-project-knowledge/11-frontend-flutter-app.md:141`:
> `keystore — TODO: Add your own signing config for the release build — a real`

> Code — `app/android/app/build.gradle.kts:57-62`:
> ```kotlin
>             create("release") {
>                 keyAlias = keystoreProperties.getProperty("keyAlias")
>                 keyPassword = keystoreProperties.getProperty("keyPassword")
>                 storePassword = keystoreProperties.getProperty("storePassword")
>                 storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
>             }
> ```

---

**Drift 16 — FCM service account not provisioned**

> Doc — `docs/claude-project-knowledge/12-deployment-and-infra.md:50-54`:
> `- Server-side FCM uses firebase-admin with a service-account JSON, referenced`
> `  by path via FCM_SERVICE_ACCOUNT_PATH — this env var was **not** set on`
> `  Render as of the last deploy (ADR-010), so push currently degrades`
> `  gracefully to log-only on the live server until that file/secret is`
> `  provisioned there.`

> Code/doc — `DECISIONS.md` ADR-014 lists `FCM_SERVICE_ACCOUNT_JSON` among the
> secrets moved into Secret Manager, "closing the gap ADR-007/010 left open
> (FCM's service-account JSON was never uploaded to Render)."

---

**Drift 17 — `jobs_embedding_idx` still described as live**

> Doc — `docs/claude-project-knowledge/02-backend-api.md:110`:
> `| 001_core_schema.sql | Enables pgvector. Creates profiles, jobs (unique dedup_key, vector(768) embedding, ivfflat cosine index), ... |`
> (The same doc's migration table stops at `008`.)

> Code — `server/db/migrations/013_fix_job_embedding_relevance.sql:31`:
> `drop index if exists jobs_embedding_idx;`

---

**Drift 18 — Brick 10 checkbox**

> Doc — `CLAUDE.md:60`:
> `- [ ] Brick 10: Play Store launch + README + demo video`

> Code/repo — `docs/PLAY_CONSOLE.md` exists (262 lines), ADRs 029–032 all carry
> `**Brick:** 10`, the app is renamed to `FirstRole` in `app/pubspec.yaml:2`, and
> release signing is wired. **There is no `README.md` anywhere in the repo**
> (only `app/README.md`, the stock Flutter one, and
> `Job-Hunt Agent design system/readme.md`).

---

**Drift 19 — MANUAL_STEPS.md §3 still targets Render**

> Doc — `MANUAL_STEPS.md:162-167`:
> `## 3. Render`
> `- [ ] Push main to GitHub (git push) and confirm the`
> `      jobhunt-agent-server service redeploys (auto-deploy) or trigger a`
> `      manual deploy.`

> Code/doc — ADR-014 moved deployment to Cloud Run, where deploys are the manual
> `gcloud run deploy --source .` recorded at `MANUAL_STEPS.md:102`. A `git push`
> deploys nothing.

---

**Drift 20 — `MAX_JOB_AGE_DAYS` default**

> Doc — `MANUAL_STEPS.md:168-169`:
> `- [ ] No new env vars are required. Optional: MAX_JOB_AGE_DAYS (defaults`
> `      to 60 in code).`

> Code — `server/config.py:64`:
> `    max_job_age_days: int = 10`

---

**Drift 21 — `docs/PROMPTS.md` is the one doc that is current**

Recorded as a non-contradiction for completeness: `docs/PROMPTS.md:5` correctly
states the ADR-023 per-task provider split, and `:179-181` correctly names
`gemini-embedding-001` with an inline note that the old `text-embedding-004`
reference was stale. It matches the code.

---

## Section 11 — Open TODOs

Grep for `TODO`, `FIXME`, `HACK`, `XXX` across `*.py`, `*.dart`, `*.md`, `*.sql`,
`*.yaml`, `*.kts` (excluding `.git/` and the vendored design-system directory):

| File | Line | Text |
|---|---|---|
| `docs/claude-project-knowledge/11-frontend-flutter-app.md` | 141 | `keystore — `TODO: Add your own signing config for the release build` — a real` |
| `docs/PLAY_CONSOLE.md` | 46 | `| Phone screenshots (min 2) | **TODO — you must capture these** (§5) |` |
| `docs/claude-project-knowledge/09-status-and-roadmap.md` | 75 | `keystore (`TODO: Add your own signing config` in `build.gradle.kts`); a real` |

**Zero `TODO`/`FIXME`/`HACK`/`XXX` markers exist in any source file** — all three
hits are in documentation, and two of them quote a marker that **no longer exists
in `build.gradle.kts`** (see Drift 15).

---

## Things the auditor could not determine

1. **Whether any migration has actually been applied to the live Supabase
   database.** There is no migration runner and no applied-migrations table. The
   schema in Section 2 is reconstructed from files. `MANUAL_STEPS.md` shows
   `009`–`014` as **unchecked** and `016`/`017` as checked; `015` and `018`
   appear in no checklist at all. The real database state is unknown from the repo.

2. **Whether `DEEPSEEK_API_KEY` and `APIFY_API_TOKEN` are actually readable in
   production.** `MANUAL_STEPS.md:105` records the secret-accessor IAM binding
   for `APIFY_API_TOKEN` as the "⚠️ ONLY REMAINING STEP" and leaves it unchecked.
   If still true, all Apify sources silently no-op. This cannot be checked from
   the repo.

3. **The live values of `TARGET_ROLES`, `TARGET_LOCATIONS`, `ENABLE_INDIA_SOURCES`,
   and every actor ID.** They are env-driven, default to empty/false in
   `config.py`, and their production values live on the Cloud Run service.
   `server/.env` exists in the working tree but was deliberately not opened.

4. **Which Cloud Run revision is currently serving**, and therefore whether the
   code audited here is the code running. ADR-022 documents a past incident where
   a stale revision was mistaken for a code bug.

5. **The Cloud Scheduler cron schedule** (frequency, time of day, timezone). It
   is configured outside the repo and no file records it.
   `settings.daily_pipeline_hour = 7` exists but is read by no code.

6. **Whether Render is still live.** ADR-014 says it is ("not paused or deleted"),
   and `settings.pipeline_secret` plus the `X-Pipeline-Secret` code path still
   exist — but current hosting status is external to the repo.

7. **The exact Apify actor IDs in use.** The code defaults are all `""`; the IDs
   in Section 5.3 come from docstrings and `.env.example` comments, not from
   runtime config.

8. **Whether the app has been verified on a physical device** with the Cloud Run
   URL and FCM push. Every ADR since -007 flags this as a standing gap; nothing in
   the repo settles it.

9. **Whether the two `flutter analyze` deprecation warnings matter in practice.**
   `supabase_flutter`'s `anonKey` is deprecated in favour of `publishableKey`;
   whether the installed version still honours `anonKey` at runtime was not
   tested (no on-device run was performed in this audit).
</content>
</invoke>
