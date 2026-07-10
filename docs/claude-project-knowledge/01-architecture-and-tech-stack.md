# Architecture & Tech Stack

## Monorepo layout

```
jobhunt-agent/
├── CLAUDE.md              ← project rules/instructions for AI coding assistants
├── DECISIONS.md           ← architecture decision log (10 ADRs so far)
├── .env.example            ← template for secrets (never a real .env is committed)
├── app/                    ← Flutter mobile app
│   ├── lib/
│   │   ├── main.dart
│   │   ├── screens/        ← one file per screen (25 files)
│   │   ├── widgets/        ← reusable design-system components (16 files)
│   │   ├── theme/           ← design tokens + ThemeData assembly
│   │   ├── services/        ← api_client.dart, push_service.dart
│   │   ├── config/           ← supabase_config.dart
│   │   └── models/           ← Dart classes mirroring server schemas (11 files)
│   ├── android/, ios/, macos/, windows/, linux/  ← platform shells
│   └── pubspec.yaml
├── server/                 ← FastAPI backend
│   ├── main.py              ← app entry, router registration, CORS, /health
│   ├── config.py             ← Pydantic Settings, loads .env
│   ├── routers/              ← one file per resource
│   ├── services/              ← llm.py, embeddings.py, job_sources.py, matching.py,
│   │                            guardrail.py, dedup.py, job_ingestion.py, auth.py,
│   │                            activity.py, cost_stats.py, email.py, notify.py,
│   │                            skill_growth.py
│   ├── models/                ← Pydantic schemas (single source of truth for shapes)
│   ├── db/                     ← supabase_client.py, migrations/*.sql (8 migrations)
│   ├── jobs/daily_pipeline.py  ← the agent loop, triggered by Render cron
│   ├── tests/                  ← 6 pytest files
│   ├── Dockerfile
│   └── requirements.txt
└── docs/
    ├── PROMPTS.md            ← human-readable source of truth for every LLM prompt
    └── claude-project-knowledge/  ← this folder
```

A separate untracked reference folder, `Job-Hunt Agent design system/`, at the
repo root holds an HTML/CSS prototype (23 screen states) that the Flutter
frontend rebuild (ADR-009) was built to match — design tokens, component specs,
and screenshots live there.

## Tech stack (deliberate choices — do not substitute without discussion)

| Layer | Choice | Notes |
|---|---|---|
| Mobile client | Flutter (Dart) | No Riverpod/Provider/Bloc yet — plain `StatefulWidget` + `setState` throughout. No routing package (no `go_router`) — imperative `Navigator.push/pop`. |
| Backend | FastAPI + Pydantic v2, Python 3.11+ | Async endpoints, response envelope `{"data": ..., "error": null}` everywhere. |
| Database | Supabase Postgres + pgvector extension | Accessed only from the server, via `supabase-py`, using the **service-role key** (bypasses RLS — the server itself is the authorization boundary, not Postgres RLS). |
| LLM (generation) | Google Gemini `gemini-2.5-flash` | All text/vision generation tasks — resume parsing, re-ranking, tailoring, follow-up drafts, job extraction, skill-growth clustering. |
| LLM (embeddings) | Google Gemini `gemini-embedding-001` | Pinned to 768-dim output (`output_dimensionality=768`) to match `vector(768)` Postgres columns. (Switched from `text-embedding-004`, which 404'd on this API key — see ADR-006.) |
| Jobs data | Adzuna API (primary) + JSearch via RapidAPI (secondary) | No scraping, anywhere, ever — legal APIs only (ADR-003). |
| Auth | Supabase Auth (Google OAuth + email/password) | Server never decodes JWTs itself; delegates verification to Supabase's Auth API per request. |
| Push notifications | Firebase Cloud Messaging | Android-only by design (no iOS APNs key provisioned yet — ADR-007). |
| Transactional email | Resend | Used only for follow-up email sending, gated behind explicit user approval. |
| Hosting | Render | Web service (Dockerfile-based, not the native Python buildpack, because `pdf2image` needs `poppler-utils`) + a cron-triggered pipeline endpoint. No `render.yaml` — service/env vars configured directly in the Render dashboard/API (not currently reproducible from the repo alone). |

## High-level data flow

```
Flutter app  ──HTTP (Bearer <Supabase session token>)──▶  FastAPI server
                                                              │
                                                              ├─▶ Supabase Postgres+pgvector (profiles, jobs, matches,
                                                              │     applications, tailored_resumes, llm_calls)
                                                              ├─▶ Supabase Auth (token verification)
                                                              ├─▶ Google Gemini (generation + embeddings)
                                                              ├─▶ Adzuna / JSearch (job sourcing)
                                                              ├─▶ Resend (follow-up email send)
                                                              └─▶ Firebase Admin SDK → FCM (push notifications)
```

The phone **never** talks to Gemini, Supabase, Adzuna, Resend, or Firebase
directly — everything is proxied and orchestrated by the FastAPI server. This is
Golden Rule 1 in [00-overview.md](00-overview.md).

## Why these choices (see [08-decisions-log.md](08-decisions-log.md) for full ADRs)

- **Two-stage RAG over pure-LLM matching**: sending ~500 jobs/day straight to an
  LLM is too costly; a pgvector cosine-similarity shortlist (top 50, ~20ms) feeds
  only the top 20 to the LLM for reasoning — roughly a 96% reduction in LLM
  tokens versus naive matching.
- **pgvector over a dedicated vector DB** (Pinecone/Weaviate/Qdrant): unnecessary
  complexity at a few thousand vectors; one datastore for relational + vector +
  auth + storage. Revisit only past ~1M vector rows.
- **No LangChain/LangGraph**: plain Python orchestration is simpler and more
  instructive for a first hand-rolled agent system.
- **No Docker for the Flutter side, Docker only for the server**: Render deploys
  the Flutter app's backend from a Dockerfile (needed for `poppler-utils`); the
  app itself ships as an APK/IPA, not containerized.
