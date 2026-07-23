# LLM Usage, Prompts, and Cost Tracking

## Models

| Purpose | Model | Where configured |
|---|---|---|
| Vision `parse` + default `tailor` | `gemini-2.5-flash` | `Settings.gemini_model`, `server/config.py` |
| `rerank` / `extract_job` / `followup` / `skill_growth` / forms | DeepSeek `deepseek-v4-flash` (OpenAI-compatible SDK, thinking disabled) | `_TASK_PROVIDERS` in `services/llm.py` (ADR-023); absent `DEEPSEEK_API_KEY` falls back to Gemini |
| Embeddings | `gemini-embedding-001`, pinned to `output_dimensionality=768` | `Settings.gemini_embed_model` |

Both were changed mid-project after live API-key quota/availability issues —
see ADR-005 and ADR-006 in [08-decisions-log.md](08-decisions-log.md). Because
the model name is always read from config rather than hardcoded per call-site,
a future model swap is a one-line change.

## The central pattern: `server/services/llm.py`

Every generative task function follows the same shape:

```
build prompt (system + user)
  → call Gemini (_call_gemini(), temperature varies per task)
  → strip markdown fences (_strip_fences)
  → Model.model_validate_json(text)   # Pydantic schema validation
  → on ValidationError/ValueError:
        retry exactly ONCE, with the error message appended via a
        *_RETRY_SUFFIX template:
        "Your previous output failed validation with this error: {error}.
         Fix the issue and return ONLY the corrected JSON."
  → if still invalid after the retry: raise a task-specific *Error
  → on network/API failure: raise LlmApiError immediately, no retry
```

This is Golden Rule 3 from [00-overview.md](00-overview.md), implemented
identically across every task so there's exactly one place to reason about LLM
reliability.

## Every task, its prompt, and its schema

| Task function | System prompt intent (paraphrased) | Validates | Temp | Used by |
|---|---|---|---|---|
| `parse_resume(images, profile_id)` | "Extract information EXACTLY as written. Never infer, embellish, or add skills that are not explicitly stated." | `ResumeProfile` | 0.1 | Brick 2, [04-resume-parsing.md](04-resume-parsing.md) |
| `rerank_job(profile, job, profile_id)` | "Evaluate job fit... be honest about gaps — an inflated score harms the candidate. 80+ strong apply, 65–79 stretch, <65 skip." | `MatchResult` | 0.2 | Brick 5, [05-job-ingestion-and-matching.md](05-job-ingestion-and-matching.md) |
| `tailor_resume(bullets, job_description, profile_id)` | "You may REPHRASE, REORDER, EMPHASIZE existing content. You may NEVER invent experience/skills/metrics/employers, change dates/titles/durations, or add unlisted technologies." | `TailorLlmResponse` | 0.6 | Brick 6, [06-resume-tailoring-and-guardrail.md](06-resume-tailoring-and-guardrail.md) |
| `generate_followup_draft(job_title, company, applied_date, headline, profile_id)` | "Brief, warm, professional follow-up email... 90–120 words, no desperation, no guilt-tripping." | `FollowupDraft` | 0.7 | Brick 8, [07-applications-and-agent-loop.md](07-applications-and-agent-loop.md) |
| `extract_job_from_text(page_text, profile_id)` | "Extract information EXACTLY as stated. Never infer/embellish/guess — use null instead." (truncates to 12,000 chars) | `JobExtraction` | 0.1 | Frontend rebuild Phase 2, [05-job-ingestion-and-matching.md](05-job-ingestion-and-matching.md) |
| `generate_skill_growth(gaps, profile_id)` | Clusters numbered gap notes into skills + course/project suggestions; explicitly forbidden from inventing any percentage/score/"impact" number. | `SkillGrowthResponse` | 0.4 | Frontend rebuild Phase 4, [07-applications-and-agent-loop.md](07-applications-and-agent-loop.md) |

The human-readable source of truth for every prompt (kept in sync by hand with
the code) is **`docs/PROMPTS.md`**, which also documents 5 "prompt engineering
working rules": consistent temperature conventions per task type, schema
declared in both the prompt text and the Pydantic model, one retry maximum,
prefer few-shot examples before switching models, and document every prompt
change. Note: `docs/PROMPTS.md`'s embeddings section now correctly names
`gemini-embedding-001` (the old `text-embedding-004` reference was fixed in
Phase-7 housekeeping, with an inline comment recording the change).

## Embeddings (`server/services/embeddings.py`)

- `embed_content(model=gemini_embed_model, ..., task_type="SEMANTIC_SIMILARITY", output_dimensionality=768)`
- Batched: `_BATCH_SIZE = 50` (found empirically — 100 real long job descriptions
  tripped free-tier volume caps, 50 (~32K chars) did not).
- `profile_embedding_text(profile)` — flattens headline + skills first (strongest
  matching signal), then experience/project bullets.
- `job_embedding_text(job)` — flattens title + company first, then description.
- Symmetric cosine comparison (not asymmetric query/document retrieval) — profile
  and job text are embedded with the same template style deliberately.

## `llm_calls` logging (Golden Rule 5)

Every attempt — success, validation failure, or API failure — is logged via
`_log_llm_call()` in `llm.py` (up to 3 log points per task call) or
`_log_embed_call()` in `embeddings.py` (once per batch). Columns: `task`,
`model`, `prompt_hash`, `tokens_in`, `tokens_out`, `latency_ms`,
`validation_passed`, `retried`, `profile_id`, `created_at`.

- `prompt_hash` = first 16 hex chars of `sha256(SYSTEM_PROMPT)` — identifies
  which prompt template/version was used, not the exact per-request content.
- `tokens_in`/`tokens_out` come from `response.usage_metadata`.
- `profile_id` is `None` for `parse_resume` specifically, since no profile row
  exists yet at that point in the flow.
- Embedding calls log `tokens_in` as the batch's billable character count (no
  `tokens_out`, and no validation-failure retry logic, since there's no schema
  to validate — just a raw vector array).

## Cost dashboard (`server/services/cost_stats.py`, `GET /stats/costs`)

Pure Python, no LLM involved:
- `_PRICING_PER_MILLION_TOKENS` (USD per 1M tokens, in/out) covers **seven** models: `gemini-2.5-flash` `(0.30, 2.50)`, `gemini-2.5-flash-lite` and `gemini-3.1-flash-lite` `(0.10, 0.40)`, `gemini-embedding-001` `(0.15, 0.0)`, `deepseek-v4-flash` `(0.14, 0.28)`, `deepseek-v4-pro` `(0.435, 0.87)` — plus a `_FALLBACK_PRICING = (0.30, 2.50)` for unknown models. DeepSeek rates verified against api-docs.deepseek.com 2026-07-12.
- `summarize_costs(rows)` aggregates the current month's `llm_calls` rows into
  `{total_cost, total_calls, total_tokens, breakdown: [...]}`, with per-task
  percentages computed from unrounded cost *before* rounding (a real rounding
  bug — a single-task month showing 99.9% instead of 100% — was caught and
  fixed during the frontend rebuild's Phase 3, per ADR-009).
