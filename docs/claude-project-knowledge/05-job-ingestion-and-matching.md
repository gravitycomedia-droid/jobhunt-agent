# Job Ingestion & Two-Stage RAG Matching (Bricks 3–5)

## Job sourcing (`server/services/job_sources.py`)

Two legal job-board APIs, fetched in parallel (`asyncio.gather`):

- `fetch_adzuna()` — `GET https://api.adzuna.com/v1/api/jobs/{country}/search/1`,
  once per (role × location) combination from `settings.target_roles` /
  `settings.target_locations`.
- `fetch_jsearch()` — `GET https://jsearch.p.rapidapi.com/search-v2` (RapidAPI).

Both swallow per-query HTTP errors (log a warning, continue) so one flaky query
never sinks the whole refresh. No scraping of LinkedIn/Naukri/Indeed anywhere —
see ADR-003 in [08-decisions-log.md](08-decisions-log.md).

A third, user-driven source exists: **manual job add**. The user pastes a job
URL in `add_job_screen.dart`; the server (`services/job_ingestion.py::
fetch_manual_job_text`) fetches the page (15s timeout, follows redirects, custom
user-agent), strips `<script>/<style>/<noscript>` via BeautifulSoup, and hands
plain text to the LLM extractor (`extract_job_from_text`, see
[03-llm-and-prompts.md](03-llm-and-prompts.md)) for the user to review before it
becomes a real job row.

## Deduplication (`server/services/dedup.py`)

Two layers, both pure functions (no I/O, unit-tested):

1. **Exact**: `make_dedup_key(title, company, location)` — slugifies each field,
   joins with `|`. Backed by a `unique` constraint on `jobs.dedup_key` in
   Postgres, so even a race between two concurrent inserts can't create a
   duplicate.
2. **Fuzzy**: `is_duplicate(candidate, existing, threshold=90)` — `rapidfuzz.
   fuzz.ratio` on concatenated `"title company location"` against the last 500
   existing jobs, catching near-duplicates the exact key misses (e.g. slightly
   different location formatting from the two different source APIs).

## Ingestion orchestration (`server/services/job_ingestion.py::refresh_job_pool`)

1. Fetch Adzuna + JSearch concurrently.
2. Pull the last 500 existing jobs for dedup comparison.
3. Apply exact then fuzzy dedup against both existing jobs and each other.
4. Batch **all** new jobs into a single `embed_texts()` call (not one call per
   job — this is why the embeddings service batches at 50 texts per request).
5. Insert each surviving job; per-row insert failures (most likely a
   `dedup_key` unique-constraint race) are caught and skipped rather than
   failing the whole refresh.
6. `backfill_job_embeddings()` catches any job rows still missing an embedding
   (e.g. from a batch that partially failed) — safe to call repeatedly.

Triggered by `POST /jobs/refresh` (manual) and as the first step of the daily
cron pipeline (see [07-applications-and-agent-loop.md](07-applications-and-agent-loop.md)).
The job pool is **shared across all users** — one refresh benefits every
account, unlike matching, which is always per-profile.

## Two-stage RAG matching (`server/services/matching.py`)

This is the core "why not just ask an LLM to rank every job" answer — see
ADR-001. With ~500 jobs/day, sending everything to an LLM is too costly and too
slow. Instead:

### Stage 1 — vector similarity shortlist (cheap, ~20ms)
- `_stage1_shortlist(profile_id, limit)` calls the Postgres RPC function
  `match_jobs_by_similarity` (defined in `001_core_schema.sql`), which computes
  `1 - (profile.embedding <=> job.embedding)` (pgvector cosine distance) across
  an `ivfflat`-indexed `jobs.embedding` column and returns the top N.
- Exposed directly to the client as `GET /matches/shortlist` (raw similarity
  percentage, no LLM reasoning yet) — `shortlist_item.dart` on the Flutter side.

### Stage 2 — LLM re-rank (reasoning, only on the shortlist)
- `rerank_shortlist(profile, limit=DEFAULT_RERANK_LIMIT=20)` takes Stage 1's
  shortlist and calls `services/llm.py::rerank_job` (see
  [03-llm-and-prompts.md](03-llm-and-prompts.md)) once per job, producing a
  `MatchResult`: `fit_score` (0–100), `strengths[]`, `gaps[]`, `compensators[]`,
  `verdict` (`apply` / `stretch` / `skip`), `one_line_reason`.
- Results are cached into the `matches` table with a `unique(profile_id,
  job_id)` constraint — pairs already ranked are skipped on subsequent calls,
  making repeated re-rank calls cheap and idempotent (`{"reranked": n,
  "skipped": n}` is the response shape).
- `get_ranked_matches(profile, limit=50)` reads the cached results back,
  ordered by `fit_score` descending, for `GET /matches`.

### Net effect
Roughly a 96% reduction in LLM tokens versus naively re-ranking every fetched
job, while still getting LLM-quality reasoning (not just a similarity number)
on the jobs that actually matter.

## Client-side flow

- `jobs_list_body.dart` — browse/bookmark the raw job pool, filter by source.
- `matches_body.dart` — renders the cached `GET /matches` result instantly,
  then kicks off `POST /matches/rerank` in the background to pick up anything
  new (long client timeout, up to 10 minutes, since re-ranking is one
  sequential Gemini call per job).
- `matching_loading_screen.dart` — the onboarding-time transitional screen that
  fires the first refresh + re-rank for a brand-new profile.

## Related files

- `server/routers/jobs.py`, `server/routers/matches.py`
- `server/services/job_sources.py`, `dedup.py`, `job_ingestion.py`, `matching.py`
- `server/models/job.py`, `server/models/match.py`
- `server/db/migrations/001_core_schema.sql` (schema + `match_jobs_by_similarity`)
- `app/lib/screens/jobs_list_body.dart`, `matches_body.dart`, `add_job_screen.dart`, `matching_loading_screen.dart`
- `app/lib/models/job.dart`, `match_item.dart`, `shortlist_item.dart`, `job_extraction.dart`
- `docs/PROMPTS.md` (sections 2 "Match Re-Ranker", 5 "Embeddings", 6 "Add Job extraction")
