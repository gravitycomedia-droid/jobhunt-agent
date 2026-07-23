# MASTER PROMPT — Job-Hunt Agent: Stabilization, UX Overhaul & New Features

You are working on the **Job-Hunt Agent** monorepo (product name **FirstRole**): a Flutter mobile app (`app/`) backed by a FastAPI server (`server/`), Supabase Postgres + pgvector, Google Gemini + DeepSeek for LLM tasks, deployed on Google Cloud Run (was Render; ADR-014). Read `CLAUDE.md`, `DECISIONS.md`, and `docs/claude-project-knowledge/` before writing any code. *(This is a historical founding prompt — where it conflicts with current ADRs, the ADRs win.)*

## NON-NEGOTIABLE CONSTRAINTS (project Golden Rules — never violate)

1. Secrets live server-side only. The Flutter app never holds an LLM/API key. The phone talks only to the FastAPI server.
2. LLMs handle language; code handles logic. Scores, state transitions, counts, diffs are always plain Python — never LLM arithmetic.
3. Every LLM output is schema-validated against a Pydantic model; exactly one retry with the validation error appended; log and fail gracefully on second failure.
4. The anti-fabrication guardrail (`server/services/guardrail.py`, `partial_ratio`, threshold 85) is sacred. Any new resume-related output must pass through it or an equivalent deterministic check.
5. Every LLM call is logged to `llm_calls` (prompt hash, model, tokens, latency, validation result, profile_id).
6. No scraping of LinkedIn/Naukri/Indeed. Legal APIs and user-pasted content only. *(Superseded by ADR-003 v2: no-login Apify scraping of LinkedIn/Indeed/Naukri/Internshala + Unstop is now approved at personal scale, daily-cron cadence only. Login-based scraping remains forbidden.)*
7. Nothing is ever auto-submitted anywhere. Every external-facing action (application submit, email send, form submit) requires an explicit human tap.
8. Keep the existing architecture: plain `StatefulWidget` + `setState` (no Riverpod/Bloc unless a phase explicitly says so), imperative `Navigator.push/pop` (no go_router), hand-written `fromJson`/`toJson` (no code-gen), design tokens from `lib/theme/app_tokens.dart` — widgets never hardcode hex/px values.
9. Response envelope `{"data": ..., "error": null}` on every server endpoint. New endpoints follow existing router/auth patterns (`get_current_profile` dependency, ownership checks on every mutating endpoint).
10. Database changes go through new hand-numbered SQL migration files in `server/db/migrations/` (next is `009_...`). Print the SQL so it can be applied manually in the Supabase SQL Editor.

Work phase by phase, in order. Commit at the end of each phase with a descriptive message. Do not start a phase until the previous one compiles (`flutter analyze` clean, `pytest server/tests` green).

---

## PHASE 0 — Commit the pending working tree (DO THIS FIRST)

`git status` currently shows ~63 changed paths (the entire ADR-009 frontend rebuild) uncommitted. Before touching anything:

1. Review `git status`. Commit the existing work in logical chunks (e.g., "theme + design system", "screens + widgets rebuild", "models + services", "config + firebase", "deleted legacy screens"). Do NOT commit `google-services-2.json` — delete it (it is a stray duplicate of `google-services.json`).
2. Verify `.env` is not staged and `.env.example` still contains only placeholders.

**Acceptance:** clean `git status` except intentional untracked reference folders; `google-services-2.json` removed.

---

## PHASE 1 — Critical bug fixes

### 1A. Fix the rerank connection abort (root cause, not a timeout band-aid)

**Observed error (screenshot):** `ClientException: Software caused connection abort, uri=https://jobhunt-agent-server.onrender.com/matches/rerank?limit=20`.

**Root cause:** `POST /matches/rerank` runs up to 20 sequential Gemini calls synchronously while the mobile client holds one HTTP connection open for minutes. Android's network stack / Render free tier drops the socket. The client's 10-minute timeout is a symptom-mask, not a fix.

