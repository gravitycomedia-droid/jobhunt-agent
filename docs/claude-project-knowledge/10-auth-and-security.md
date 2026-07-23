# Auth & Security (Brick 9)

## Sign-in methods

Two, both via **Supabase Auth**, both handled entirely client-side in Flutter
(`auth_screen.dart`):
- Email/password (`signInWithPassword` / `signUp`)
- Google OAuth (`signInWithOAuth`), returning to the app via a custom URL
  scheme redirect: `com.jobhuntagent.firstrole://login-callback/`
  (configured in `SupabaseConfig.redirectUrl`, and matched by an
  `AndroidManifest.xml` intent-filter with `android:scheme=
  "com.jobhuntagent.jobhunt_agent"` / `android:host="login-callback"`).

Note: this is **Firebase-adjacent but not Firebase Auth** — sign-in identity is
entirely Supabase's; Firebase in this project is used only for Cloud Messaging
(push), never auth. Don't conflate the two when reasoning about credentials.

## Server-side verification (`server/services/auth.py`)

- `get_current_user_id(authorization: str = Header(...))` — parses
  `Authorization: Bearer <token>` and calls `supabase.auth.get_user(token)`.
  **The server never decodes a JWT or manages a signing secret itself** — it
  delegates verification entirely to Supabase's Auth API (one network
  round-trip per authenticated request). Raises 401 on a missing/malformed
  header or an invalid/expired session.
- `get_current_profile(user_id = Depends(get_current_user_id))` — looks up the
  `profiles` row for that `user_id`; 404s with "No profile found — upload a
  resume first" if none exists yet. Only `POST /resume/parse` creates the
  first profile row for a new user.

Almost every router depends on one of these two functions — see the endpoint
table in [02-backend-api.md](02-backend-api.md) for exactly which.

## Multi-tenancy: enforced in application code, not by Postgres RLS

This is the single most important thing to understand about this project's
security model, and it's a deliberate, documented choice (ADR-008):

- `db/supabase_client.py` creates the server's Supabase client using the
  **service-role key**, which **bypasses Row Level Security entirely**.
- Real tenant isolation happens in Python: every router filters/checks by
  `profile["id"]` or `user_id`, and explicit ownership checks (e.g. `if
  existing[0]["profile_id"] != profile["id"]: raise HTTPException(403/404)`)
  guard every mutating endpoint in `routers/applications.py` and
  `routers/tailor.py` before a row is modified by id.
- RLS policies **do exist** (migrations `004_auth.sql`, `006_llm_calls_profile.sql`)
  — owner-scoped read/write on `profiles`/`matches`/`applications`/
  `tailored_resumes`/`llm_calls`, and any-authenticated-read/service-role-only-
  write on `jobs`. But they are explicitly **defense-in-depth**, not the
  primary boundary: they only matter if the Supabase **anon key** is ever
  queried directly (e.g. from a future client that bypasses the FastAPI
  server), which per Golden Rule 1 is not expected to happen.

**If you're reasoning about "is this endpoint safe," the question to ask is
"does this router function check ownership before acting," not "does RLS cover
this table."** ADR-008 notes this distinction fixed a real pre-existing bug:
before the ownership checks were added, any UUID could be PATCHed by anyone
who knew (or guessed) it.

## Cron authentication (a deliberately separate path)

`POST /pipeline/run` (the Cloud Scheduler cron target, processes *all* users)
does **not** use the JWT flow at all — a cron job has no per-user session to
authenticate with. Instead it accepts a Google-signed OIDC token (Cloud
Scheduler's service account) or, for the transition, a static shared secret in the
`X-Pipeline-Secret` header, matched against `settings.pipeline_secret`
(`PIPELINE_SECRET` in `.env`). The parallel authenticated endpoint,
`POST /pipeline/run-mine`, uses the normal JWT flow and only ever processes the
caller's own profile.

## Secrets handling

- Golden Rule 1: **the Flutter app never contains an LLM/API key.** The only
  values baked into the client are the Supabase project URL and the Supabase
  **anon key** (`lib/config/supabase_config.dart`) — the anon key is
  documented in its own code comment as safe to embed client-side (it has no
  power without a valid user session, and RLS + server-side ownership checks
  bound what an authenticated session can do).
- All real secrets (`GEMINI_API_KEY`, `SUPABASE_SERVICE_KEY`, `ADZUNA_APP_KEY`,
  `RAPIDAPI_KEY`, `RESEND_API_KEY`, `PIPELINE_SECRET`, the FCM service-account
  path) live in `server/.env` only, never committed (`.env.example` is the
  committed template, and every value in it is a placeholder — verified, no
  real secrets present in that file).
- `google-services.json` (Android Firebase config) is safe to commit despite
  looking secret-shaped — it contains only public client identifiers (project
  number, app ID, public API key scoped to that Firebase project), which is
  standard Firebase/Google practice.

## Related files

- `server/services/auth.py`
- `server/db/migrations/004_auth.sql`, `006_llm_calls_profile.sql`
- `server/routers/pipeline.py` (the two-path cron vs. user auth split)
- `app/lib/screens/auth_gate.dart`, `auth_screen.dart`, `splash_screen.dart`
- `app/lib/config/supabase_config.dart`
- `app/android/app/src/main/AndroidManifest.xml` (OAuth redirect intent-filter)
- `.env.example`
