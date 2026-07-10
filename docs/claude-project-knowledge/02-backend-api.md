# Backend API Reference

FastAPI app defined in `server/main.py`. Title: "Job-Hunt Agent API". CORS is
wide open (`allow_origins=["*"]`) — explicitly dev-only, since native mobile
builds never hit CORS at all. Every response follows the envelope
`{"data": ..., "error": null}`. One inline route: `GET /health`.

Config (`server/config.py`) is a Pydantic `Settings` object loaded from `.env`:
`gemini_api_key`, `gemini_model` (default `gemini-2.5-flash`),
`gemini_embed_model` (default `gemini-embedding-001`), Supabase URL/service
key/anon key, Adzuna/RapidAPI creds, `fcm_service_account_path`, Resend creds,
`daily_pipeline_hour`, `target_roles`/`target_locations`, `environment`, and
`pipeline_secret` (shared secret for the cron endpoint).

## Routers (registration order in `main.py`)

All endpoints require Supabase auth (`get_current_user_id` or
`get_current_profile`, see [10-auth-and-security.md](10-auth-and-security.md))
except the cron endpoint, which uses a shared-secret header instead.

### `routers/resume.py` — prefix `/resume`
| Method & path | Purpose |
|---|---|
| `POST /resume/parse` | Upload a resume PDF → vision-LLM parse → upsert `profiles` row. |
| `GET /resume/profile` | Caller's own profile, or `null`. |
| `PATCH /resume/profile` | Edit profile fields; re-embeds from merged data. |
| `PATCH /resume/profile/fcm-token` | Register a device push token. |
| `PATCH /resume/profile/target-roles` | Set target roles / min salary (onboarding). |
| `PATCH /resume/profile/notification-prefs` | Toggle alerts / follow-up nudge. |

### `routers/jobs.py` — prefix `/jobs`
| Method & path | Purpose |
|---|---|
| `POST /jobs/refresh` | Trigger `refresh_job_pool()` (fetch+dedup+embed+insert). Shared pool, not per-user. |
| `GET /jobs` | Paginated job list (`limit` ≤ 100, `offset`). |
| `POST /jobs/backfill-embeddings` | Embed any job rows missing an `embedding`. |
| `POST /jobs/manual/parse` | Fetch a user-pasted URL, extract job fields via LLM, return for review (no persistence). |
| `POST /jobs/manual` | Create (or dedupe-return) a job from user-reviewed fields. |

### `routers/matches.py` — prefix `/matches`
| Method & path | Purpose |
|---|---|
| `GET /matches/shortlist` | Stage 1: pgvector similarity shortlist via `match_jobs_by_similarity` RPC. |
| `POST /matches/rerank` | Stage 2: LLM re-rank of top-N shortlist; caches into `matches`, idempotent. |
| `GET /matches` | Read cached stage-2 results, best-fit first. |

### `routers/tailor.py` — prefix `/tailor`
| Method & path | Purpose |
|---|---|
| `POST /tailor/{job_id}` | Tailor resume bullets toward a job, run the guardrail, store unapproved. |
| `GET /tailor/{job_id}` | Most recent tailored resume for a job. |
| `PATCH /tailor/{tailored_resume_id}/approve` | Human approval gate; supports per-bullet accept/reject. |

### `routers/applications.py` — prefix `/applications`
| Method & path | Purpose |
|---|---|
| `POST /applications` | Add a job to the Kanban tracker (idempotent per profile+job). |
| `GET /applications` | List caller's tracked applications, job joined. |
| `PATCH /applications/{application_id}` | Move Kanban stage / update notes / contact_email (ownership-checked). |
| `POST /applications/{application_id}/followup` | Draft a follow-up email via LLM (on-demand). |
| `POST /applications/{application_id}/followup/send` | Actually send via Resend (explicit "send" approval action). |

### `routers/pipeline.py` — prefix `/pipeline`
| Method & path | Purpose |
|---|---|
| `POST /pipeline/run` | Cron entrypoint for **all** users, guarded by `X-Pipeline-Secret` header (not JWT). |
| `POST /pipeline/run-mine` | Authenticated "Run agent now" button — caller's own profile only. |

### `routers/stats.py` — prefix `/stats`
| Method & path | Purpose |
|---|---|
| `GET /stats/costs` | This month's LLM cost/usage breakdown by task, from `llm_calls`. |
| `GET /stats/activity` | Merged activity feed (stage changes, follow-ups, tailoring events). |
| `GET /stats/skill-growth` | LLM-clustered skill gaps with real frequency counts computed in Python. |

## Service layer map (`server/services/`)