**Required change — async job pattern:**
- New table via migration `009_background_tasks.sql`: `background_tasks(id uuid pk, profile_id uuid fk, task_type text, status text check in ('pending','running','done','failed'), result jsonb, error text, created_at, updated_at)`. RLS owner-read policy (defense-in-depth, consistent with migration 004/006 style).
- `POST /matches/rerank` now: creates a `background_tasks` row (`pending`), schedules the actual rerank via FastAPI `BackgroundTasks`, returns `202` with `{"data": {"task_id": ...}}` immediately. The background function updates the row to `running`, then `done` with `result = {"reranked": n, "skipped": n}` or `failed` with the error string. Reuse the existing idempotent `rerank_shortlist` internals unchanged.
- New endpoint `GET /tasks/{task_id}` (ownership-checked) returning the task row.
- Apply the same pattern to `POST /pipeline/run-mine` (the "Run agent now" button) — it is equally long-running.
- The cron path `POST /pipeline/run` stays synchronous (Render cron has no timeout problem) — do not change its auth or behavior.
- Client (`api_client.dart`): `rerankShortlist()` and `runPipeline()` now return a task id and there is a `getTaskStatus(taskId)` method. Remove the 10-minute timeouts (normal 30s timeouts are now sufficient).
- Client polling: poll `GET /tasks/{id}` every 5 seconds, backing off to 10s after 1 minute, giving up with a friendly error after 10 minutes. Polling must survive tab switches (the `IndexedStack` keeps tabs alive — hold the poller in a service, see Phase 2).

**Acceptance:** tapping re-rank returns instantly; the UI stays usable; the matches list refreshes itself when the task completes; killing/restoring network mid-task shows a graceful failure with Retry, never a raw `ClientException`.

### 1B. Fix Google OAuth landing on localhost:5173

**Observed:** after Google sign-in on a real device, the browser lands on `localhost:5173` instead of returning to the app.

**Root cause:** the Supabase project's **Site URL** is set to the Vite dev default, and it is used as fallback because `redirectTo` is either not passed or not in the allow-list.

**Fix:**
1. In `auth_screen.dart`, ensure `signInWithOAuth(OAuthProvider.google, redirectTo: SupabaseConfig.redirectUrl, authScreenLaunchMode: LaunchMode.externalApplication)`.
2. Verify `SupabaseConfig.redirectUrl == 'com.jobhuntagent.firstrole://login-callback/'` and that `AndroidManifest.xml` has the matching intent-filter (`android:scheme="com.jobhuntagent.firstrole"`, `android:host="login-callback"`, `android:autoVerify` not required, `BROWSABLE` + `DEFAULT` categories present).
3. Print clear manual instructions for the Supabase dashboard (cannot be done from code): Authentication → URL Configuration → add `com.jobhuntagent.firstrole://login-callback/` to **Additional Redirect URLs**; set Site URL to the production URL or the deep link, not localhost.
4. Confirm `AuthGate` reacts to the auth-state change fired by the deep-link return (Supabase Flutter handles the token exchange; verify `onAuthStateChange` triggers profile lookup and `PushService.initAndRegister()`).

**Acceptance:** documented dashboard steps + code verified; email/password flow untouched.

### 1C. Fix Home vs Matches count mismatch

**Observed:** Home page reports e.g. 10 matches; Matches tab shows only 2.

**Investigate then fix:** Home and Matches must read the **same source of truth**: `GET /matches` (cached stage-2 results) with the **same filters**. Likely causes to check: Home counting the Stage-1 shortlist (`GET /matches/shortlist`) or all cached rows while the Matches tab filters `verdict != 'skip'`; or a partially-populated cache from the aborted rerank (fixed in 1A). Whatever the cause: extract one shared fetch/filter definition, use it in both `home_body.dart` and `matches_body.dart`, and make the Home stat literally the `.length` of the same filtered list the Matches tab renders.

**Acceptance:** the number on Home always equals the number of cards on the Matches tab.

### 1D. Job freshness + currency bugs

**Observed:** a job showing "2591d ago" (≈7 years old) and "$200K–$400K" for a Hyderabad, India position.

**Fixes:**
- **Freshness:** in `job_sources.py` / `job_ingestion.py`, parse the posting date from both Adzuna (`created`) and JSearch responses; skip jobs older than 60 days at ingestion time (constant `MAX_JOB_AGE_DAYS = 60` in config). Add a one-off cleanup note (SQL to delete/flag stale rows). In the UI, if a date is missing or implausible (> 1 year), show "date unknown" instead of "2591d ago".
- **Currency:** add `salary_currency` to the `jobs` table (same migration 009 or a small 010). Adzuna returns salaries in the country's currency (INR for `country=in`); JSearch provides a currency field. Store it. In `job_card.dart` / `match_card.dart`, format with the correct symbol; for INR use Indian formatting (₹20L–₹40L style is acceptable, or ₹20,00,000). Never assume `$`.

**Acceptance:** no job renders with an implausible age; Indian salaries render in ₹.

---

## PHASE 2 — Background-first UX (loading popups + completion toasts)

Goal: **no operation ever blocks the UI**, and the user is always told (a) that a long task started and runs in the background, and (b) when it finishes.

