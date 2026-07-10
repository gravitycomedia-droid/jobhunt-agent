# Deployment & Infrastructure

## Backend hosting — Render

- Service: `jobhunt-agent-server` (free plan, Singapore region), deployed from
  **`server/Dockerfile`**, not Render's native Python buildpack — the buildpack
  doesn't include `poppler-utils`, which `pdf2image` requires for resume-PDF
  vision parsing (see [04-resume-parsing.md](04-resume-parsing.md)).
- **Dockerfile**: `python:3.11-slim` base → `apt install poppler-utils` →
  `pip install -r requirements.txt` → copy source → `uvicorn main:app --host
  0.0.0.0 --port ${PORT:-8000}` (Render-style dynamic `$PORT`, default 8000).
- **No `render.yaml`** exists in the repo — the service and its environment
  variables were created directly through Render's dashboard/HTTP API during
  an interactive session (ADR-010), not as infra-as-code. This means the
  Render deployment is **not currently reproducible from the repo alone** —
  worth fixing (a `render.yaml`) as part of hardening before/after Brick 10.
- Live base URL, also the Flutter app's default: `https://jobhunt-agent-server.onrender.com`.
- A cron job (external to the repo, configured in Render) hits `POST
  /pipeline/run` on a schedule, authenticated via the `X-Pipeline-Secret`
  header (see [10-auth-and-security.md](10-auth-and-security.md)).

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
- Server-side FCM uses `firebase-admin` with a service-account JSON, referenced
  by path via `FCM_SERVICE_ACCOUNT_PATH` — this env var was **not** set on
  Render as of the last deploy (ADR-010), so push currently degrades
  gracefully to log-only on the live server until that file/secret is
  provisioned there.

## Third-party APIs in play

| Service | Used for | Key env var(s) |
|---|---|---|
| Google Gemini | All generation + embeddings | `GEMINI_API_KEY`, `GEMINI_MODEL`, `GEMINI_EMBED_MODEL` |
| Adzuna | Primary job source | `ADZUNA_APP_ID`, `ADZUNA_APP_KEY`, `ADZUNA_COUNTRY` |
| JSearch (RapidAPI) | Secondary job source | `RAPIDAPI_KEY` |
| Resend | Follow-up email sending | `RESEND_API_KEY`, `RESEND_FROM_EMAIL` |
| Supabase | DB, Auth | `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `SUPABASE_ANON_KEY` |
| Firebase (Admin SDK) | Push (FCM) | `FCM_SERVICE_ACCOUNT_PATH` |

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
- Release build uses the **debug signing config** — not production-ready for
  Play Store submission yet (needs a real upload keystore).
- iOS: no build/signing/distribution setup at all — out of scope for now.

## CI/CD

None. No `.github/workflows/`. All verification to date has been manual or
scripted directly against the live Render/Supabase stack (e.g., throwaway test
users created/deleted via the Supabase admin API), plus local `flutter
analyze` / `flutter test` / `flutter build`. See
[09-status-and-roadmap.md](09-status-and-roadmap.md) for what's flagged as a
gap versus what's deliberately deferred.