| File | Responsibility | Detail doc |
|---|---|---|
| `llm.py` | Central Gemini client; every generative task, prompt templates, validate/retry pattern, `llm_calls` logging | [03-llm-and-prompts.md](03-llm-and-prompts.md) |
| `embeddings.py` | Batch embedding wrapper (`gemini-embedding-001`, 768-dim), also logs to `llm_calls` | [03-llm-and-prompts.md](03-llm-and-prompts.md) |
| `job_sources.py` | Adzuna + JSearch fetchers, per-query error tolerance | [05-job-ingestion-and-matching.md](05-job-ingestion-and-matching.md) |
| `dedup.py` | Exact (`dedup_key`) + fuzzy (`rapidfuzz.fuzz.ratio`) job dedup, pure functions | [05-job-ingestion-and-matching.md](05-job-ingestion-and-matching.md) |
| `job_ingestion.py` | Orchestrates fetch → dedup → embed → insert; manual job add flow | [05-job-ingestion-and-matching.md](05-job-ingestion-and-matching.md) |
| `matching.py` | Two-stage RAG: pgvector shortlist (Stage 1) + LLM re-rank (Stage 2) | [05-job-ingestion-and-matching.md](05-job-ingestion-and-matching.md) |
| `guardrail.py` | Anti-fabrication check on tailored bullets (`rapidfuzz.fuzz.partial_ratio`, threshold 85) | [06-resume-tailoring-and-guardrail.md](06-resume-tailoring-and-guardrail.md) |
| `auth.py` | `get_current_user_id` / `get_current_profile` dependencies | [10-auth-and-security.md](10-auth-and-security.md) |
| `activity.py` | Builds the activity feed from existing tables (no LLM, no dedicated log table) | [07-applications-and-agent-loop.md](07-applications-and-agent-loop.md) |
| `cost_stats.py` | Aggregates `llm_calls` into cost/usage breakdowns (no LLM) | [03-llm-and-prompts.md](03-llm-and-prompts.md) |
| `email.py` | Sends follow-up emails via Resend | [07-applications-and-agent-loop.md](07-applications-and-agent-loop.md) |
| `notify.py` | Firebase Admin / FCM push, fails silently (never crashes the pipeline) | [07-applications-and-agent-loop.md](07-applications-and-agent-loop.md) |
| `skill_growth.py` | Mixed: LLM clusters gap text into skills, Python computes real frequency stats | [07-applications-and-agent-loop.md](07-applications-and-agent-loop.md) |

## Pydantic models (`server/models/`)

Single source of truth for every data shape, mirrored by hand in the Flutter app's `lib/models/`:

- `application.py` — `ApplicationState` (saved/applied/replied/interview/offer/rejected), `ApplicationCreate`, `ApplicationStateUpdate`
- `followup.py` — `FollowupDraft` (subject, body)
- `job.py` — `JobIn` (normalized source→DB shape), `JobExtraction` (LLM's read of a pasted URL)
- `match.py` — `MatchResult` (fit_score, strengths, gaps, compensators, verdict, one_line_reason)
- `resume.py` — `ExperienceItem`, `ProjectItem`, `EducationItem`, `ResumeProfile`, `ResumeProfileUpdate`
- `skill_growth.py` — `SkillCourse`, `SkillProject`, `SkillGrowthItem`, `SkillGrowthResponse`
- `tailor.py` — `TailoredBullet`, `TailorLlmResponse`

## Database schema (`server/db/migrations/*.sql`, applied manually in Supabase SQL Editor)

| Migration | What it adds |
|---|---|
| `001_core_schema.sql` | Enables `pgvector`. Creates `profiles`, `jobs` (unique `dedup_key`, `vector(768) embedding`, `ivfflat` cosine index), `matches` (unique on `profile_id,job_id`), `applications`, `tailored_resumes`, `llm_calls`. Defines SQL function `match_jobs_by_similarity(p_profile_id, p_limit)` (Stage 1 cosine shortlist). |
| `002_followups.sql` | Adds `followup_subject`, `followup_body`, `followup_drafted_at` to `applications`. |
| `003_fcm_token.sql` | Adds `fcm_token` to `profiles`. |
| `004_auth.sql` | Unique constraint on `profiles.user_id`; enables RLS on `profiles`/`matches`/`applications`/`tailored_resumes` (owner-scoped) and `jobs` (any authenticated read, service-role-only write). Explicitly documented as defense-in-depth, not the primary boundary. |
| `005_target_roles.sql` | Adds `target_roles jsonb`, `min_salary numeric` to `profiles`. |
| `006_llm_calls_profile.sql` | Adds nullable `profile_id` to `llm_calls` (nullable because resume-parse logs before a profile exists), RLS owner-read policy. |
| `007_followup_send.sql` | Adds `contact_email`, `followup_sent_at` to `applications`. |
| `008_notification_prefs.sql` | Adds `notification_prefs jsonb` (`{"alerts": true, "followup_nudge": true}`) to `profiles`. |

`db/supabase_client.py` creates a single module-level client using the
**service-role key** — it bypasses RLS by design; the FastAPI layer is the real
authorization boundary (see [10-auth-and-security.md](10-auth-and-security.md)).

## Server dependencies (`requirements.txt`)

`fastapi`, `uvicorn[standard]`, `python-multipart`, `pydantic-settings`,
`google-genai` (Gemini SDK), `pdf2image` + `pypdf` + `Pillow` (resume PDF
handling), `supabase`, `httpx` (async HTTP), `python-slugify` (dedup key
normalization), `rapidfuzz` (fuzzy matching — dedup and guardrail),
`firebase-admin` (FCM), `beautifulsoup4` (manual job HTML extraction), `resend`
(transactional email).