1. Create `lib/services/task_center.dart` — a plain singleton (no new packages) that: registers background tasks (rerank, pipeline run, jobs refresh, tailoring), owns the polling loops from Phase 1A, exposes `ValueNotifier`s / streams of task state, and survives tab switches.
2. **Start-of-task dialog:** a reusable `showBackgroundTaskDialog(context, title, message)` widget (in `lib/widgets/`) shown when any task expected to exceed ~5 seconds starts. Content pattern: title (e.g., "Re-ranking your matches"), body: "This runs in the background and usually takes 2–3 minutes. You can keep using the app — we'll notify you when it's done.", one "Got it" dismiss button. It must be dismissible and must NOT block the task.
3. **Completion feedback:** when a task completes, show a floating `SnackBar` styled like a console/status line from the design tokens (monospace-ish, success color, e.g. "✓ Re-rank complete — 8 new, 12 skipped" or "✗ Job refresh failed — tap to retry" with a Retry action). Fire it from wherever the user currently is (use a global `ScaffoldMessengerKey` on the `MaterialApp` so it works across tabs).
4. Wire this into: matches re-rank, "Run agent now", jobs refresh (pull-to-refresh keeps its indicator but long refreshes also toast on completion), resume tailoring (`POST /tailor/{job_id}` — if consistently > 5s, move it to the same 202+poll pattern), and resume parsing during onboarding (keep the dedicated loading screen there, but with honest copy about duration).
5. Remove `resume_generating_screen.dart`'s fake pause OR repurpose it to reflect a real task state — no fake waits anywhere in the app.

**Acceptance:** no button in the app ever leaves the user staring at a frozen spinner for minutes; every long task has a start dialog and an end toast; tab switching mid-task never loses the result.

---

## PHASE 3 — Navigation, headers, onboarding

### 3A. Remove the app title bar; add interactive per-page headers

- Remove any AppBar/header that displays "Job Hunt Agent" branding text from the main shell entirely.
- Give each of the 4 tab bodies (Jobs, Matches, Track, Profile) its own header built as a reusable `PageHeader` widget in `lib/widgets/` using existing tokens: large title, optional subtitle/count, contextual action icons (Jobs: search/filter + refresh; Matches: re-rank trigger; Track: view options; Profile: settings shortcut). Home keeps its existing greeting header.
- **Back button semantics:** the 4 tabs are bottom-nav roots, so their headers show no back button; every **pushed sub-screen** (AddJob, Shortlist, AppDetail, ResumeDiff, ResumePreview, CostStats, ActivityLog, SkillGrowth, Settings, ProfileReview, TargetRoles) gets the same `PageHeader` **with** a back button (`Navigator.pop`). Audit all 25 screens for consistency.

### 3B. Onboarding resumption + skip buttons

**Problem:** after signup the onboarding flow (Welcome → ResumeUpload → ProfileReview → TargetRoles → MatchingLoading) renders inconsistently, and if the user quits mid-flow they restart from the beginning. Skip buttons are unreliable.

**Fix:**
1. Migration (009 or later): add `onboarding_step text` to `profiles` (values: `welcome`, `resume`, `review`, `roles`, `done`; default `welcome`). `PATCH /resume/profile` and the step-specific endpoints update it as each step completes. `POST /resume/parse` sets it to `review` on the newly created profile.
2. `AuthGate` routing becomes: no session → auth; session + no profile → onboarding at `welcome`/`resume`; session + profile with `onboarding_step != 'done'` → onboarding **at exactly that step**; `done` → `MainTabScreen`. Mirror the step in local cache (Phase 5) so resumption works instantly even before the network responds.
3. Rework `onboarding_flow.dart` into an explicit step state machine (an enum + `IndexedStack` or step-keyed builder) instead of chained pushes, so jumping to an arbitrary step is trivial.
4. **Skip buttons:** define and implement the skip contract per step — Welcome: skippable → resume upload. ResumeUpload: NOT skippable (the whole product depends on a profile) — replace any skip with clear copy. ProfileReview: skippable (accepts parsed data as-is, sets step to `roles`). TargetRoles: skippable (server falls back to config defaults; mark prefs as unset so Profile screen nudges later). Every skip advances `onboarding_step` server-side.
5. Visual QA every onboarding screen against the design tokens: correct spacing, no overflow on small screens (test at 360×640 logical), progress indicator showing step X of 4.

**Acceptance:** kill the app at any onboarding step, reopen → resumes at that exact step; every skip lands where specified; `flutter analyze` clean.

---

## PHASE 4 — Feature work

### 4A. Job card → open the original posting

