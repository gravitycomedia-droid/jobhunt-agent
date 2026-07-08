# CLAUDE.md — Job-Hunt Agent

## What this project is
An AI-powered job-search agent mobile app. It hunts jobs daily, scores them against the user's resume using two-stage RAG (embeddings filter → LLM re-rank), tailors resumes per job with an anti-fabrication guardrail, and tracks applications in a pipeline. The user approves; the agent executes.

**Builder context:** First "real" mobile project. Background: Python full-stack (strong), FlutterFlow (visual only — new to hand-written Dart/Flutter), experienced with AI/LLM APIs. Optimize explanations toward Flutter/Dart concepts; be terser on Python.

## Monorepo structure
```
jobhunt-agent/
├── CLAUDE.md              ← you are here
├── DECISIONS.md           ← architecture decision log (UPDATE when we make tradeoffs)
├── .env.example           ← template for secrets (NEVER commit real .env)
├── app/                   ← Flutter mobile app
│   ├── lib/
│   │   ├── main.dart
│   │   ├── screens/       ← one file per screen
│   │   ├── widgets/       ← reusable components
│   │   ├── services/      ← API client, FCM, auth
│   │   └── models/        ← Dart data classes mirroring server schemas
│   └── pubspec.yaml
├── server/                ← FastAPI backend
│   ├── main.py            ← app entry, router registration
│   ├── routers/           ← one file per resource (resume, jobs, matches, applications)
│   ├── services/          ← llm.py, embeddings.py, job_sources.py, matching.py, guardrail.py
│   ├── models/            ← Pydantic schemas (single source of truth for data shapes)
│   ├── db/                ← supabase client, migrations/*.sql
│   ├── jobs/              ← daily_pipeline.py (the agent loop, run by cron)
│   └── requirements.txt
└── docs/                  ← brick plans, prompts library
```

## Tech stack (do not substitute without discussion)
- **Mobile:** Flutter (Dart), Riverpod for state (introduce only from Brick 5+), `http` package for API calls
- **Backend:** FastAPI + Pydantic v2, Python 3.11+
- **DB:** Supabase Postgres with pgvector extension. Access via `supabase-py` from the server ONLY.
- **LLM:** Google Gemini — `gemini-2.5-flash` for all generation, `text-embedding-004` for embeddings
- **Jobs data:** Adzuna API (primary) + JSearch via RapidAPI (secondary). NO scraping — legal APIs only.
- **Push:** Firebase Cloud Messaging
- **Hosting:** Render (web service + cron job)

## Golden rules (enforce these in every code review)
1. **Secrets live in server/.env only.** The Flutter app must NEVER contain API keys. Phone talks to our FastAPI server; server talks to everything else.
2. **LLMs handle language; code handles logic.** Scores are computed in Python. Pipeline states are a state machine. Diffs are algorithms. Never ask the LLM to do arithmetic or make state decisions.
3. **Every LLM output is schema-validated.** Pydantic model per LLM task. On validation failure: retry ONCE with the error appended to the prompt. On second failure: log and return a graceful error.
4. **Anti-fabrication guardrail is sacred.** Every tailored resume bullet must trace back to a real source bullet via the post-check in `services/guardrail.py`. Untraceable bullets get flagged, never silently accepted.
5. **Log every LLM call** to the `llm_calls` table: prompt hash, model, tokens in/out, latency ms, validation pass/fail. No exceptions.
6. **One brick at a time.** Do not build ahead. Each brick ends with something demonstrable. Resist scaffolding future features.

## Current status
- [x] Brick 1: Foundations (Flutter↔FastAPI loop)
- [x] Brick 2: Resume parser (vision LLM → structured profile)
- [ ] Brick 3: Job ingestion (Adzuna + JSearch + dedup + Supabase)
- [ ] Brick 4: Embeddings + pgvector search
- [ ] Brick 5: LLM re-ranker (two-stage RAG complete)
- [ ] Brick 6: Resume tailoring + guardrail + diff view
- [ ] Brick 7: Application tracker (Kanban)
- [ ] Brick 8: Agent loop (cron + FCM push + follow-up drafts)
- [ ] Brick 9: Auth + polish + beta users
- [ ] Brick 10: Play Store launch + README + demo video

**UPDATE the checkbox above when a brick's definition-of-done is met.**

## Coding conventions
- **Python:** type hints everywhere, black formatting, async endpoints in FastAPI, service functions pure where possible (easy to test).
- **Dart:** follow flutter_lints defaults. Prefer StatelessWidget until state is truly needed. One screen = one file in `screens/`.
- **API design:** REST, JSON, snake_case fields. Server returns `{"data": ..., "error": null}` envelope consistently.
- **Errors:** never swallow exceptions silently. Server logs with context; app shows human-readable messages with a retry option.
- **Tests:** pytest for `services/` functions (especially guardrail.py and matching.py — these MUST have tests). Widget tests optional for v1.
- **Commits:** conventional style — `feat(brick-3): add adzuna client with dedup`. Commit at least once per work session.

## Teaching mode (important)
The builder is learning Flutter/Dart. When writing Dart code:
- Add brief comments mapping concepts to FlutterFlow equivalents where helpful ("this Column = FlutterFlow's Column widget")
- Explain any non-obvious Dart idiom (null safety `?`/`!`, `async`/`await`, `late`) the FIRST time it appears
- For Python, skip beginner explanations — the builder is fluent

## What NOT to do
- No LangChain/LangGraph for v1 — plain Python orchestration is simpler and more instructive
- No Docker for v1 — Render deploys from repo directly
- No scraping LinkedIn/Naukri/Indeed — ToS violation, account bans
- No auto-submitting applications anywhere — human approval gates always
- No dedicated vector DB (Pinecone/Weaviate) — pgvector is the deliberate choice (see DECISIONS.md)
- Don't add features not in the current brick, even if easy
