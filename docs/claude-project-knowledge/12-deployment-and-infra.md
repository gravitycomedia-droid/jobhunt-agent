# Deployment & Infrastructure

## Backend hosting — Google Cloud Run

Migrated off Render in ADR-014 (Render free-tier cold-starts were timing out
re-rank/tailor calls). The Render history below survives only inside ADR-010/014.

- Service: `jobhunt-agent-server` on Cloud Run, project `jobhunteragent-502002`,
  region `asia-south1` (Mumbai, closest to `ADZUNA_COUNTRY=in`). Deployed from
  **`server/Dockerfile`** — the container is the whole point: it bundles
  `poppler-utils`, which `pdf2image` requires for resume-PDF vision parsing
  (see [04-resume-parsing.md](04-resume-parsing.md)).
- **Dockerfile**: `python:3.11-slim` base → `apt install poppler-utils` →
  `pip install -r requirements.txt` → copy source → `uvicorn main:app --host
  0.0.0.0 --port ${PORT:-8000}` (Cloud Run injects `$PORT`, default 8000).
- **Deploys are manual and not repo-triggered.** A `git push` deploys nothing;
  the user runs `gcloud run deploy --source .` (recorded in `MANUAL_STEPS.md`)
  and it builds the Dockerfile via Cloud Build. There is no infra-as-code file
  yet — service config and env/secret wiring were set up interactively (ADR-014),
  so the deployment is not fully reproducible from the repo alone. "Still broken"
  after a change is usually a **stale revision** — verify a new revision with
  `gcloud run services describe`.
- Live base URL, also the Flutter app's default:
  `https://jobhunt-agent-server-380742808186.asia-south1.run.app`
  (`app/lib/services/api_client.dart`), overridable via
  `--dart-define=API_BASE_URL=...`.
- The daily pipeline is triggered by **Cloud Scheduler**, which authenticates as
  a dedicated `pipeline-scheduler@…iam.gserviceaccount.com` service account with
  a **Google-signed OIDC bearer token** — `POST /pipeline/run` accepts that OIDC
  token *or* the legacy `X-Pipeline-Secret` header (kept for transition). See
  [10-auth-and-security.md](10-auth-and-security.md).

## Database — Supabase

- Postgres with the `pgvector` extension enabled.
- Schema managed via hand-numbered SQL migration files in
  `server/db/migrations/`, applied **manually** in the Supabase SQL Editor (no
  migration runner/tool wired up) — see the migration table in
  [02-backend-api.md](02-backend-api.md).
- Server connects with the **service-role key** (bypasses RLS by design — see
  [10-auth-and-security.md](10-auth-and-security.md)); the Flutter app connects
  directly to Supabase only for **auth** (session tokens), using the public
  anon key, never for data access.

## Firebase project

- Project ID: `jobhuntagent-27b32`, `messagingSenderId`/project number:
  `326733198557`.
- **Only Cloud Messaging is configured** — no Firebase Auth, Firestore,
  Analytics, or Crashlytics in this project. Firebase's sole job here is
  Android push notifications.
- **Android-only**: `lib/firebase_options.dart` (FlutterFire-CLI-generated)
  only populates the `android` case; iOS/macOS/windows/linux/web all `throw
  UnsupportedError`. No APNs key or iOS Firebase app registered (ADR-007).
- Config files: `app/firebase.json` (FlutterFire config, maps `android.default`
  → `android/app/google-services.json`), `android/app/google-services.json`
  (+ a stray, structurally-identical duplicate `google-services-2.json` — worth
  cleaning up when next touching Android config). These contain only public
  client identifiers (project number, app ID, a Firebase-scoped public API
  key) — standard practice to commit them, unlike a service-account key.
- Server-side FCM uses `firebase-admin` with a service-account JSON. Since the
  Cloud Run migration this is provided as `FCM_SERVICE_ACCOUNT_JSON` in Secret
  Manager (ADR-014), closing the ADR-007/010 gap where the JSON was never
  uploaded to Render. Push still degrades gracefully to log-only if the secret
  is absent, and on-device delivery remains unverified (ADR-007).

## Third-party APIs in play

| Service | Used for | Key env var(s) |
|---|---|---|
| Google Gemini | Vision parse + embeddings + default tailor (see `_TASK_PROVIDERS`, ADR-023) | `GEMINI_API_KEY`, `GEMINI_MODEL`, `GEMINI_EMBED_MODEL` |
| DeepSeek | rerank / extract_job / followup / skill_growth / forms (OpenAI-compatible, thinking disabled) | `DEEPSEEK_API_KEY` |
| Adzuna | Primary job source | `ADZUNA_APP_ID`, `ADZUNA_APP_KEY`, `ADZUNA_COUNTRY` |
| JSearch (RapidAPI) | Secondary job source | `RAPIDAPI_KEY` |
| Apify | No-login supplementary scraping (LinkedIn/Indeed/Naukri/Internshala) + Unstop, daily-cron only (ADR-003 v2) | `APIFY_API_TOKEN`, `ENABLE_INDIA_SOURCES` |
| Resend | Follow-up email sending | `RESEND_API_KEY`, `RESEND_FROM_EMAIL` |
| Supabase | DB, Auth | `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `SUPABASE_ANON_KEY` |
| Firebase (Admin SDK) | Push (FCM) | `FCM_SERVICE_ACCOUNT_JSON` (Secret Manager) |

All secrets live in Cloud Run Secret Manager; non-secret config (model names,
`TARGET_ROLES`, `TARGET_LOCATIONS`, etc.) is passed as plain env vars.

Full grouping and every variable name (no real values) is in `.env.example` at
the repo root — verified to contain only placeholders, no real secrets, and
explicitly documented as server-side-only (Golden Rule 1).

## Environment / app config knobs

`DAILY_PIPELINE_HOUR`, `TARGET_ROLES`, `TARGET_LOCATIONS`, `ENVIRONMENT`
(`server/config.py`) control the daily pipeline's schedule intent and default
search scope; `PIPELINE_SECRET` gates the cron endpoint.

## Mobile build/distribution status

- First APK built and confirmed installable (sideload), but **not verified
  running end-to-end on a physical device** — no Android SDK/emulator in the
  development environment so far.
- Release build is signed with a **real upload keystore** driven by
  `android/key.properties` (ADR-030); R8 is on, and `build.gradle.kts`
  **hard-fails** the release build if `key.properties` is missing — no silent
  fallback to the debug cert. The keystore lives outside the repo and is
  unbacked-up. Play closed testing is set up (`docs/PLAY_CONSOLE.md`).
- iOS: no build/signing/distribution setup at all — out of scope for now.

## CI/CD

None. No `.github/workflows/`. All verification to date has been manual or
scripted directly against the live Cloud Run/Supabase stack (e.g., throwaway
test users created/deleted via the Supabase admin API), plus local `flutter
analyze` / `flutter test` / `flutter build`. See
[09-status-and-roadmap.md](09-status-and-roadmap.md) for what's flagged as a
gap versus what's deliberately deferred.