On the Jobs page (and job detail anywhere it appears), tapping the source chip/link must open the job's original URL. Add `url_launcher` to `pubspec.yaml`. Server already stores the source URL from Adzuna/JSearch (verify the field exists on the `jobs` row and in `job.dart`; if it was dropped during normalization in `JobIn`, add it — migration + backfill note). Open with `launchUrl(uri, mode: LaunchMode.externalApplication)`; if the URL is missing, disable the affordance with a tooltip "Source link unavailable".

### 4B. Tailored resume → ATS-friendly PDF ("Create Resume" button)

1. Verify the tailoring flow: match card → `ResumeDiffScreen` shows bullet-by-bullet diff with guardrail flags and per-bullet accept/reject (this exists — fix any rendering bugs found).
2. New server capability: `GET /tailor/{tailored_resume_id}/pdf` (ownership-checked) that compiles ONLY the accepted bullets + the stored profile (name, headline, contact, skills, experience, projects, education) into a **single-column, ATS-friendly PDF**: standard fonts (Helvetica/Arial), standard section headings (SUMMARY, SKILLS, EXPERIENCE, PROJECTS, EDUCATION), no tables/columns/images/icons/text-in-graphics, machine-readable text layer, reverse-chronological. Use **ReportLab** (add to `requirements.txt`; it is pure-Python, no new system packages in the Dockerfile). Return `application/pdf` (skip the `{"data": ...}` envelope for this binary endpoint — document that exception in the router).
3. Client: on `ResumePreviewScreen`, add a prominent "Create Resume PDF" button → downloads the PDF (`http` bytes → temp file) → opens the native share/save sheet. Add `share_plus` (or `open_filex`) to pubspec.
4. Golden Rule 4 check: the PDF compiler is deterministic Python assembling already-guardrailed, human-accepted bullets — no LLM call in this step.

### 4C. Per-screen skeleton loaders

Replace the single generic `loading_skeleton.dart` usage with structure-matched skeletons (all built on the existing shimmer base, all token-driven):
- `JobCardSkeleton` (avatar square + two text lines + chip row) → Jobs list shows 5–6 of these.
- `MatchCardSkeleton` (avatar + title lines + score-ring circle placeholder) → Matches.
- `KanbanSkeleton` (column headers + 2–3 card blocks per column) → Track.
- `StatGridSkeleton` + `HeroCardSkeleton` → Home.
- `ProfileSkeleton` (avatar circle + field rows) → Profile/ProfileReview.
- `DiffRowSkeleton` → ResumeDiffScreen while tailoring loads.
Keep one `ListSkeleton` fallback for anything else. Each body widget uses its matching skeleton during first load; cached-data renders (Phase 5) skip skeletons entirely.

---

## PHASE 5 — Client-side caching (stale-while-revalidate)

1. Move `shared_preferences` from `dev_dependencies` to `dependencies` in `pubspec.yaml`.
2. New `lib/services/cache_service.dart`: `read<T>(key, fromJson)` / `write(key, toJsonMap)` storing `{"data": ..., "cachedAt": "<ISO>"}` as JSON strings. **All keys namespaced by user id** (`"<userId>:matches"`). `clearForUser(userId)` called on sign-out from `AuthGate`.
3. Pattern in every tab body + profile: on init, paint cached data instantly if present (no skeleton) → fetch fresh in background → update cache + UI on success → on failure keep cached data and show a small "Showing saved data · last updated <relative time>" banner with a retry. Explicit reload = pull-to-refresh or the page-header refresh action, which bypasses cache.
4. Cache targets: profile (highest value — changes rarely, gates everything), matches list, jobs first page, applications, cost stats, activity feed, `onboarding_step`. TTL: treat anything older than 24h as must-revalidate-before-trust (still paint it, but force the background fetch).
5. Never cache: auth tokens (Supabase handles those), task statuses, anything mid-mutation.

**Acceptance:** airplane-mode app open shows last-known data on every tab with the stale banner; switching accounts never shows the previous user's data.

---

## PHASE 6 — Form Autofill + JD-tailored resume (major feature)

**Product rule reminder: the agent fills, the human reviews and taps submit. No server-side form submission, ever.**

