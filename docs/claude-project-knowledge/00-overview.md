# Job-Hunt Agent — Project Overview

> This folder is a set of reference documents meant to be uploaded to a Claude.ai
> Project's knowledge base, so a fresh Claude conversation can understand this
> project without re-deriving it from the codebase each time. Each file covers one
> slice of the system. Start here, then read the file that matches what you're
> discussing.
>
> Generated: 2026-07-10, from a direct inventory of the codebase (not from memory).
> Treat this as a snapshot — verify against the live repo before relying on any
> specific file path, function name, or line of code for an active change.

## What this is

Job-Hunt Agent is an AI-powered job-search assistant delivered as a mobile app
(Flutter) backed by a FastAPI server. It automates the tedious parts of a job
search while keeping a human in the loop for every consequential action:

1. **Parses** a candidate's resume PDF into a structured profile using a vision LLM.
2. **Hunts** for jobs daily from legal job-board APIs (Adzuna, JSearch), dedupes them,
   and stores them in a shared pool.
3. **Matches** jobs to the candidate using two-stage RAG: a cheap vector-similarity
   shortlist (pgvector), then an LLM re-rank of only the most promising candidates,
   producing a fit score, strengths, gaps, and a verdict (apply / stretch / skip).
4. **Tailors** the candidate's resume bullets per job — rephrasing and reordering
   existing content to target the job description — while a deterministic
   fuzzy-matching guardrail (not the LLM) verifies every tailored bullet traces back
   to something the candidate actually wrote. Nothing is fabricated.
5. **Tracks** applications through a Kanban pipeline (saved → applied → replied →
   interview → offer / rejected), including drafting (and, on approval, sending)
   follow-up emails after 7 days of silence.
6. **Runs autonomously once a day** via a cron-triggered pipeline that refreshes
   jobs, re-ranks matches, drafts follow-ups, and pushes a summary notification to
   the user's phone — but never submits an application or sends an email without
   explicit human approval.

The one-line mental model: **"The user approves; the agent executes."** Every
consequential, external-facing action (submitting an application, sending an
email) requires a tap from the human. The LLM never makes structural decisions
(scores, state transitions, diffs) — those are always plain Python. See
[08-decisions-log.md](08-decisions-log.md) and the golden rules below for why.

## Builder context

This is the builder's first "real" hand-written mobile app. Background: strong
Python full-stack experience, prior exposure to Flutter only through FlutterFlow
(visual, no-code), and solid experience with AI/LLM APIs. The project has
deliberately been built brick-by-brick (see
[09-status-and-roadmap.md](09-status-and-roadmap.md)) rather than all at once, to
keep each stage demonstrable and to build real Flutter/Dart fluency alongside the
product.

## The five non-negotiable rules ("Golden Rules")

These are enforced in every code review and referenced throughout the other
documents in this folder:

1. **Secrets live server-side only.** The Flutter app never holds an LLM/API key.
   The phone talks only to the FastAPI server; the server talks to everything else
   (Gemini, Supabase, Adzuna, JSearch, Resend, FCM).
2. **LLMs handle language; code handles logic.** Match scores, Kanban state
   transitions, resume diffs, and cost/frequency statistics are all computed in
   plain Python — never delegated to an LLM's arithmetic or judgment.
3. **Every LLM output is schema-validated** against a Pydantic model. On
   validation failure, the system retries exactly once with the error appended to
   the prompt; on a second failure it logs and returns a graceful error.
4. **The anti-fabrication guardrail is sacred.** Every tailored resume bullet must
   be traceable to a real source bullet via a deterministic fuzzy-match check.
   Untraceable bullets are flagged in the UI, never silently accepted.
5. **Every LLM call is logged** (prompt hash, model, tokens in/out, latency,
   validation pass/fail) to a `llm_calls` table — no exceptions. This powers the
   in-app cost dashboard.

Two more product-level rules worth knowing: no *direct/login* scraping of
LinkedIn/Naukri/Indeed; scoped Apify-based scraping is approved for personal use
per ADR-003 (amended). And no auto-submitting applications anywhere — human
approval gates always.

## Document index

| File | Covers |
|---|---|
| [01-architecture-and-tech-stack.md](01-architecture-and-tech-stack.md) | Monorepo layout, full tech stack, high-level data flow |
| [02-backend-api.md](02-backend-api.md) | FastAPI routers, every endpoint, service layer map, DB schema/migrations |
| [03-llm-and-prompts.md](03-llm-and-prompts.md) | Gemini models used, prompt library, validation/retry pattern, cost logging |
| [04-resume-parsing.md](04-resume-parsing.md) | Vision-LLM resume parsing pipeline (Brick 2) |
| [05-job-ingestion-and-matching.md](05-job-ingestion-and-matching.md) | Job sourcing, dedup, two-stage RAG matching (Bricks 3–5) |
| [06-resume-tailoring-and-guardrail.md](06-resume-tailoring-and-guardrail.md) | Resume tailoring + anti-fabrication guardrail (Brick 6) |
| [07-applications-and-agent-loop.md](07-applications-and-agent-loop.md) | Kanban tracker, daily cron pipeline, follow-ups, push notifications (Bricks 7–8) |
| [08-decisions-log.md](08-decisions-log.md) | Condensed architecture decision records (ADR-001 to ADR-010) with reasoning |
| [09-status-and-roadmap.md](09-status-and-roadmap.md) | What's built, what's uncommitted, what's next (Brick 10 and future scope) |
| [10-auth-and-security.md](10-auth-and-security.md) | Supabase Auth / Google OAuth, multi-tenancy, RLS, secrets handling |
| [11-frontend-flutter-app.md](11-frontend-flutter-app.md) | Every screen, model, service, the design system, and state management approach |
| [12-deployment-and-infra.md](12-deployment-and-infra.md) | Render hosting, Docker, Firebase project, environment variables |
