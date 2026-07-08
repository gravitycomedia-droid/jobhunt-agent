# BRICKS.md — Implementation prompts for Claude Code

> How to use: start each work session by opening this file. Copy the prompt for your current brick into Claude Code. Each prompt assumes CLAUDE.md context is loaded (it is, automatically). Finish the definition-of-done, tick the checkbox in CLAUDE.md, commit, then stop — don't build ahead.

---

## BRICK 1 — Foundations
**Paste into Claude Code:**
```
We're on Brick 1. Goals: (1) scaffold the Flutter app in /app with a single home
screen, (2) scaffold FastAPI in /server with a GET /health endpoint returning
{"data": {"status": "ok", "time": <iso>}, "error": null}, (3) create an ApiClient
service in app/lib/services/api_client.dart that fetches /health and displays the
result on the home screen with loading and error states.
Teach me the Dart parts: explain the widget tree, setState, and async/await in
Dart as you write them — I know FlutterFlow visually but not Dart.
Also create .gitignore entries for .env, build/, and .dart_tool/.
```
**Definition of done:** phone shows live data from your local FastAPI. Commit: `feat(brick-1): flutter-fastapi loop working`.
**Manual step first:** install Flutter SDK (docs.flutter.dev/get-started), Android Studio + a device/emulator, Python 3.11+.

---

## BRICK 2 — Resume Parser
**Manual steps first:** get GEMINI_API_KEY from aistudio.google.com → copy .env.example to server/.env and fill it.
**Paste into Claude Code:**
```
Brick 2. Build the resume parsing pipeline:
1. server: POST /resume/parse accepting a PDF upload. Convert pages to images
   (pdf2image + poppler), send to Gemini vision with the parser prompt in
   docs/PROMPTS.md. Validate against a ResumeProfile Pydantic model. On
   validation failure retry ONCE with the error appended. Log to llm_calls.
2. server: save the parsed profile + raw text to Supabase profiles table.
3. app: a screen with a file picker (file_picker package) to upload the PDF,
   then a profile review screen showing parsed fields in editable text fields
   with a Confirm button that PATCHes /resume/profile.
Explain Dart null-safety operators the first time they appear.
```
**Definition of done:** your real resume parses accurately and is editable in the app.

---

## BRICK 3 — Job Ingestion
**Manual steps first:** create Supabase project → enable vector extension → run migrations/001_core_schema.sql in SQL Editor. Get Adzuna keys (developer.adzuna.com) + RapidAPI key (JSearch, Basic free plan). Fill .env.
**Paste into Claude Code:**
```
Brick 3. Build job ingestion:
1. server/services/job_sources.py: async clients for Adzuna and JSearch using
   TARGET_ROLES and TARGET_LOCATIONS from env. Normalize both into one JobIn
   Pydantic model.
2. Dedup: dedup_key = slugified(title)|slugified(company)|slugified(location);
   use rapidfuzz (ratio >= 90) against recent jobs before insert.
3. POST /jobs/refresh triggers a fetch cycle; GET /jobs lists newest first
   with pagination.
4. app: jobs list screen — card per job (title, company, location, source
   chip), pull-to-refresh calling /jobs/refresh.
Write pytest tests for the dedup function with tricky near-duplicate cases.
```
**Definition of done:** fresh deduplicated jobs from two sources visible in the app.

---

## BRICK 4 — Embeddings + Vector Search
**Paste into Claude Code:**
```
Brick 4. Add semantic matching stage 1:
1. server/services/embeddings.py: embed_text() using text-embedding-004,
   with batching and llm_calls logging.
2. Embed profile on save; embed each job at ingestion (backfill existing).
3. GET /matches/shortlist: call the match_jobs_by_similarity SQL function
   (top 50), join job details, return sorted by similarity.
4. app: shortlist screen with a similarity bar per card.
Explain to me in comments how cosine distance works and why we use the <=>
operator, in 5 lines or less.
```
**Definition of done:** shortlist is visibly more relevant at the top; you can articulate why.

---

## BRICK 5 — LLM Re-Ranker
**Paste into Claude Code:**
```
Brick 5. Stage 2 of RAG:
1. server/services/matching.py: rerank_top_jobs(profile_id, n=20) — for each
   shortlisted job WITHOUT an existing match row, call Gemini with the
   re-rank prompt from docs/PROMPTS.md, validate MatchResult (fit_score,
   strengths, gaps, compensators, verdict, one_line_reason), upsert to
   matches. Cache: never re-rank the same (profile, job) pair.
2. GET /matches: joined match+job data sorted by fit_score.
3. app: match cards — score in a circular indicator, strengths (green),
   gaps (amber), verdict chip, expandable reason.
4. Add GET /stats/llm returning daily token totals from llm_calls so I can
   watch my costs.
Write a pytest test that mocks Gemini and asserts caching prevents duplicate calls.
```
**Definition of done:** honest ranked matches with reasons you agree with; token stats visible.