### Server
1. `server/services/form_parser.py` — deterministic (no LLM) Google Forms parser: fetch the public `viewform` URL (reuse the httpx/user-agent/timeout pattern from `fetch_manual_job_text`), extract the `FB_PUBLIC_LOAD_DATA_` JSON, parse into `FormSchema` (Pydantic): `title`, `description`, `questions[]` each with `entry_id`, `text`, `type` (short/paragraph/choice/checkbox/dropdown/date/file_upload), `options[]`, `required`. If the form requires sign-in to view, return a typed error the client maps to the WebView fallback message. For non-Google forms: strip HTML with BeautifulSoup and send text to a new LLM extraction task (same pattern/temperature as `extract_job_from_text`), flagged `source="llm_extracted"` with lower confidence.
2. New LLM task in `llm.py`: `map_profile_to_form(profile, form_schema, profile_id)` — system prompt: answer each question using ONLY information present in the profile; return null for anything the profile cannot answer; never invent phone numbers, emails, dates, IDs, or credentials; for choice questions pick strictly from the provided options. Temp 0.2. Validates `FormFillResponse`: `[{entry_id, question, answer|null, confidence, source_field}]`. Standard one-retry + `llm_calls` logging. **Deterministic post-check (mini-guardrail):** in Python, verify every choice/checkbox/dropdown answer is an exact member of that question's options; flag mismatches `guardrail_pass=false`.
3. JD handling: if the form description contains a plausible JD (length heuristic), pipe it through the existing `extract_job_from_text` → `POST /jobs/manual` flow to create a job row; otherwise the client asks the user to paste the JD. Then the **existing** tailoring pipeline (`POST /tailor/{job_id}` → guardrail → diff → approve → Phase 4B PDF) runs unchanged.
4. New router `routers/forms.py`: `POST /forms/parse` (URL in body → FormSchema), `POST /forms/fill` (form schema or id + profile → mapped answers), optional `form_fills` table (migration) to persist fills for history. All auth’d via `get_current_profile`.
5. Prefill URL builder (pure Python): from approved answers, construct `<form_url>?usp=pp_url&entry.<id>=<urlencoded answer>&...` (repeat params for checkboxes). File-upload questions are explicitly listed as "attach manually" — Google does not allow prefilled/programmatic file answers.

### Client
6. New entry point "Fill an application form" (from Jobs tab header action and/or Home quick action) → `FormFillScreen`: paste URL → parse → review list of question/answer rows, each editable, null/low-confidence/guardrail-failed rows visually flagged exactly like guardrail failures in the diff screen → optional "Tailor resume for this JD" branch (jumps into the existing tailoring flow, returns with a PDF ready) → "Open prefilled form" button → in-app WebView (`webview_flutter`) or external browser loading the prefilled URL. The user is signed into Google in that browser context with whichever account they choose (Google's own account picker — we never touch Google credentials), attaches the tailored PDF to any file-upload question manually, and taps Google's Submit button themselves.
7. Restricted forms: show "This form requires sign-in to view — open it in the browser, sign in, then use 'Fill from page' " (v2: WebView JS-injection fill; scaffold the screen but it may ship behind a flag).

**Acceptance:** a public Google Form with text/choice questions round-trips: paste → parsed → answers mapped only from real profile data (nulls where unknown) → edited → opens prefilled in browser → human submits. No network call ever POSTs to `formResponse` from our server or app.

---

## PHASE 7 — Verification & housekeeping

- Run `flutter analyze`, `flutter test`, `pytest server/tests` — all clean/green. Add tests for: `form_parser` (fixture HTML), the choice-answer mini-guardrail, task-status transitions, currency formatting, freshness filter.
- Update `docs/PROMPTS.md`: fix the stale `text-embedding-004` reference (now `gemini-embedding-001`), add the new form-mapping prompt section.
- Append new ADR entries to `DECISIONS.md` for: async task pattern, ATS PDF generation choice (ReportLab), form-autofill submission model (prefill-URL + human submit).
- Update `.env.example` if any new config was added.
- List every manual step I must do myself (Supabase dashboard redirect URLs, applying SQL migrations in the SQL Editor, Render env changes) in a final `MANUAL_STEPS.md`.

---

## FINAL DELIVERABLE — Future roadmap proposals

After all phases, write `docs/ROADMAP_PROPOSALS.md` proposing next-phase features NOT covered above, each with a one-paragraph rationale and rough effort estimate. Seed ideas to evaluate and expand (add your own): interview-prep question packs generated per match from JD + gaps; cover-letter generation reusing the tailor+guardrail pattern; application deadline reminders via the existing pipeline/FCM; salary insights & negotiation ranges from Adzuna salary data already ingested; job alerts by saved search; multi-resume profiles (different base resumes per role family); referral finder (surface LinkedIn search links, no scraping); weekly progress email digest via Resend; Flutter Web client (backend is already client-agnostic); dark theme (token system makes it cheap); Riverpod migration when state-sharing pain justifies it; CI via GitHub Actions (pytest + flutter analyze/test on push); `render.yaml` for reproducible deployment; iOS support (APNs + second Firebase app) as a distinct milestone.
