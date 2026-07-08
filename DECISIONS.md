# DECISIONS.md — Architecture Decision Log

> Every significant tradeoff gets an entry. Recruiters and interviewers read this file — it proves reasoned engineering, not just working code. Format: Context → Decision → Alternatives considered → Consequences.

---

## ADR-001: Two-stage RAG matching (embeddings filter → LLM re-rank)
**Date:** project start · **Status:** accepted

**Context:** ~500 new jobs arrive daily. Sending every job description to an LLM for fit evaluation would cost ~400k tokens/day and take minutes.

**Decision:** Stage 1 — pgvector cosine similarity shortlists top 50 jobs (free, ~20ms). Stage 2 — LLM re-ranks only the top 20 with structured reasoning.

**Alternatives considered:** (a) LLM-evaluate everything: too slow/costly, doesn't scale past one user. (b) Keyword matching only: misses semantic matches (e.g., "cross-platform mobile dev" ↔ "Flutter engineer"). (c) Embeddings only, no LLM: no reasoning, no gap analysis — scores without explanations aren't trustworthy.

**Consequences:** ~96% reduction in LLM tokens with negligible recall loss. The pattern mirrors production RAG systems, making the codebase a portfolio artifact for exactly that skill.

---

## ADR-002: pgvector inside Supabase instead of a dedicated vector DB
**Date:** project start · **Status:** accepted

**Context:** Need vector similarity search for embeddings. Pinecone/Weaviate/Qdrant are purpose-built options.

**Decision:** Use the pgvector extension inside the existing Supabase Postgres.

**Alternatives considered:** Dedicated vector DBs offer better performance at millions of vectors — but this app stores thousands. A second datastore means a second thing to learn, secure, sync, and pay for.

**Consequences:** One database for relational data, vectors, auth, and storage. Simplicity chosen deliberately at our scale; revisit only if vectors exceed ~1M rows.

---

## ADR-003: Legal job APIs only — no scraping
**Date:** project start · **Status:** accepted

**Context:** LinkedIn/Naukri have the richest listings, but scraping violates ToS, risks account bans, and produces brittle code.

**Decision:** Adzuna API (primary) + JSearch/RapidAPI (secondary, surfaces Google-for-Jobs results legally). Dedup layer merges feeds.

**Alternatives considered:** Scraping: legally grey, maintenance nightmare. Manual paste-a-job feature kept as a supplement for postings outside our feeds.

**Consequences:** Slightly narrower coverage, fully compliant and stable. Designing around API limits is itself demonstrable engineering maturity.

---

## ADR-004: Anti-fabrication guardrail with deterministic post-check
**Date:** project start · **Status:** accepted

**Context:** LLM resume tailoring can hallucinate skills/experience. A fabricated resume harms the user materially (and ethically).

**Decision:** Tailoring prompt returns `{original, tailored}` pairs. Python post-check (`services/guardrail.py`) verifies every `original` exists verbatim-or-fuzzy (threshold ≥ 0.85) in the stored resume. Failures are flagged red in the diff UI and require explicit manual approval.

**Alternatives considered:** Prompt-only instruction ("don't fabricate"): unenforceable, models drift. Human review alone: users skim and miss inventions.

**Consequences:** A verifiable safety property, testable in pytest. LLM handles language; code enforces truth — the boundary this whole project is built on.

---

## ADR-005: Switched from gemini-2.0-flash to gemini-2.5-flash
**Date:** 2026-07-08 · **Status:** accepted

**Context:** Brick 2's first real `/resume/parse` call against a live Gemini API key failed with `429 RESOURCE_EXHAUSTED`, `limit: 0`. Checking the project's Gemini API Rate Limit dashboard confirmed `Gemini 2 Flash` shows 0/0 RPM, TPM, and RPD on the free tier — not a temporary quota exhaustion, but zero free-tier allocation for that model on this project. `Gemini 2.5 Flash` and `Gemini 2.5 Flash Lite` both show real free-tier allowances (5–10 RPM, 250K TPM, 20 RPD).

**Decision:** Standardize on `gemini-2.5-flash` for all generation tasks (parse, rerank, tailor, followup) and keep `text-embedding-004` for embeddings. Updated in `CLAUDE.md`, `.env.example`, `server/.env`, and `docs/PROMPTS.md`.

**Alternatives considered:** `gemini-2.5-flash-lite` — slightly higher RPM (10 vs 5) and same RPD (20/day), but lower quality for vision-based resume extraction where accuracy matters most. Since this is a single-user app making a handful of calls per day, the RPM difference is irrelevant and quality wins.

**Consequences:** No code changes needed beyond the model string — `services/llm.py` reads the model from `Settings.gemini_model`, not a hardcoded literal, so this was a one-line config change everywhere it's pinned. Worth re-checking the rate-limit dashboard if Google deprecates another model tier during the project.

---

## ADR-006: (template — copy for your next decision)
**Date:** · **Status:** proposed
**Context:**
**Decision:**
**Alternatives considered:**
**Consequences:**