---

## BRICK 6 — Tailoring + Guardrail
**Paste into Claude Code:**
```
Brick 6. The anti-fabrication system (read ADR-004 in DECISIONS.md first):
1. server/services/guardrail.py: verify_bullets(pairs, raw_resume_text) —
   each 'original' must fuzzy-match (rapidfuzz >= 85) somewhere in the resume
   text. Return pass/fail per bullet. THIS FUNCTION GETS THOROUGH PYTESTS,
   including an LLM-invented bullet case.
2. POST /tailor/{job_id}: Gemini with the tailoring prompt (docs/PROMPTS.md),
   validate, run guardrail, store in tailored_resumes with guardrail_flags.
3. app: diff view screen — original vs tailored side by side; guardrail
   failures highlighted red requiring individual approval taps; Approve All
   only enabled when zero red flags remain. Export as copyable text.
```
**Definition of done:** one-tap tailored resume; invented content is impossible to miss.

---

## BRICK 7 — Application Tracker
**Paste into Claude Code:**
```
Brick 7. Pipeline Kanban:
1. server: CRUD for applications; PATCH /applications/{id}/state enforces the
   state machine (saved→applied→replied→interview→offer|rejected; rejected
   reachable from any state). Invalid transitions return 422.
2. GET /applications/stale: applied with no state change in 7+ days.
3. app: Kanban board (horizontal columns, drag or move-button), notes editor,
   and a "Needs follow-up" banner fed by /stale.
Explain how you're structuring Flutter state for drag-and-drop, and introduce
Riverpod here if state is getting messy — teach me the basics as you do.
```
**Definition of done:** whole search visible on one board; stale applications surface themselves.

---

## BRICK 8 — Agent Loop
**Manual steps first:** create Firebase project, add the Flutter app via FlutterFire CLI, download service-account JSON to server/.
**Paste into Claude Code:**
```
Brick 8. Make it an agent:
1. server/jobs/daily_pipeline.py: orchestrate fetch → embed → shortlist →
   rerank → detect stale apps → send FCM push ("N strong matches today").
   Idempotent (safe to run twice). Runnable via `python -m jobs.daily_pipeline`.
2. Follow-up drafts: for stale applications, generate a polite follow-up email
   draft (prompt in docs/PROMPTS.md), store for approval — NEVER auto-send.
3. app: FCM integration with deep-link to matches screen; agent activity log
   screen (what ran, when, what it found); follow-up approval screen with
   copy-to-clipboard.
4. Add a Render cron job config note to README (daily at DAILY_PIPELINE_HOUR).
```
**Definition of done:** you wake up to a push notification and review matches over coffee.

---

## BRICK 9 — Auth + Polish
**Paste into Claude Code:**
```
Brick 9. Multi-user readiness:
1. Supabase auth (email + Google) in Flutter; send JWT to server; verify in a
   FastAPI dependency; scope every query by user_id. Add RLS policies SQL as
   migrations/002_rls.sql.
2. Onboarding: 3-screen flow (welcome → upload resume → set target roles).
3. Polish pass: loading skeletons, empty states with guidance, error retry,
   friendly copy. List every screen and what state it's missing, then fix.
4. Rate limiting on expensive endpoints (slowapi).
```
**Definition of done:** a stranger can sign up and get matches without help. Then recruit 3–5 beta users.

---

## BRICK 10 — Ship + Tell
**Paste into Claude Code:**
```
Brick 10. Launch package:
1. Generate a README.md: project story, architecture diagram (mermaid),
   feature GIF placeholders, local setup guide, link to DECISIONS.md.
2. Play Store checklist: signed release build steps, listing copy (title,
   short + full description), privacy policy markdown for GitHub Pages.
3. A LAUNCH.md with my launch-post drafts for LinkedIn and r/SideProject,
   and the 90-second demo video shot list.
Pull real metrics from llm_calls for the README (validation pass rate,
avg tokens/day, guardrail catch count).
```
**Definition of done:** live on Play Store, public repo, demo video, launch post. The agent now works for YOU.
