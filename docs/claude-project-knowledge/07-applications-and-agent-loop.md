# Application Tracker & the Daily Agent Loop (Bricks 7–8)

## Application tracker (Kanban)

A straightforward state machine, not an LLM decision — Golden Rule 2.

- **States** (`server/models/application.py::ApplicationState`, a `Literal`,
  enforced by a DB check constraint): `saved → applied → replied → interview →
  offer` / `rejected`. Full list exported as `APPLICATION_STATES` /
  `kApplicationStates` (Dart mirror).
- **Endpoints** (`routers/applications.py`): `POST /applications` (idempotent
  per profile+job — bookmarking a job in `jobs_list_body.dart` and formally
  "submitting" an application after tailoring both land here), `GET
  /applications`, `PATCH /applications/{id}` (state/notes/contact_email,
  ownership-checked so one user can't PATCH another's row by guessing a UUID —
  see [10-auth-and-security.md](10-auth-and-security.md)).
- **UI**: `applications_body.dart` renders a horizontally-scrolling Kanban board
  (`KanbanColumn` per state); tapping a card opens `app_detail_screen.dart` for
  notes, stage moves, and follow-up actions.

## Follow-up emails

Two-step, both human-gated:

1. **Draft**: `POST /applications/{id}/followup` → `services/llm.py::
   generate_followup_draft` (see [03-llm-and-prompts.md](03-llm-and-prompts.md))
   produces subject + body, stored on the `applications` row
   (`followup_subject`, `followup_body`, `followup_drafted_at`).
2. **Send**: `POST /applications/{id}/followup/send` → `services/email.py::
   send_followup_email`, which lazily configures the Resend client and sends;
   `followup_sent_at` is stamped. This is a real, synchronous, just-approved
   user action — failures raise rather than being swallowed, unlike the
   push-notification path below.

The draft can also be generated automatically by the daily pipeline (see
below) when an application has sat in `applied` for 7+ days with no response —
but sending always requires a separate explicit tap.

## The daily agent loop (`server/jobs/daily_pipeline.py`)

This is the autonomous part of the system — triggered once a day by a Render
cron job hitting `POST /pipeline/run`. Step by step:

1. **`_refresh_and_backfill()`** — runs **once**, shared across all users, not
   per-profile:
   - `refresh_job_pool()` (fetch Adzuna+JSearch, dedup, embed, insert — see
     [05-job-ingestion-and-matching.md](05-job-ingestion-and-matching.md))
   - `backfill_job_embeddings()` (catch up any un-embedded rows)
2. **`_process_profile(profile)`** — runs once **per user**:
   - Reads `notification_prefs` (defaults to "on" if the column is missing/null,
     for backward compatibility with rows created before migration `008`).
   - `rerank_shortlist(profile, limit=20)` — the Stage-1+Stage-2 match refresh.
   - If `followup_nudge` is enabled: `_draft_pending_followups(profile)` finds
     `applications` in state `applied` with `followup_drafted_at IS NULL` and
     `state_changed_at <= now - 7 days` (`FOLLOWUP_AFTER_DAYS = 7`), and drafts
     each. Per-job `FollowupError`/`LlmApiError` are caught and skipped — since
     `followup_drafted_at` stays null on failure, it's retried automatically the
     next day.
   - If `alerts` is enabled and either step produced something, sends **one**
     push notification summarizing the counts.
3. **Two entrypoints**:
   - `run_daily_pipeline_for_all()` — the actual Render cron target
     (`POST /pipeline/run`, gated by the `X-Pipeline-Secret` header, not JWT,
     since a cron job has no user session): runs the shared refresh once, then
     loops `_process_profile()` over every `profiles` row.
   - `run_daily_pipeline_for_profile(profile)` — the authenticated "Run agent
     now" entrypoint (`POST /pipeline/run-mine`), a manual trigger for just the
     caller, exposed as a trailing icon button on the Home tab
     (`main_tab_screen.dart`).

## Push notifications (`server/services/notify.py`)

- Firebase Admin SDK, lazily initialized from `settings.fcm_service_account_path`;
  if the credential is missing or invalid, push is disabled (logged) rather
  than crashing server startup — this was the original ADR-007 fallback before
  a real Firebase project existed, and remains the graceful-degradation path.
- `send_push_notification(...)` never raises — a notification failure should
  never take down the daily pipeline.
- Client side: `push_service.dart::initAndRegister()` is Android-only (`kIsWeb`
  guard — no iOS/web push configured, see ADR-007), initializes Firebase,
  requests notification permission, fetches the FCM token, and registers it via
  `PATCH /resume/profile/fcm-token` if a profile already exists. Called from
  `AuthGate` right after sign-in. Entirely wrapped in try/catch so failures
  never block app startup. **Not verified on a physical device** — no Android
  SDK/emulator available in the development environment so far.

## Activity feed & cost dashboard (read-only reporting, no LLM at request time)

- `services/activity.py::build_activity_feed` — merges `applications` +
  `tailored_resumes` rows into a timestamp-sorted feed of human-readable events
  (`_STAGE_TITLES` maps e.g. `saved` → "Saved a job"). Deliberately built from
  existing tables rather than a dedicated activity-log table — one less thing
  to keep in sync. Surfaced via `GET /stats/activity` → `activity_log_screen.dart`.
- `services/cost_stats.py` — see [03-llm-and-prompts.md](03-llm-and-prompts.md)
  for detail; surfaced via `GET /stats/costs` → `cost_stats_screen.dart`.
- `services/skill_growth.py::get_skill_growth` — pulls up to 50 cached matches,
  flattens all `gaps[]` with their originating job id, sends the raw gap text
  to the LLM for clustering/labeling only (`generate_skill_growth`), then
  computes **real** frequency in Python from the `gap_indices` the LLM returns:
  `frequency_label = f"{n} of {total_matches} matches"`. This is a deliberate
  example of Golden Rule 2 — the LLM clusters and names, Python counts.
  Surfaced via `GET /stats/skill-growth` → `skill_growth_screen.dart`.

## Related files

- `server/routers/applications.py`, `server/routers/pipeline.py`, `server/routers/stats.py`
- `server/services/email.py`, `notify.py`, `activity.py`, `cost_stats.py`, `skill_growth.py`
- `server/jobs/daily_pipeline.py`
- `server/models/application.py`, `followup.py`, `skill_growth.py`
- `server/db/migrations/002_followups.sql`, `003_fcm_token.sql`, `007_followup_send.sql`, `008_notification_prefs.sql`
- `app/lib/screens/applications_body.dart`, `app_detail_screen.dart`, `activity_log_screen.dart`, `cost_stats_screen.dart`, `skill_growth_screen.dart`, `settings_screen.dart`
- `app/lib/services/push_service.dart`
- `app/lib/models/application_item.dart`, `activity_item.dart`, `cost_stats.dart`, `skill_growth_item.dart`
- `docs/PROMPTS.md` (sections 4 "Follow-up Draft", 7 "Skill Growth")
