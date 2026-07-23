# FirstRole

**An AI job-hunting agent for Android.** It hunts jobs daily, scores each against
your résumé with two-stage RAG (embeddings filter → LLM re-rank), tailors your
résumé per job behind an anti-fabrication guardrail, drafts follow-ups, and
tracks applications in a pipeline. **You approve; the agent executes** — every
consequential, external-facing action requires a deliberate human press.

> Repo/server name is `jobhunt-agent`; the shipped product is **FirstRole**
> (ADR-029). UI-facing strings say FirstRole.

---

## What it does

- **Daily agent loop** — a Cloud Scheduler cron refreshes a shared job pool, re-ranks each user's matches, drafts follow-ups, and sends a push.
- **Two-stage matching** — pgvector cosine shortlist (Stage 1) → role-aware LLM re-rank (Stage 2). Scores are computed in Python; the LLM only ranks.
- **Résumé tailoring** — per-JD rewrite with a deterministic guardrail: every factual claim must trace back to your real résumé, or it's flagged. Output is a one-page, ATS-safe PDF.
- **Apply via Google Forms** — deterministic form parse + prefill URL; you attach the PDF and submit (the agent never auto-submits).
- **Application tracker** — six-column Kanban (`saved → applied → replied → interview → offer → rejected`).

## Architecture

```
jobhunt-agent/
├── app/        Flutter (Dart) Android app — screens, widgets, services, theme
├── server/     FastAPI backend — routers, services, Pydantic models, jobs/, db/migrations/
└── docs/       Brick plans, ADR-driven knowledge pack, execution plans
```

- **Golden Rule 1:** secrets are server-side only. The Flutter app holds the Supabase URL + anon key and nothing else; the phone talks to our FastAPI server, the server talks to everything else.
- **Golden Rule 2:** LLMs handle language; code handles logic. Scores, state machines, money, diffs, and counts are all Python.

## Tech stack

| Layer | Choice |
|---|---|
| Mobile | Flutter (Dart), `http`, `supabase_flutter`, `firebase_messaging` |
| Backend | FastAPI + Pydantic v2, Python 3.11+ |
| DB | Supabase Postgres + `pgvector` (via `supabase-py`, server only) |
| LLM | Gemini `gemini-2.5-flash` (vision `parse`, default `tailor`) + DeepSeek `deepseek-v4-flash` (rerank / extract / followup / skill-growth / forms) behind one validate/retry/log flow (ADR-023) |
| Embeddings | Gemini `gemini-embedding-001` (768-dim) |
| Jobs data | Adzuna + JSearch (RapidAPI) + Greenhouse/Lever boards; supplementary no-login Apify (LinkedIn/Indeed/Naukri/Internshala) + Unstop, **daily-cron only** (ADR-003 v2) |
| Push | Firebase Cloud Messaging (Android only) |
| Hosting | Google Cloud Run (`asia-south1`); Cloud Scheduler OIDC-triggered pipeline |

## Local development

**Server**
```bash
cd server
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp ../.env.example .env      # fill in keys — never commit real .env
uvicorn main:app --reload    # http://localhost:8000
pytest                       # services/ tests (guardrail + matching are mandatory)
```

**App**
```bash
cd app
flutter pub get
flutter analyze
# point at a local server (emulator uses 10.0.2.2):
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

The app defaults to the live Cloud Run URL when `API_BASE_URL` is not supplied.

## Deployment

The server runs on **Google Cloud Run** (migrated off Render — ADR-014). A
`git push` deploys nothing; deployment is a manual, user-approved
`gcloud run deploy --source .` that builds `server/Dockerfile` (the container
bundles `poppler-utils` for vision PDF parsing). Database migrations in
`server/db/migrations/` are applied manually in the Supabase SQL Editor. See
[`MANUAL_STEPS.md`](MANUAL_STEPS.md).

## Documentation map

| File | What it holds |
|---|---|
| [`CLAUDE.md`](CLAUDE.md) | Project charter, golden rules, conventions, brick status |
| [`DECISIONS.md`](DECISIONS.md) | Architecture decision log (ADRs) |
| [`MANUAL_STEPS.md`](MANUAL_STEPS.md) | Dashboard/CLI steps that aren't code-executable |
| [`docs/claude-project-knowledge/`](docs/claude-project-knowledge/) | Detailed subsystem reference pack |
| [`docs/20-frontend-rebuild-master-plan.md`](docs/20-frontend-rebuild-master-plan.md) | Current execution plan (frontend rebuild + résumé-quality track) |

## Status

Bricks 1–9 complete (foundations → auth + multi-tenant scoping + polish). Brick
10 (Play Store launch) is in progress. The frontend v2 rebuild and the
résumé-quality overhaul are tracked in the master plan above.

## Constraints (non-negotiable)

- No login-based scraping of any job board, ever.
- No auto-submitting applications, emails, or forms — human approval gates always.
- Every LLM output is schema-validated and logged; every consequential UI action is press-and-hold.
- All money is stored as integer paise, rendered in ₹.

*iOS is out of scope (no APNs key). This is an Android-first personal-scale project.*
