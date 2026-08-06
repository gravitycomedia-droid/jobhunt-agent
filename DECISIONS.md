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

## ADR-003: Job APIs + scoped scraping via Apify
**Date:** project start · **Amended:** 2026-07-13 · **Status:** accepted (amended)

**Context:** LinkedIn/Naukri have the richest listings, but scraping violates ToS, risks account bans, and produces brittle code.

**Original decision:** Adzuna API (primary) + JSearch/RapidAPI (secondary, surfaces Google-for-Jobs results legally). Dedup layer merges feeds. Legal APIs only — no scraping of LinkedIn/Indeed/Naukri.

**Alternatives considered:** Scraping: legally grey, maintenance nightmare. Manual paste-a-job feature kept as a supplement for postings outside our feeds.

**Consequences:** Slightly narrower coverage, fully compliant and stable. Designing around API limits is itself demonstrable engineering maturity.

### Amendment (2026-07-13) — scoped scraping via Apify

For personal use by a small, known group of friends (not a public or commercial
product), scraping LinkedIn, Indeed, and Naukri via third-party Apify actors is
now approved as a **supplementary** source, subject to these constraints:

- Prefer no-login / cookie-free actors (no LinkedIn/Indeed/Naukri account
  credentials are ever given to Apify or stored anywhere in this project) —
  this avoids the account-ban risk that login-based scraping carries.
- Personal-scale usage only: capped result counts per run, no resale,
  redistribution, or public hosting of the scraped data.
- This does not change golden rule 1 (secrets server-side only) — the Apify
  token lives in Secret Manager / server `.env`, never in the Flutter app.
- Still explicitly rejected: logging into LinkedIn/Indeed/Naukri accounts to
  scrape, high-volume/aggressive polling, or treating this as a redistributable
  data product.

**Why the amendment:** Adzuna + JSearch under-cover Indian fresher/intern roles
specifically, and LinkedIn/Indeed/Naukri are where most of that volume lives.
Apify actors abstract the scraping mechanics and (for the no-login variants)
reduce — but do not eliminate — ToS and blocking risk. This is accepted as a
known, bounded risk for a small personal deployment, not a decision that would
necessarily hold at public-product scale.

**Implementation:** see `14-scraping-source-expansion-plan.md`. Scraped sources
run on the cron path only — never on `POST /jobs/refresh` *or* on "Run agent now"
(`run_daily_pipeline_for_profile`), both of which are user-triggered. The plan
only called out the former; the latter shares `_refresh_and_backfill()` with the
cron, so scraping deliberately lives outside that helper. Otherwise any user
could spend real money by tapping a button.

### What the live hand-test changed (2026-07-13)

Four things were wrong in the plan's assumptions, all found by running the actors
for real rather than trusting their store pages:

1. **Pricing.** The plan assumed "a few dollars a month" and pay-per-result for
   all three. In fact `bebity/linkedin-jobs-scraper` is a **$29.99/mo flat
   subscription** (rejected — swapped to `curious_coder/linkedin-jobs-scraper` at
   $0.001/result), and per-job prices differ ~10x: LinkedIn $0.001, Indeed
   $0.006, Naukri $0.0095 (with full JDs). Daily × 3 sources would have been
   ~$27/mo against Apify's **$5/mo free-plan hard cap**.
2. **Cadence and caps are therefore PER SOURCE**, not global — the cheap source
   runs mon/wed/fri, the priciest runs weekly. ~$4.33/mo, inside the free cap.
   Crucially, Apify bills per result and dedup runs *after* the charge, so
   re-scraping daily means re-buying rows we already own.
3. **HTTP 402 does not mean "out of credit."** An unbounded `asyncio.gather()`
   over 12+ queries asks for ~48GB of actor memory against the free plan's 16GB
   ceiling, and Apify rejects the overflow with a 402 — observed live losing 6 of
   6 LinkedIn calls at $0.84 of a $5 budget. Fixed with a concurrency semaphore
   (`apify_max_concurrent_runs`). Note a client-side timeout does **not** abort
   an Apify run: it keeps executing and billing, so bounded concurrency also
   bounds how many runs we can strand.
4. **No two actors share an output shape.** Indeed says `positionName`, LinkedIn
   says `title`, Naukri hides the real description behind `fetchDetails` (90-char
   stub → 2,219-char JD). Every field name in `job_sources.py` was read off a
   live run. Locations also disagree on spelling ("Bengaluru East", "Greater
   Hyderabad Area", "Hybrid - Hyderabad, Chennai"), so `_primary_city()`
   canonicalizes them — without it the same posting on two boards yields two
   dedup keys and lands twice.

### Amendment v2 (2026-07-20) — Internshala + Unstop, and a scale ceiling

> **Status: ACCEPTED (2026-07-20).** Plan 15 (`docs/15-india-source-expansion-and-ingestion-alerting-plan.md`)
> gated all new scraping on this amendment; it is now signed off. Internshala
> (Apify) and Unstop (direct-fetch) code may be built and wired in, but each
> source still makes zero live calls until `ENABLE_INDIA_SOURCES=true` is set
> (default `false`). Unstop additionally waits on its Phase B endpoint recon.
> Phase F ingestion-health observability was never gated by this — it only
> measures sources already approved under the 2026-07-13 amendment.

The 2026-07-13 amendment approved LinkedIn/Indeed/Naukri via no-login Apify
actors for "personal use by a small, known group of friends." Plan 15 widens
that boundary on two independent axes, and this amendment governs both.

**1. Two new scraped sources.** Approval extends to:
- **Internshala** via a no-login Apify actor (internships + fresher jobs).
- **Unstop** via its own public JSON endpoint (the one its web frontend calls),
  fetched directly with `httpx` — no Apify actor, no login, no credentials.

Both inherit every constraint of the 2026-07-13 amendment unchanged: no-login
only, capped result counts per run, cron-path only (never a user-tappable
button), no resale/redistribution/public hosting of the scraped data.

**2. A scale ceiling, framed by WHO not just HOW MANY.** The original wording
("a small, known group of friends") is what keeps the ToS-risk framing —
"personal, non-commercial" — defensible. Growing the user base doesn't
automatically erode that, so this amendment states the boundary explicitly:

- **Access is invite-only to known individuals.** No public signup, no
  marketing, no open registration. This constraint — not the headcount — is
  what actually keeps "personal/small-batch" honest.
- **Soft ceiling of ~100 users** sits underneath that qualitative bound, not
  the other way around. Crossing it is a prompt to revisit this ADR, not a hard
  stop.

**3. Scraping volume is a SEPARATE dial from user count — decoupled on purpose.**
The job pool is shared: one daily refresh serves every reader, whether that's 5
users or 100. So more users does **not** imply more Apify spend. Widening
coverage (more role×location combos, higher per-query caps) is an independent
decision with its own cost, made deliberately — never automatic fallout from
onboarding more people. The per-source caps, cadence weekdays, and concurrency
ceiling from the 2026-07-13 amendment remain the spend control and are unchanged
by this one.

**What actually scales with users is Stage-2 LLM rerank, not scraping** — ~20
jobs/user/day through Gemini, so ~2,000 rerank calls/day at 100 users vs. a
handful today. That's a cost to watch via `GET /stats/costs` once a few dozen
real users are on, with real numbers rather than an estimate — and it's an LLM
cost, wholly separate from the Apify/scraping budget this ADR governs.

**Why accept the wider boundary:** Indian fresher/intern coverage is still the
gap ADR-003 has been chipping at since 2026-07-13; Internshala and Unstop are
where a lot of the genuinely entry-level Indian volume lives, and neither
requires a login. The residual ToS/blocking risk is the same *kind* already
accepted for LinkedIn/Indeed/Naukri, held bounded by the same mechanisms
(no-login, capped, cron-only) plus the explicit invite-only ceiling above.
Public signup is **out of scope** — not a roadmap item this ADR defers, but a
boundary it draws: this deployment stays invite-only to known individuals with
no public registration or marketing. Opening it to the public would be a
different product with a different risk profile, and would require a fresh ADR
before any of this scraping could carry over.

**Implementation gate:** `ENABLE_INDIA_SOURCES` (default `false`) is the master
kill switch for both new sources; the code lands and is unit-tested against
mocked responses behind it, and makes zero live calls to Internshala or Unstop
until this amendment is accepted AND the flag is flipped. Unstop additionally
waits on a one-time manual endpoint-recon step (Plan 15 Phase B).

### Amendment v3 (2026-07-26) — the broad Unstop pool

> **Status: ACCEPTED (2026-07-26).** Raises Unstop from ~20 rows/day to ~87/day
> steady state (~791 on the first run) by crawling its whole catalogue instead
> of three role keywords, adding its `jobs` catalogue alongside `internships`,
> and dropping the ROLE and LOCATION halves of the ingestion gate for that one
> source. Everything the v2 amendment constrained — no login, cron-only,
> invite-only user base, no redistribution — is unchanged.

**Context.** v2 approved Unstop and it worked, but landed ~20 postings a day.
Live measurement on 2026-07-26 found the cause was not the fetch cap everyone
assumed. Three separate narrowings compounded:

| narrowing | effect |
|---|---|
| `searchTerm` set per `target_roles` entry | never saw the catalogue, only 3 keywords |
| `opportunity=internships` hardcoded | 1,186 open `jobs` postings invisible |
| the role gate in `job_filter.py` | discarded ~92% of what did come back |
| `UNSTOP_MAX_RESULTS=20` | the one everybody looked at; least significant |

**The decision.** Three changes, each measured rather than estimated:

**1. Crawl the catalogue, not keywords.** `UNSTOP_SEARCH_TERMS` defaults empty →
one unfiltered pass. Counter-intuitively this is *fewer* requests than the
keyword loop it replaces. `UNSTOP_OPPORTUNITY_TYPES=internships,jobs` adds the
second catalogue. (`freshers`/`entry-level` were probed and are **not**
opportunity types — they return `total=0`; Unstop treats them as filters inside
`jobs`, so the fresher cut stays the ingestion gate's job.)

**2. Volume is bounded by FRESHNESS, not by a cap.** Results are newest-first, so
the crawler stops after two consecutive pages older than `MAX_JOB_AGE_DAYS`.
Cold start is ~21 requests; steady state is ~3. `UNSTOP_MAX_RESULTS` is now a
runaway guard, not a target. This is what keeps "no high-volume polling" true
while pulling 40x the rows — we are a *lighter* caller per row than before.

**3. The relevance gate is now per-source** (`INGESTION_GATE_OVERRIDES`,
default `unstop:entry`). Measured over the full open catalogue:

| gates applied | day-one backfill | new per day |
|---|---|---|
| all three (v2 behaviour) | 441 | 55 |
| entry only (**chosen**) | 791 | 87 |
| location only | 711 | 76 |
| none | 1,443 | 131 |

**Why entry-level stays on and the other two come off.** Role and location are
*preferences* — they vary per user and change as someone's search evolves, and
the app can express them as filters the user can widen at any time. Entry-level
is a *property of this product*: a resume-tailoring agent for a fresher has
nothing useful to say about a Director of Sales posting, so storing one costs an
embedding and buys nothing. The asymmetry that decides it: a posting we filtered
in the app is one tap from being visible again, while a posting we never ingested
is gone until it's re-crawled. So preferences filter late, product boundaries
filter early.

**What this costs.** ~75% of the pool is now non-engineering (sales 23%,
marketing 16%, operations 9%). Three consequences, all handled:
- **The app needed a category axis** — `jobs.category` (migration 027), a
  keyword classifier (`services/job_category.py`, golden rule 2: no LLM call on
  a per-row hot path), and a filter chip row defaulting to the tech categories.
  This one is applied server-side, unlike every other filter, because the client
  would otherwise page through 1,400 rows to display ~200.
- **Two latent bugs became real** at this volume and are fixed here: the dedup
  lookback was a blind "most recent 500 rows" (fine at 30/day, under three days
  of history at 130/day — it broke the *fuzzy* near-match check; exact dupes were
  always safe via `on_conflict`), and the batch upsert now chunks at 200 rows
  rather than sending 800 embeddings in one request body.
- **Match quality and LLM cost are unaffected**, which is why this is safe.
  Verified in `services/matching.py`: stage 1 is cosine similarity against the
  user's resume, so marketing postings sink; `_prescreen()` drops off-discipline
  jobs before Gemini sees them. Rerank stays pinned at ~20 jobs/user/day
  regardless of pool size. The added cost is embeddings and storage only.

**What did NOT change:** no login, no credentials, cron-path only, invite-only
access, no redistribution, and `ENABLE_INDIA_SOURCES` remains the master kill
switch. The v2 scale ceiling and the "scraping volume is a separate dial from
user count" principle both still hold — this *is* that dial being turned
deliberately, with numbers, which is exactly what v2 said such a change required.

### Amendment v4 (2026-07-27) — Internshala goes free, Instahyre added

> **Status: PROPOSED — awaiting sign-off.** Code lands behind the existing
> `ENABLE_INDIA_SOURCES` gate (still default `false`), so nothing fetches live
> until the flag is flipped. Same posture as v2.

**Context.** Two findings from hands-on recon on 2026-07-27, both verified
before any code was written:

1. **Internshala needs no Apify actor.** Its category listing pages are plain
   server-rendered HTML — a bare GET returns all 50 cards per page with title,
   company, location, stipend, duration, skill tags and a relative posted-time
   badge already in the markup. The `blackfalcondata~internshala-scraper` actor
   was billing $0.0015/result for HTML anyone can fetch.
2. **Instahyre has a genuinely public JSON API.** `GET /api/v1/job_search` with
   `job_categories=1` ("Software Engineering") returns structured listings with
   no auth, cookies or session of any kind — confirmed without ever logging in.

**Decision.**

- Internshala moves from the paid Apify rotation to a free `httpx` +
  BeautifulSoup fetch, and from a tue/fri cadence capped at 10 results to
  **daily** across ~12 technical category slugs. Cadence was rationing money;
  there is no longer money to ration. The Apify actor and its three config knobs
  are deleted rather than deprecated.
- Instahyre is added as a second free direct-fetch source.
- Both route through a new `refresh_india_boards()` — **cron-only**, gated on
  `ENABLE_INDIA_SOURCES`, deliberately NOT in `refresh_job_pool()`. The source
  plan asked for the latter; that would have been a rules violation, because
  `refresh_job_pool()` is what the app's "Run agent now" button calls, and this
  ADR permits these boards only on a daily cron. **Free of COST is not free of
  CADENCE** — they are separate constraints, and only the first one changed.

**Two new schema columns (migration 028), and why they are new columns:**

- `tech_category` — the technical *specialism* (frontend/backend/ai_ml/…). It
  sits **alongside** `category` (migration 027), which records the *function*
  (engineering/sales/hr/…). Overloading 027's column with specialisms — which the
  source plan proposed — would have destroyed the ability to label and browse
  non-engineering roles at all, which is the entire reason 027 exists. NULL is
  the correct, meaningful value for a non-technical posting; there is no
  `non_it` member, because `category` already says it.
- `is_active` — soft-delete for presence-based retirement. Neither source
  exposes a usable expiry date, so a posting that stops appearing in the daily
  fetch is retired. **Never a hard `DELETE`**: `jobs` rows are referenced by
  `applications`, `matches` and `tailored_resumes`, and deleting one would
  destroy a user's own tracked history because a company took a listing down.
  Discovery reads (`GET /jobs`, facets, `match_jobs_by_similarity`) exclude
  retired rows; reads that hydrate a job the user already interacted with
  deliberately do not. That asymmetry is the whole point of the flag.

**Classification is deterministic first.** Pass 1 is keyword/skill-tag matching
in Python; only rows it cannot place go to a **single batched** DeepSeek call.
Measured against 210 real listings pulled live from both sources on 2026-07-27,
Pass 1 resolved **96%** (177/184 technical rows) — the 7 that fell through were
IoT, Robotics, Unreal Engine and Kofax, i.e. genuine `other_it`. So the LLM cost
is one small call per ingestion run, and `ENABLE_TECH_CATEGORY_LLM=false` turns
even that off in exchange for those rows defaulting to `other_it`.

This is a narrower use of an LLM than ADR-003 v3's `job_category.py` explicitly
argued against, and the difference matters: that module rejects an LLM for the
*function* call because it runs on every row and the vocabulary is title-visible.
Specialism is harder — "Software Engineer" with only a skill list is not
decidable by keyword, and it's the commonest title in the pool. Golden rule 2
still holds: code decides everything code can decide, and here that's 96%.

**Two claims in the source plan were wrong and are corrected here**, both caught
by live recon rather than in production:

- *"Listings are sorted newest-first, so stop early at the first stale card."*
  They are not. The top ~32 cards are a promoted/featured block in mixed order —
  a "3 weeks ago" card sat at position 1 with "Just now" at position 2. The
  proposed early-stop would have returned near-zero jobs. Every card on a fetched
  page is parsed, and freshness is left to the existing shared `is_fresh()` gate.
- *"Instahyre `job_type=2` is mixed with Sales/HR/Marketing interns."* With
  `job_categories=1` applied it is not — all 8 internships returned were
  technical. The classifier still runs on every row as a safety net, but the
  source-side filter is better than the plan credited.

**Known limitation, accepted:** Instahyre's full-time catalogue (~7,900 rows)
skews heavily senior — page one was Staff/Principal/Senior almost throughout — so
the entry-level gate will discard most of it, much like Greenhouse/Lever. Its
internship catalogue was only 8 rows. Realistic yield from Instahyre is therefore
low; it is added for coverage, not volume, and the ingestion health log tracks
*fetched* (not inserted) so an all-duplicate day doesn't read as a dead source.

**What did NOT change:** no login, no credentials, cron-path only, invite-only
access, no redistribution, per-request delays, and `ENABLE_INDIA_SOURCES` remains
the master kill switch for all three India boards.

#### First production run, 2026-07-27 — two bugs the unit tests could not catch

Deployed as revision `00027-jnt` and triggered manually. Internshala worked
(876 cards parsed, 32 inserted, all classified). **Instahyre inserted zero rows
while reporting 300 fetched**, and the reason generalizes:

1. **A shared cap starved the only useful catalogue.** `fetch_instahyre()`
   crawled `job_type` 0 then 2 against one row cap. Full-time is ~7,900 rows and
   *120/120 sampled were rejected by the entry-level gate* (Staff/Principal/
   Senior throughout); internships are ~8 rows and mostly survive. Full-time ate
   the entire 300-row budget, so internships were never requested. Fixed by
   crawling internships first — the order in `INSTAHYRE_JOB_TYPES` is
   load-bearing, not cosmetic.

   The wider lesson: **`by_source` counts FETCHED, so a source can look perfectly
   healthy at 300/day while contributing nothing.** Tracking fetched is still
   right for detecting a dead source (golden rule 6), but it cannot detect a
   source whose every row is filtered out. Only checking the table found this.

2. **Pagination could loop forever.** The crawl exits on `len(jobs) < cap`, but
   rows are deduped by id *before* being counted — so an endpoint that keeps
   returning `meta.next` with content already seen never grows the list and spins
   indefinitely. This would have hung the daily cron, not merely slowed it. Found
   because a regression test written for bug 1 modelled exactly that shape and
   hung the suite. Fixed with `INSTAHYRE_MAX_PAGES`, a bound independent of the
   row cap. Both bugs now have regression tests.

Deployed as `00028-2r6`. Post-fix live state: Internshala 36 active rows
(specialisms: full_stack 12, frontend 12, devops_cloud 4, mobile 3, qa_testing 2,
backend 2, ai_ml 1), Instahyre 1 active row (devops_cloud).

#### Open: the gate is discarding most of what these sources return

`INGESTION_GATE_OVERRIDES` names only `unstop`, so Internshala and Instahyre get
all three strict gates. Measured live 2026-07-27:

| source | all three gates | entry-only |
|---|---|---|
| Internshala | 68 | **237** |
| Instahyre | 1 | **8** |

The 159 Internshala postings the role gate discards are ai_ml 61, data_science
24, mobile 20, backend 19, cybersecurity 18, qa_testing 17 — i.e. precisely the
specialisms `tech_category` was added to let users browse. The role gate admits
only fullstack/frontend/cloud, so the pool can never contain the variety the
chips imply.

This is the same trade v3 already made for Unstop, and the same reasoning applies
(*a posting we never stored can't be un-filtered later*; role and location are
reversible per-user in the app, an ingestion gate is not). The change would be
`INGESTION_GATE_OVERRIDES=unstop:entry,internshala:entry,instahyre:entry`.
**Deliberately left unset pending a decision** — it widens what enters the pool,
which is the kind of change v2 said should be made with numbers rather than by
reflex. The numbers are above.

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

## ADR-006: Switched from text-embedding-004 to gemini-embedding-001
**Date:** 2026-07-09 · **Status:** accepted

**Context:** Brick 4's first live embed call against this project's Gemini API key failed with `404 NOT_FOUND: models/text-embedding-004 is not found ... or is not supported for embedContent`. Listing models with `embedContent` support on this key showed only `gemini-embedding-001`, `gemini-embedding-2-preview`, and `gemini-embedding-2` — `text-embedding-004` isn't offered at all, not just quota-exhausted. Same class of issue as ADR-005 (a pinned model unavailable on this key/tier), different symptom (missing model vs. zero quota).

**Decision:** Standardize on `gemini-embedding-001`, pinned to 768-dim output via `EmbedContentConfig(output_dimensionality=768)` in `services/embeddings.py`. 768 was chosen to match migration 001's existing `vector(768)` columns on `profiles.embedding` and `jobs.embedding` exactly — no schema migration needed. Updated in `CLAUDE.md`, `.env.example`, `server/.env`.

**Alternatives considered:** Migrating the schema to `gemini-embedding-001`'s native 3072-dim output — more representational capacity, but doubles+ pgvector index size/query cost for a single-user app where 768 dims already gives strong semantic separation between job postings; not worth the migration. `gemini-embedding-2-preview`/`gemini-embedding-2` — newer but preview-status or undocumented stability for a project this early; `-001` is the stable GA option.

**Consequences:** No schema change required — `output_dimensionality` does the adaptation, so `services/embeddings.py` is the only file that knows the model produces more than 768 dims natively. `EmbedContentResponse.metadata` only exposes `billable_character_count` (no token counts) for embedding calls, unlike generation calls — `llm_calls.tokens_in` is repurposed to hold that character count for this task, `tokens_out` stays null. Worth re-checking model availability again if Google changes the embedding lineup during the project, per the same pattern ADR-005 already established.

---

## ADR-007: Stubbed FCM push, cron via Render, manual /pipeline/run trigger
**Date:** 2026-07-09 · **Status:** accepted

**Context:** Brick 8 (the agent loop) needs a scheduler and a push-notification channel. No Firebase project exists yet — no service-account JSON, no `google-services.json`/`GoogleService-Info.plist`, no `firebase_messaging` in the Flutter app. Provisioning those is a manual, external action (Firebase Console) that can't be scripted from here.

**Decision:** `services/notify.py.send_push_notification()` just logs `"would notify: ..."` instead of calling FCM — the daily pipeline (`jobs/daily_pipeline.py`) calls it at the same point a real send would happen, so swapping in the real Admin SDK call later is a one-function change. Scheduling follows CLAUDE.md's existing Render hosting choice: a Render cron job is expected to hit `POST /pipeline/run` on `DAILY_PIPELINE_HOUR`, rather than adding an in-process scheduler (APScheduler) as a new dependency. Since no cron is deployed yet, `POST /pipeline/run` also doubles as a manual trigger — surfaced in the Flutter app as a "Run agent now" button on `HomeScreen` — so the loop is demonstrable before deployment.

**Alternatives considered:** In-process APScheduler — works without deploying, but adds a dependency and requires the server to stay running continuously, which conflicts with Render's cron-job-as-separate-process model. Blocking Brick 8 entirely until FCM is configured — would stall the rest of the agent loop (job refresh, re-rank, follow-up drafts) on an unrelated external setup step.

**Consequences:** The full loop (refresh → embed backfill → re-rank → follow-up drafts) is real and tested end-to-end; only the notification send is fake. `applications` gained three columns (`followup_subject`, `followup_body`, `followup_drafted_at`) via migration `002_followups.sql` — applied manually in the Supabase SQL Editor, same as migration 001. Revisit this ADR once a Firebase project exists: replace `send_push_notification`'s body, add `firebase_messaging` + platform config files to the Flutter app, and add a device-token registration endpoint.

**Update (2026-07-09):** The Firebase project (`jobhuntagent-27b32`) and service-account credential now exist, so the deferred half landed same-day. Server: `services/notify.py` sends a real `firebase_admin.messaging.send()` when a token is present, falling back to log-only when it's missing or the Admin SDK fails to init — a push failure must never take down the daily pipeline. `profiles` gained an `fcm_token` column via migration `003_fcm_token.sql`, set through a dedicated `PATCH /resume/profile/{id}/fcm-token` (kept separate from the main profile PATCH so a token refresh doesn't trigger a re-embed). Android app registered via `flutterfire configure` (Firebase CLI was already authenticated on this machine), generating `app/android/app/google-services.json` and `app/lib/firebase_options.dart` — both committed as-is; neither contains secrets, only public client identifiers, which is Firebase's own recommended practice. Flutter: `PushService` (`app/lib/services/push_service.dart`) initializes Firebase, requests notification permission, and registers the device token — every step best-effort/caught, since push setup must never block app startup. **iOS is explicitly out of scope** — no APNs key uploaded, no iOS app registered; `PushService` early-returns on web and would need an iOS-specific path added before that platform gets push. **Not yet verified on-device** — no Android SDK/emulator/physical device available in this environment; `flutter build apk` couldn't be run. Verify the full loop (permission prompt → token registration → a real push arriving) the next time this runs on an actual Android device or emulator.

---

## ADR-008: Supabase Auth (Google OAuth) for multi-tenancy, service-role scoping over RLS enforcement
**Date:** 2026-07-09 · **Status:** accepted

**Context:** Every table and endpoint through Brick 8 assumed a single global profile row (`select(...).limit(1)`) — the whole point of Brick 9's "beta users" framing is that this stops being true. Needed: real login, and every query in the app scoped to the caller instead of "the one row."

**Decision:** Supabase Auth with Google as the only provider (chosen over email/password for beta-tester UX, and over scaffolding multi-tenancy without real login since that would just defer the harder problem). `server/services/auth.py` provides two FastAPI dependencies: `get_current_user_id` (verifies the `Authorization: Bearer <token>` header via `supabase.auth.get_user()` — a network round-trip to Supabase's own Auth API rather than decoding the JWT locally, so there's no signing secret to manage or rotate) and `get_current_profile` (looks up the caller's profile by `user_id`, 404s with the same "upload a resume first" message pre-auth callers already relied on). Every router that touched `.limit(1)` — `resume.py`, `matches.py`, `applications.py`, `tailor.py`, `services/matching.py` — now takes the authenticated profile as a parameter instead. `POST /pipeline/run` (the Render cron path, all beta users) and `POST /pipeline/run-mine` (the Flutter "Run agent now" button, caller only) split apart because a cron job has no user session to authenticate with — cron is guarded by a shared `PIPELINE_SECRET` sent as `X-Pipeline-Secret` instead. `daily_pipeline.py` restructured around `_refresh_and_backfill()` (job pool has no owner, runs once) and `_process_profile()` (re-rank + follow-ups + push, looped per beta user for the cron path, called once for the button path). Flutter: `supabase_flutter` + `AuthGate` (swaps `LoginScreen`/`HomeScreen` on `onAuthStateChange`) + `ApiClient._authHeaders()` attaching the session token to every call — one method touched instead of respecifying auth per call site, same pattern Golden Rule 1 already established for the base URL.

**Alternatives considered:** Decoding the Supabase JWT locally with the project's signing secret — saves a network round-trip per request, but means managing a secret that Supabase can rotate, and `auth.get_user()` is one line versus real signature-verification code for a single/beta-user app where the extra latency is irrelevant. Scaffolding `user_id` + RLS without wiring real login — explicitly rejected per the user's own framing: the point was to unblock real multiple accounts, not defer that again. A single `/pipeline/run` trying to serve both cron and per-user triggers — would need to smuggle "is this a cron call or a user call" through some other signal; splitting into two routes with two different auth mechanisms is more honest about what each caller actually is.

**Consequences:** RLS (migration `004_auth.sql`) is explicitly documented as defense-in-depth, not the enforcement boundary — the FastAPI server always connects with the service-role key and bypasses RLS entirely, so the real per-user isolation is the `get_current_profile` dependency scoping every query. This matters if anyone reads the RLS policies expecting them to be what stops user A from seeing user B's data — they don't; the Python code does. Ownership checks were added to `PATCH /applications/{id}` and `PATCH /tailor/{id}/approve` that didn't exist pre-auth (any UUID could be PATCHed by anyone when there was only one possible owner) — a real gap the multi-tenant change surfaced, not scope creep. `{profile_id}` was dropped from every resume URL (`/resume/profile`, `/resume/profile/fcm-token`) since the authenticated session makes "which profile" derivable instead of client-supplied — a simplification the auth layer enabled, not a breaking change made gratuitously. Verified end-to-end short of an actual device: `GET /resume/profile` and `GET /jobs` both 401 with no/bad token; `POST /pipeline/run` 401s without the right `X-Pipeline-Secret` and succeeds with it; a raw curl to Supabase's `/auth/v1/authorize?provider=google` 302s to a real `accounts.google.com` sign-in page with the correct `client_id` and `redirect_uri`, confirming the whole chain (app → Supabase → Google) is wired correctly. **Never verified on-device** — same environment limitation as ADR-007 (no Android SDK/emulator here); the actual "tap Sign in with Google, land back in the app signed in" flow needs a real device or emulator to confirm.

**Update (2026-07-10) — "polish":** The Brick 9 title's third word had never been scoped; asked directly, the answer was three things: adopt the `AppShell` bottom-nav (designed in the `Job-Hunt Agent design system/` reference folder but never wired to any screen — every screen was still reached by pushing from `HomeScreen`'s AppBar icons), add a real Profile/Settings screen (previously there was no way to revisit the resume profile after the initial upload flow, and sign-out was a stray icon button), and audit empty/loading/error states for consistency. Execution: every tab-bound screen (`HomeScreen`, `JobsListScreen`, `ShortlistScreen`, `ApplicationsScreen`) was split into a body-only widget (`HomeBody`, `JobsListBody`, `MatchesBody`, `ApplicationsBody` — no own `Scaffold`/`AppBar`, since `AppShell` now supplies that chrome) plus a new `ProfileBody`, all composed by a new `MainTabScreen` that wraps `AppShell` in an `IndexedStack` (keeps all five tabs' state — scroll position, loaded data — alive across switches instead of refetching on every tap). The old standalone screen files were deleted outright rather than kept as dead code, since nothing pushed to them anymore. `HomeBody`'s hand-rolled error UI was swapped for the shared `EmptyState` widget, and `ApplicationsBody`'s bare spinner became a horizontal `LoadingSkeleton` row, matching the pattern `JobsListBody`/`MatchesBody` already used — both were real inconsistencies the audit surfaced, not busywork.

**Consequences (polish):** `test/widget_test.dart` was already broken independent of this pass — it predated `Supabase.initialize()` being on the critical path to first paint (added earlier in Brick 9) and threw `You must initialize the supabase instance before calling Supabase.instance` the moment `AuthGate` built. Fixed with `SharedPreferences.setMockInitialValues({})` + a real (fake-URL) `Supabase.initialize()` in `setUpAll`; the test itself was rewritten to assert on the login screen appearing (accurate given `AuthGate` now gates on session state) rather than a stale "loading indicator" assertion that referenced a `CircularProgressIndicator` `JobsListBody` doesn't even render anymore (it's used `LoadingSkeleton` shimmer cards since before this session). `activity_log_item.dart` and `chip_input.dart` — two more design-system widgets built ahead of any screen using them — were deliberately left alone rather than wired in or deleted; neither was in scope of what "polish" turned out to mean, and removing working code nobody asked to remove isn't polish. Verified via `flutter analyze` (clean except three pre-existing info-level lints), `flutter test` (2/2 passing), `flutter build web` (clean), and a real `flutter run -d chrome` launch with no runtime exceptions and a confirmed `Supabase init completed` log line — same on-device gap as everything else in this brick: the actual tab-switching/bottom-nav interaction was never clicked through by a human or an automated browser driver.

---

## ADR-009: Frontend rebuild from the design-system prototype, phased execution
**Date:** 2026-07-10 · **Status:** complete (all 4 phases shipped and verified)

**Context:** The user asked for a complete frontend rebuild pixel-faithful to `Job-Hunt Agent design system/Job-Hunt Agent Prototype.dc.html` — the real prototype, which turned out to have 23 screen-states (more than the 17 originally catalogued in the design brief), not just the 9 already built. Investigation found the token/component layer (`app/lib/theme/`, `app/lib/widgets/`) already matches the CSS tokens exactly — this was a screen-composition problem, not a component-porting one. Reading the full prototype surfaced ~14 net-new screens, several with zero backend behind them (LLM cost stats, an activity log, manual job entry, per-user target roles, on-demand follow-ups, "skill growth" recommendations, real email sending, settings). Given the size, execution was explicitly scoped into 4 phases with a checkpoint after each — full plan at `/Users/vishnuashrith/.claude/plans/linked-coalescing-lagoon.md`.

**Decision — Phase 1 (onboarding shell + core re-skins), shipped this session:**
- **Email/password auth added alongside Google**, zero backend changes — `services/auth.py`'s `get_current_user_id` already verifies any valid Supabase session token regardless of provider. Verified for real: signed up a test user via Supabase's REST API, confirmed it with the service-role key (bypassing the email-confirmation step, since there's no way to receive that email here), signed in for a real token, and confirmed the server accepted it — then deleted the test user and profile row afterward.
- **Migration `005_target_roles.sql`** adds `profiles.target_roles`/`min_salary`; new `PATCH /resume/profile/target-roles` mirrors the `fcm-token` endpoint's pattern (separate from the main profile PATCH so a preference update doesn't trigger a re-embed). Not yet wired into `daily_pipeline.py`'s job-fetch step, which still reads the global `TARGET_ROLES` env var — the Target Roles screen currently promises more than the pipeline delivers; flagged for Phase 2+.
- **`AuthGate` rewritten as a real state machine**: no session → Splash/Auth; session but `GET /resume/profile` returns null → `OnboardingFlow` (Welcome → Upload → Review → Target Roles → Matching → done); session with a profile → straight to `MainTabScreen`. `MatchingLoadingScreen` deliberately does NOT await the rerank call — `MatchesBody` had already learned (documented in its own comments) that a cold 20-job rerank batch can take 7+ minutes, so onboarding fires refresh+rerank in the background and hands off after a fixed 1.6s display instead of blocking on it.
- **HomeBody/JobsListBody/MatchesBody re-skinned** using only existing endpoints/components: Home gained a hero best-match card (`ScoreRing` size 100) and a real 3-stat grid (matches/applied/saved, computed client-side from already-fetched lists — deliberately dropped the prototype's "Grow your match rate" and "Recent activity" sections rather than wire them to nothing, since that data doesn't exist until Phase 3/4). Jobs gained a bookmark toggle reusing Brick 7's `applications` 'saved' state (add-only for now — there's no DELETE endpoint, so tapping an already-saved job's bookmark shows an explanatory snackbar instead of a broken toggle) and a real `ShortlistScreen` (zero new backend, just `GET /applications` filtered client-side). Matches got the prototype's always-expanded card layout for free via `MatchCard`'s existing but previously-unused `defaultExpanded` flag.

**Alternatives considered:** Building all 23 screens in one pass — rejected given the size (~10 new backend capabilities) and the user's own choice to checkpoint per phase. Blocking `MatchingLoadingScreen` on the full rerank to literally match the prototype's percentage-complete UI — rejected as repeating a bug `MatchesBody` had already fixed elsewhere in the codebase.

**Consequences:** `login_screen.dart`, `home_screen.dart`, `jobs_list_screen.dart`, `shortlist_screen.dart` (the old Brick 9 versions), and `applications_screen.dart` are gone, replaced by the body-widget pattern Brick 9's polish pass established. `ResumeUploadScreen` and `ProfileReviewScreen` gained optional continuation callbacks (`onProfileReviewDone`, `onSaved`) so `OnboardingFlow` can chain them into Target Roles without changing their default pop-back behavior when reached from the Profile tab — additive, not a breaking change to either screen's existing callers. Phases 2–4 (App Detail + per-bullet tailoring + Add Job; Cost Stats + Activity Log; real email sending + Skill Growth + Settings) are scoped in the plan file but not yet built — each still needs its own migration(s) and, for Phase 4 specifically, an external Resend API key + verified sending domain (same shape as the Firebase/Google OAuth setup steps earlier in the project) plus one more product decision about what "send" actually targets, since no recruiter contact email exists anywhere in the data model yet.

**Update (2026-07-10) — Phase 2 shipped:** App Detail, per-bullet tailoring accept/reject, and Add Job — the three items scoped for this phase — are all built and verified end-to-end against the live server with real Gemini calls (not just curl-shaped smoke tests): drafted a real on-demand follow-up (`POST /applications/{id}/followup`, reusing `generate_followup_draft` outside the daily sweep's 7-day gate — a human asking is itself the approval gate), tailored a real resume and approved it with mixed accept/reject choices (`PATCH /tailor/{id}/approve` now takes an optional `accepted: list[bool]`, one per bullet, backward-compatible with the old bodyless global-approve call), and ran the full Add Job pipeline (`POST /jobs/manual/parse` fetches a URL with httpx + strips it with BeautifulSoup + a new `extract_job` LLM task in `services/llm.py`, `POST /jobs/manual` inserts with dedup-key idempotency confirmed by re-posting the same job and getting the same row back). All test data (profile, application, tailored resume, manual job, auth user) created via a throwaway Supabase test user and deleted afterward — same pattern as Phase 1, now via `auth/v1/admin/users` (direct create+confirm) instead of `signup` after hitting Supabase's free-tier email-rate-limit from Phase 1's testing.

`AppDetailScreen` replaces the old stage-picker bottom sheet in `ApplicationsBody` — the `applications.notes` column existed since Brick 7 with no editable UI until now. `ResumeDiffScreen` gained per-bullet "Keep original"/"Use tailored" toggles (prototype `ui.isTailoring`) feeding a new `ResumeGeneratingScreen` (a deliberate ~900ms pause before the resume actually existed to compile, matching the prototype's UI rhythm) → `ResumePreviewScreen` (renders the final bullet text per accept/reject choice, plus skills/education from the profile) → "Submit application" now lives there instead of on the diff screen, reusing the existing `saveToTracker` call. One known limitation: `ResumePreviewScreen` renders bullets as a flat list rather than grouped under their original experience entries, since `POST /tailor/{job_id}` flattens all bullets across every experience into one list before tailoring (`_flatten_bullets`) and doesn't preserve which experience each came from — fixing that would mean changing the tailor endpoint's data shape, out of scope for a preview screen.

**Update (2026-07-10) — Phase 3 built, pending migration apply:** Cost Stats and Activity Log, plus wiring Home's stat grid/"Recent activity" (cut from Phase 1). Re-scoped at the Phase 3 checkpoint before building, per two discoveries: `llm_calls` had no `profile_id` — it predates multi-tenant auth (Brick 9) and was one global stream, so a naive Cost Stats screen would have leaked every user's combined spend to every user. Decision: **migration `006_llm_calls_profile.sql`** adds a nullable `profile_id` column (nullable because `POST /resume/parse` logs a call before a profile row exists — the parse result is what creates it), and every `services/llm.py`/`services/embeddings.py` call site (`parse_resume`, `rerank_job`, `tailor_resume`, `generate_followup_draft`, `extract_job_from_text`, `embed_text`/`embed_texts`) now takes an optional `profile_id` to attribute cost correctly; job-pool embeddings stay unattributed (shared pool, no owner). Second discovery: the plan's Activity Log source (`jobs.ingested_at`) is a global pipeline event, not a user action — decided against including it (user-actions-only), and against inventing an activity-log table; instead `services/activity.py` derives the feed from `applications.state_changed_at` + `applications.followup_drafted_at` + `tailored_resumes.created_at`, all already profile-scoped. `services/cost_stats.py` holds approximate per-model $/1M-token pricing (labeled as such — this is a usage dashboard, not a billing reconciliation) and intentionally drops the prototype's "$X of $Y budget" bar, since no budget concept exists anywhere in this app; showing one would be fabricated data, which Phase 1 already established this codebase avoids (`HomeBody`'s doc comment: "no ... sections here, since those depend on ... data that doesn't exist yet"). `ProfileBody` gained a nav-rows card ("Target roles", "LLM cost & usage") — fixed an incidental gap where `TargetRolesScreen` (built in Phase 1 for onboarding) had no revisit entry point after onboarding completed.

`flutter analyze` / `flutter test` / `flutter build web` are clean, and 8 new pytest cases (`test_cost_stats.py`, `test_activity.py`) plus 2 stale `test_matching.py` cases fixed (they pre-dated Brick 9's `rerank_shortlist(profile, ...)` signature and had been silently broken) all pass.

**Update (2026-07-10) — Phase 3 verified end-to-end after migration 006 was applied:** same throwaway-test-user pattern as Phases 1–2 (`auth/v1/admin/users` create+confirm, real Gemini calls, cleanup after). Uploaded a real resume (rendered with macOS `cupsfilter` from plain text — no PDF fixture existed in the repo, and no `reportlab`/`fpdf` in the venv), reranked a real job, tailored and approved a resume, saved+moved an application to 'applied', and drafted a real follow-up — then confirmed `GET /stats/costs` correctly attributed rerank/tailor/followup costs (parse+embed from the initial upload stayed unattributed as designed, since no profile exists yet at that point) and `GET /stats/activity` returned the tailored/stage-change/followup events in the right order with the right job context. Caught and fixed one real bug this surfaced: `summarize_costs` rounded a bucket's cost to 4dp *before* dividing by the unrounded total to get `pct`, so a single-task month showed 99.9% instead of 100% — fixed by computing `pct` from the unrounded value first, then rounding `cost` after.

**Update (2026-07-10) — HomeBody re-skin gaps found and fixed:** the user flagged that Home still didn't look redesigned. Re-diffing `home_body.dart` against the prototype's `ui.isHome` block (not just re-reading Phase 1's own notes) turned up three elements Phase 1's re-skin had silently dropped without documenting the cut, unlike the deliberately-deferred "Grow your match rate"/"Recent activity" sections: the bell icon with an unread-activity dot, the "New matches ready" info banner, and the "Also matched · See all" link — all present in the prototype markup, all buildable from data Home already fetches. Fixed all three: the bell and banner both use real data (`_activity.isNotEmpty` for the dot, `_matches.length` for the banner copy — no fabricated "6 new matches overnight" placeholder), and "See all" needed a small plumbing change since `HomeBody` had no way to switch `MainTabScreen`'s active tab — added an `onNavigateToTab` callback, wired from `MainTabScreen`'s `IndexedStack` construction. Verified visually, not just via `flutter analyze`: built a throwaway Supabase test user with a real profile and 20 real reranked matches, served the release `flutter build web` output over a static HTTP server (the DDC debug server proved too flakey to screenshot reliably — blank canvas on ~half of cold loads), signed in via headless Playwright (coordinate-clicked, since Flutter web's CanvasKit renderer exposes no DOM text for selector-based interaction), and screenshotted the fully-loaded Home showing all three elements live. This is the first UI verification in this project done with an actual rendered screenshot rather than `flutter analyze`/`flutter build web` exit codes alone — worth reusing this Playwright-over-static-build pattern for future visual-regression checks, since `flutter run -d web-server`'s debug compiler was not reliable enough to screenshot.

**Update (2026-07-10) — Phase 4 shipped and verified end-to-end (frontend rebuild complete, Brick 10 next):** the three pieces this phase deliberately left unscoped — re-scoped with the user before building, per the phase's own working mode:
- **Real follow-up sending via Resend**, gated: **migration `007_followup_send.sql`** adds `applications.contact_email`/`followup_sent_at`. New `server/services/email.py` mirrors `notify.py`'s lazy-init shape but *raises* instead of swallowing on failure — a user-initiated send must surface errors, unlike a background push. `POST /applications/{id}/followup/send` requires both a draft and a contact email to already exist, then 502s with a clear message when `RESEND_API_KEY` is unset (no Resend account exists yet — the user chose to build the full path now and complete signup later). The user chose (via AskUserQuestion) a per-application `contact_email` field over sending to the user's own inbox — most faithful to "send it to the recruiter," reusing the existing `PATCH /applications/{id}` endpoint rather than a new one.
- **Skill Growth**: the prototype's `growthSkills` shows a fabricated `+12% matches` per skill with no real data behind it. The user chose (via AskUserQuestion) a real "N of M matches" frequency instead. `services/skill_growth.py` is the Golden-Rule-2 boundary: a new `skill_growth` LLM task (`services/llm.py`) only clusters raw gap text into skill names and returns which input indices belong to each cluster — Python then computes and sorts the actual frequency from those indices. `GET /stats/skill-growth` — observed ~50s for one real user's 20 matches (a single Gemini call whose input scales with match count), so `fetchSkillGrowth()` got the same 3-minute-timeout treatment as this app's other known-slow single-call tasks, which the initial version had missed (default `http.get` has no timeout at all).
- **Settings**: the prototype's 4 toggles included `autoApply`, which conflicts outright with CLAUDE.md's "no auto-submitting anywhere" rule. The user chose (via AskUserQuestion) to ship only the two toggles with real backing behavior: new-match push alerts and follow-up nudges, both gating calls `daily_pipeline.py::_process_profile` already makes unconditionally (one-line `if` guards, not new pipeline logic) — `autoTailor`/`autoApply` are out of scope entirely, not half-built. **Migration `008_notification_prefs.sql`** adds `profiles.notification_prefs jsonb`; a missing/null value reads as "on" everywhere it's checked, so existing profile rows keep today's behavior after the migration lands.

Verified end-to-end with the same throwaway-test-user pattern as every prior phase, plus a direct unit-level check of the pipeline gating (mocked `_draft_pending_followups`/`send_push_notification`, confirmed both skip when prefs are off, both run when on or absent) since triggering real "prefs off, nothing sent" behavior through the full pipeline would need unpredictable real job-pool data. Screenshotted all three new/changed screens via the Playwright-over-static-build pattern from the HomeBody fix above — this surfaced that Skill Growth's real latency (~50s) reads as a stuck loading skeleton without a bound, which is what led to catching the missing timeout. This closes out the frontend rebuild (ADR-009) — Brick 10 (Play Store launch) is next in CLAUDE.md's checklist.

## ADR-010: Render deployment + first working APK build
**Date:** 2026-07-10 · **Status:** accepted

**Context:** The user asked for a working APK with real login and API calls. Two blockers surfaced immediately: (1) `ApiClient._baseUrl` still pointed at `localhost`/`10.0.2.2`, which only ever resolves back to the emulator's own host machine — a real phone has no way to reach either address; (2) Bricks 4-9's entire server implementation (`routers/matches.py`, `tailor.py`, `applications.py`, `pipeline.py`, `stats.py`, `services/auth.py`, `matching.py`, `guardrail.py`, `embeddings.py`, `job_ingestion.py`, `notify.py`, `email.py`, `activity.py`, `cost_stats.py`, `skill_growth.py`, all 7 migrations after 001) existed only in the local working tree — never committed, so GitHub (and therefore Render, which deploys from GitHub) had nothing past Brick 3 to build.

**Decision:** Deployed the server to Render (the hosting choice CLAUDE.md already committed to) rather than a LAN-IP or tunnel workaround, since the user has a Render account and wants this reachable from anywhere, not just a demo on one WiFi network. Concretely:
- Committed and pushed the untracked Brick 4-9 backend (42 files) — a large single commit, done only after explicit user confirmation, since auto-mode's push classifier correctly flagged a big batch push to `main` as needing that confirmation.
- Added `server/Dockerfile` (`python:3.11-slim` + `apt-get install poppler-utils`) — Render's native Python buildpack has no poppler, and `services/llm.py::parse_resume` needs `pdf2image.convert_from_bytes` for the vision-LLM resume parse. A Docker-based service was the only way to get poppler onto Render without switching PDF libraries.
- Created the Render web service and env vars via Render's HTTP API (user supplied a personal API key for this session) — `jobhunt-agent-server` on the free plan, Singapore region (closest to `ADZUNA_COUNTRY=in`), all of `server/.env`'s keys copied over except `FCM_SERVICE_ACCOUNT_PATH` (the service-account JSON itself isn't committed/available to upload, and `notify.py::_get_app` already degrades gracefully to log-only when it's missing — same known gap ADR-007 already accepted, not a new one).
- `ApiClient._baseUrl` now defaults to `https://jobhunt-agent-server.onrender.com`, overridable via `--dart-define=API_BASE_URL=...` for local-server dev against a LAN IP.
- Release APK still signs with the debug keystore (`android/app/build.gradle.kts`'s existing `signingConfig = signingConfigs.getByName("debug")`) — fine for sideloading onto a personal device now; a real upload keystore is Play Store-launch-specific and deferred to Brick 10 proper.
- Local environment had no Android SDK at all (`flutter doctor` showed it missing) — installed via `brew install --cask android-commandlinetools`, then `sdkmanager` for platform-tools/platforms;android-36/build-tools;36.0.0, licenses auto-accepted non-interactively.

**Alternatives considered:** LAN IP or ngrok tunnel — both rejected by the user in favor of Render (see recommendation given: permanent URL, matches existing hosting decision, works from any network). Render free-tier's cold-start spin-down after inactivity is an accepted tradeoff for now, same posture as accepting Render generally in CLAUDE.md.

**Consequences:** First release APK built successfully — `app-release.apk`, 53.5MB, `minSdkVersion 24`/`targetSdkVersion 36`, `INTERNET` permission present, verified signed (debug cert). Verified server-side only via `curl`: `/health` returns 200, an authenticated-only route (`/jobs`) correctly 401s rather than 500ing, confirming the full Brick 4-9 router set imports and boots cleanly on Render. **Not verified**: the actual on-device login flow, resume upload, matching, or any other screen — no physical Android device or emulator was available in this environment to install and click through the APK. Google Sign-In's redirect URL (`com.jobhuntagent.jobhunt_agent://login-callback/`) being registered in Supabase's Auth dashboard is also unverified from code — if Google sign-in fails on-device but email/password works, that dashboard setting is the first thing to check. This is the same category of gap ADR-008/009 already flagged repeatedly: code-level and server-level verification happened, human-in-hand device verification did not.

## ADR-011: Async background-task pattern for long LLM endpoints (202 + poll)
**Date:** 2026-07-11 · **Status:** accepted

**Context:** `POST /matches/rerank` ran up to 20 sequential Gemini calls (~20-25s each) while the phone held one HTTP connection open for minutes. Android's network stack / Render's free tier dropped the socket — the observed `ClientException: Software caused connection abort`. The client's 10-minute timeout was masking the symptom, not fixing the cause. `POST /pipeline/run-mine` (full agent loop) and `POST /tailor/{job_id}` (single 20-60s call) had the same shape.

**Decision:** Standard async-job pattern, kept deliberately boring: migration `009_background_tasks.sql` adds a `background_tasks` table (`pending → running → done|failed`, enforced by a CHECK constraint — Golden Rule 2, states in code/SQL, never LLM). The three endpoints now create a row, schedule the unchanged work via FastAPI `BackgroundTasks`, and return `202 {"task_id"}` immediately; `GET /tasks/{id}` is the ownership-checked poll endpoint. Client-side, a `TaskCenter` singleton (plain `ValueNotifier`s, no new packages) owns the poll loops — 5s interval backing off to 10s after a minute, giving up at 10 — so polling survives tab switches in the `IndexedStack` and completion toasts fire wherever the user is. The cron path `POST /pipeline/run` stays synchronous: Render's cron runner has no socket-timeout problem.

**Alternatives considered:** WebSockets/SSE (new infra for three endpoints; polling every 5s is fine at this scale), Celery/RQ (a real queue is overkill for a single-instance free-tier deploy; FastAPI BackgroundTasks runs in-process). Known tradeoff: an in-process background task dies with the dyno — the row stays `running` forever; the client's 10-minute give-up covers that honestly.

**Consequences:** Re-rank/agent-run/tailor return instantly; normal 30s client timeouts everywhere; the aborted-connection failure mode is gone by construction. The stuck-`running` case surfaces as a client-side timeout message with Retry.

## ADR-012: ATS resume PDF via ReportLab (deterministic, server-side)
**Date:** 2026-07-11 · **Status:** accepted

**Context:** Phase 4B needs "Create Resume PDF" — compiling the human-approved tailored bullets + stored profile into a file recruiters' ATS parsers can actually read.

**Decision:** ReportLab on the server (`services/resume_pdf.py` + `GET /tailor/{id}/pdf`). Pure-Python (no new Dockerfile packages), deterministic assembly of already-guardrailed, human-accepted content — no LLM call anywhere in the step (Golden Rule 2/4). ATS constraints hard-coded: single column, Helvetica, standard UPPERCASE headings, no tables/images, real text layer (tests round-trip the PDF through pypdf and assert accepted text appears and rejected tailored text never leaks). The endpoint returns raw `application/pdf` — the one documented exception to the `{"data": ...}` envelope. Client downloads bytes → temp file → native share sheet (`share_plus` + `path_provider`).

**Alternatives considered:** client-side Dart `pdf` package (would duplicate the accepted-bullets compilation logic client-side and drift from the server's single source of truth); HTML→PDF via headless Chrome (heavy system dependency on Render); LaTeX (ditto).

## ADR-013: Form autofill = prefill URL + human submit, deterministic Google Forms parse
**Date:** 2026-07-11 · **Status:** accepted

**Context:** Phase 6's "the agent fills, the human reviews and taps submit". Two design questions: how to read a form, and how to hand the user a filled one without ever submitting on their behalf.

**Decision:**
- **Parsing:** public Google Forms embed their full structure as `FB_PUBLIC_LOAD_DATA_` JSON in the viewform HTML — parsed deterministically in `services/form_parser.py`, zero LLM. Non-Google pages fall back to BeautifulSoup text + a new `extract_form` LLM task, flagged `source="llm_extracted"` and presented as best-effort. Sign-in-gated forms return a typed `form_auth_required` error the app maps to an open-in-browser fallback.
- **Filling:** new `form_fill` LLM task maps profile facts to questions — null where the profile has no answer, never an invented phone/email/ID. A deterministic mini-guardrail (`verify_choice_answers`) then checks every choice/checkbox/dropdown answer is an exact option member; mismatches are flagged, never silently accepted (ADR-004's posture, applied to forms).
- **Submission model:** the deliverable is a Google prefill URL (`?usp=pp_url&entry.<id>=...`, built in pure Python) opened in the user's own external browser, signed into whatever Google account they pick. File-upload questions are listed as "attach manually" (Google forbids programmatic file answers). Neither app nor server ever POSTs to `formResponse` — grep-provably absent.

**Alternatives considered:** WebView JS-injection fill (v2 candidate for sign-in-gated forms; more capable but fragile and much closer to "acting as the user" than v1 should be); server-side submission (violates the golden rule outright, rejected).

**Consequences:** Fills persist to `form_fills` (migration 012) for history. The whole flow degrades honestly: unparseable → clear error; sign-in-required → browser fallback; unanswerable questions → visibly empty rows the user completes themselves.

## ADR-014: Migrated Render → Google Cloud Run
**Date:** 2026-07-11 · **Status:** accepted

**Context:** ADR-010 accepted Render free-tier cold-start spin-down "for now." That tradeoff started actually hurting: re-rank/tailor calls routinely hit `TimeoutException after 0:00:30` when the server had spun down, and general app responsiveness was inconsistent. Render free-tier cold start is ~30-60s; Cloud Run's is ~2-5s because it's a proper container runtime rather than a suspended VM, and it has a genuinely-free (not trial-credit) tier. Considered Oracle Cloud's Always-Free VM too (zero cold start at all) but rejected it — real ops burden (self-managed systemd/nginx/crontab) plus a documented reputation for reclaiming "idle" free resources, a bad trade for an app about to onboard real Play Store beta users.

**Decision:** Deployed `server/`'s existing Dockerfile as-is to Cloud Run (`jobhunteragent-502002` project — reused an existing empty org project instead of the one freshly created, after the personal billing account hit its 5-linked-project quota; region `asia-south1`/Mumbai, closer to `ADZUNA_COUNTRY=in` than Render's old Singapore region). Concretely:
- All of `server/.env` plus `firebase-service-account.json` moved into Secret Manager (`GEMINI_API_KEY`, `SUPABASE_SERVICE_KEY`, `SUPABASE_ANON_KEY`, `ADZUNA_APP_KEY`, `RAPIDAPI_KEY`, `PIPELINE_SECRET`, `FCM_SERVICE_ACCOUNT_JSON`) — closing the gap ADR-007/010 left open (FCM's service-account JSON was never uploaded to Render). Non-secret config (`SUPABASE_URL`, model names, `TARGET_ROLES`, etc.) went in as plain env vars via an `--env-vars-file` to sidestep `gcloud`'s comma-as-delimiter parsing on `TARGET_ROLES`/`TARGET_LOCATIONS`.
- **Cron auth upgraded**: rather than reproducing Render's shared-secret-header cron trigger verbatim, `POST /pipeline/run` now accepts *either* the original `X-Pipeline-Secret` header (kept for Render's transition period) *or* a Google-signed OIDC bearer token (`services/auth.py::verify_pipeline_cron`/`_verify_scheduler_oidc`) — Cloud Scheduler authenticates as a dedicated `pipeline-scheduler@jobhunteragent-502002.iam.gserviceaccount.com` service account with no shared secret stored anywhere. This was the user's explicit choice over reusing the static-header approach, made after auto-mode's safety classifier correctly flagged that a Cloud Scheduler job's HTTP headers are stored in plaintext in its job config (broader-privilege-visible than Secret Manager).
- Fixed [resume_diff_screen.dart](app/lib/screens/resume_diff_screen.dart) double-`Navigator.pop()` bug found while triaging the same "things feel broken" report: `_generate()` awaited the pushed `ResumePreviewScreen`'s future and then popped again unconditionally, so *any* back-tap out of the preview double-popped mid-transition — the actual cause of a `RenderBox was not laid out` assertion the user hit, unrelated to Render/Cloud Run.
- `ApiClient._baseUrl` now points at the Cloud Run URL; `rerankShortlist`/`tailorResume`/`runPipeline`/`getTaskStatus` timeouts bumped 30s → 60s (cold starts, even Cloud Run's short ones, plus network variance, were tight against the old value); `main.dart` fires an unawaited `fetchHealth()` at launch as a best-effort wake-up nudge.

**Bug caught mid-migration:** the first secret-upload pass piped `awk '{print $1}'` into `gcloud secrets create --data-file=-`, and `awk print` appends a trailing newline — every secret silently carried one extra `\n` byte. Invisible almost everywhere except RapidAPI's HTTP client, which rejects header values containing `\n` outright (`Illegal header value`), surfacing as JSearch queries failing during the first live pipeline run. Fixed by re-adding all six secret versions via `awk '{printf "%s", $1}'` instead, then forcing a new Cloud Run revision (`--update-secrets`) since Cloud Run resolves `:latest` once at container startup, not on every request — the already-running instance kept serving the bad value until redeployed.

**Alternatives considered:** Google Cloud Run vs. Oracle Always-Free VM — covered above. Keeping Render but paying for its Starter tier (no cold start) — rejected by the user in favor of migrating to a platform with a real free tier instead of paying to patch the one already chosen.

**Consequences:** `/health` and an authenticated-only route (`/jobs` → 401) verified against the live Cloud Run URL, same bar ADR-010 used for Render. The Cloud Scheduler → OIDC → `/pipeline/run` path was verified for real (not just curl-shaped): manually triggered the job twice, caught the trailing-newline bug from the first run's JSearch failures, fixed it, and confirmed a clean `200 OK` on the second run. **Render is still live** — not paused or deleted, kept as a fallback until the user has run the app against Cloud Run for a few real days. `PIPELINE_SECRET` and the `X-Pipeline-Secret` code path should be removed once Render is decommissioned, since the OIDC path fully supersedes it. Not verified on-device (same standing gap as every ADR since -007): the actual phone app talking to the new URL.

## ADR-015: Bug batch — job-match relevance, tailoring concurrency, stale OAuth fallback
**Date:** 2026-07-11 · **Status:** accepted

**Context:** Three separate "feels broken" reports investigated together: (1) jobs shown looked unrelated to the uploaded resume, (2) tailored resumes looked identical across different jobs, (3) Google sign-in was landing on a live Render page instead of returning to the app.

**Job-match relevance — root cause and fix:** `jobs_embedding_idx` (an ivfflat ANN index, migration 001) was created in the same migration as the `jobs` table itself, i.e. trained on zero rows. IVFFlat's cluster centroids are fixed at `CREATE INDEX` time and never self-retrain as rows are inserted, and `ivfflat.probes` was never set anywhere (defaults to 1) — so stage-1 similarity search was scanning ~1% of an index built on degenerate centroids, handing stage-2 LLM rerank an already-irrelevant shortlist. Fixed by `013_fix_job_embedding_relevance.sql`, which drops the index entirely; `match_jobs_by_similarity` falls back to an exact brute-force scan, which is always correct and fine at current beta job-pool sizes (low thousands of rows). Revisit with a properly-tuned ivfflat (built *after* the table is populated) or an HNSW index once the table is large enough (~50k+ rows) for sequential scan latency to matter. **Requires manually applying the migration in Supabase** (see MANUAL_STEPS.md §1) — not automatic.

**Tailoring concurrency — root cause and fix:** [task_center.dart](app/lib/services/task_center.dart)'s `TaskCenter` tracked in-flight tasks keyed only by `TaskKind`, not by which job a tailor task was for. `start()` was a no-op whenever a task of that kind was already active (line ~74), so opening a second job's tailoring screen while a first job's tailor call was still in flight silently dropped the second request — that screen never got its own tailored bullets and either hung on the loading skeleton or, once addressed, could resolve to the wrong job's completion event. Fixed by threading an optional `id` (the jobId) through `start`/`notifierFor`/`isActive`/`retry`/`clearIfFinished`, so tailoring is now "one active task per kind+id" instead of "one active task per kind" — `rerank`/`pipeline` call sites pass no id and keep their original single-global-task behavior unchanged.

**OAuth fallback — root cause and fix:** MANUAL_STEPS.md's original Phase 1B fix pointed Supabase's Site URL (the fallback used whenever the OAuth redirect isn't allow-listed) at the Render URL — correct at the time, but Render is still live post-ADR-014, so the stale fallback kept resolving to a real page instead of erroring loudly. Updated MANUAL_STEPS.md §2 to point Site URL at the app's own deep link (`com.jobhuntagent.jobhunt_agent://login-callback/`) instead of any backend URL, so the fallback can never again land on a web page regardless of which backend host is live. **Dashboard-only config change, not code** — must be applied manually in the Supabase project settings; nothing in this repo can do it.

**Consequences:** The tailoring fix is a pure code change, applied. The relevance fix and OAuth fix both require a manual step outside this repo (SQL migration; Supabase dashboard setting) — flagged in MANUAL_STEPS.md, not yet confirmed applied. None of the three were re-verified on-device.

## ADR-016: Onboarding — student/experienced + USN/college; form-fill answer reuse
**Date:** 2026-07-11 · **Status:** accepted

**Context:** Two feature requests bundled with the ADR-015 bug batch: (1) onboarding never asked whether the user is a student or an experienced professional, or collected a student's USN/college when the resume itself didn't have one; (2) the form auto-fill feature (ADR-013) re-derived every answer from scratch on every form, even for questions the user had already answered identically on a previous form (phone number, visa sponsorship, notice period, expected salary...).

**Onboarding — decision:** Added a new `student_info` onboarding step (migration 014) between `review` and `roles`: a two-way student/experienced choice, plus USN and college-name fields shown *only* when the resume parser (services/llm.py's `PARSE_SYSTEM_PROMPT`, extended to also extract a `usn` when literally printed on the resume) didn't already find them. College name backfills `education[0].institution` rather than getting its own column — avoids storing the same fact twice. Deliberately minimal scope (no graduation year/branch/CGPA) per explicit user choice, kept skippable like every other onboarding step.

**Form-fill reuse — decision and root-cause note:** The naive version of "learn from past forms" doesn't work off `form_fills.answers` alone, because that row was written from the raw LLM guess at fill time (ADR-013) — the user's in-app edits were never persisted back, so "history" would just be repeating old guesses, not what the user actually confirmed. Fixed the underlying gap first: `PATCH /forms/fills/{id}` (new) persists the user's final, possibly-edited answers right before `form_fill_screen.dart` opens the prefilled form. `POST /forms/fill` now looks up the last 50 fills for the profile, builds a normalized-question → most-recent-answer map (`services/form_parser.py::normalize_question`/`apply_answer_history`, fuzzy-matched via rapidfuzz's `token_set_ratio` so "Phone number" still matches "Your phone number:"), and silently overwrites the LLM's answer for any question that matches — still shown as an ordinary editable row, still re-verified against the *current* form's choice options (a reused answer valid on one form's dropdown may not be valid on another's) before being trusted.

**Alternatives considered (form-fill):** A visible "reused from last time" badge — user chose silent reuse instead, since the guardrail/edit-review flow already surfaces anything wrong.

**Consequences:** Both are additive, backward-compatible changes — `014_student_info.sql` needs manual Supabase application (MANUAL_STEPS.md §1) like every migration in this project. `flutter analyze` and the expanded `test_form_parser.py` (4 new cases covering normalization, fuzzy reuse, and the re-verification-after-reuse edge case) pass; neither was exercised on-device or against a live form.

## ADR-017: JD-paste resume builder — a standalone entry point into the existing tailoring pipeline
**Date:** 2026-07-11 · **Status:** accepted

**Context:** Requested: a page to paste a JD as text or upload it as a PDF, generate a resume tailored to it, and download it — without needing the JD to already exist as a matched job — using a cheaper LLM tier than the rest of the app.

**Decision — reuse over rebuild:** Rather than a parallel tailoring pipeline, this is two new endpoints (`POST /jobs/from-jd/parse`, `POST /jobs/from-jd`) that create a `jobs` row (`source='jd_paste'`, no `redirect_url` — a pasted JD has no source link) and a `saved` `applications` row, then hand off to the *existing* `/tailor/{job_id}` → `ResumeDiffScreen` → `ResumePreviewScreen` (download already built, Phase 4B) flow completely unchanged. That flow doesn't know or care where a job came from, so nothing about it needed touching for the diff/approve/download UX — the only new frontend surface is [jd_resume_screen.dart](app/lib/screens/jd_resume_screen.dart), a paste-or-upload-then-review screen mirroring [AddJobScreen](app/lib/screens/add_job_screen.dart)'s existing two-step parse-then-review shape (JD text → `extract_job_from_text`, or PDF → pypdf text extraction first, same technique as `routers/resume.py`'s resume parser).

**Cheaper model, threaded not hardcoded:** Added `settings.gemini_model_lite` (`gemini-2.5-flash-lite`, ~3x cheaper input / ~6x cheaper output than `gemini-2.5-flash` per `services/cost_stats.py`'s pricing table) and an optional `model` override param on `tailor_resume`/`extract_job_from_text`/`_call_gemini` (`services/llm.py`) — every other caller passes nothing and keeps using `settings.gemini_model`. `routers/jobs.py`'s `from-jd/parse` passes the lite model explicitly; `routers/tailor.py`'s `tailor_and_store` checks `job.get("source") == "jd_paste"` to decide, so the *existing* shared `/tailor/{job_id}` endpoint runs cheap for these jobs specifically without any per-request flag leaking into its API surface. Added a `gemini-2.5-flash-lite` row to `_PRICING_PER_MILLION_TOKENS` so CostStatsScreen's totals reflect the real (lower) spend instead of silently falling back to flash's pricing for an unrecognized model string.

**Alternatives considered:** A fully separate tailoring implementation for this feature — rejected; would have duplicated the guardrail/PDF-compile/approve logic for no product benefit, and violates CLAUDE.md's "don't add features beyond what the task requires."

**Consequences:** `flutter analyze` and the full server test suite (51 tests) pass. Not exercised on-device or against a real PDF/pasted JD — the PDF-text-extraction path in particular (pypdf against arbitrary user-uploaded JD PDFs, not resumes) is unverified beyond code review.

## ADR-018: Job source expansion — Adzuna India-tuning + Greenhouse/Lever fetchers
**Date:** 2026-07-11 · **Status:** accepted

**Context:** Coverage for Indian students was thin. A companion planning doc proposed three additive workstreams inside ADR-003's "legal APIs only" boundary: confirm the Render→Cloud Run infra story (ADR-014) has no gaps, tune Adzuna/JSearch for India, and add Greenhouse/Lever public job-board fetchers.

**Phase 0 audit — no gaps found:** Checked the live Cloud Run service directly (`gcloud run services describe`) against `.env.example`: every var present, all six secrets resolve via Secret Manager `secretKeyRef` (not plain env vars), Cloud Scheduler's OIDC audience/service-account match `config.py` exactly, `/health` returns 200. ADR-014's migration was clean; nothing to fix here.

**JSearch quota discovery — changed the plan mid-flight:** RapidAPI's response headers (`x-ratelimit-requests-limit`/`-remaining`) showed JSearch's free tier caps at **200 requests/month**, with only 49 remaining before the cycle resets — already near-exhausted by the existing 3-roles × 2-locations × 30-days query pattern (~180/month). The original plan's Phase 1b (add an `INTERN` query variant + more locations to JSearch) would have ~6x'd that volume and exhausted the quota in ~2 days. **User chose to leave JSearch's query pattern untouched** and apply India-tuning to Adzuna only, whose free tier had generous headroom in live testing.

**Decision — Adzuna only:**
- `services/job_sources.py::fetch_adzuna()` now runs two query variants per role×location — the role as-is, and `f"{role} intern"` — since Adzuna's `/v1/api/jobs/in/categories` has no internship-specific category for India (verified live); the free-text keyword append is the only way to surface internship-labeled postings.
- Added `settings.adzuna_locations` (falls back to the shared `target_locations` when unset) so Adzuna can query a wider Indian city list (Bangalore, Hyderabad, Pune, Delhi NCR, Mumbai, Chennai) without inflating JSearch's shared `target_locations` and its call count. Applied live via `gcloud run services update --update-env-vars="^:^ADZUNA_LOCATIONS=..."` — the `^:^` alternate-delimiter syntax was required again (same comma-parsing gotcha ADR-014 hit with `TARGET_LOCATIONS`).

**Greenhouse/Lever fetchers — decision:** Added `fetch_greenhouse()`/`fetch_lever()` to `job_sources.py`, wired into `refresh_job_pool()`'s existing `asyncio.gather()` fan-out (no new orchestration logic, dedup is already source-agnostic). Two things worth recording:
- **Greenhouse's `content` field is HTML whose own tags are entity-encoded** (e.g. the literal string `&lt;div&gt;`, not a real `<div>`) — verified live against the `postman` board. BeautifulSoup on the raw field is a no-op (no real tags to find), so `_strip_html()` calls `html.unescape()` first. Missing this would have shipped garbage-entity text into every Greenhouse job's description.
- **Greenhouse's payload includes `company_name` per posting** — contrary to the original plan's assumption, no need to hand-maintain a display name alongside each board token in config. Lever's payload has no equivalent field, so `LEVER_COMPANIES` stays `"slug:Display Name"` pairs.
- Seed lists were discovered by live curl/web-search verification, not assumed: Greenhouse — `postman`, `groww`, `razorpaysoftwareprivatelimited` (Razorpay), `phonepe`. Lever — `cred`, `meesho`, `zeta`, `freshworks`. Several plan-suggested candidates (Zerodha, Chargebee, Browserstack, Clevertap, Innovaccer, Whatfix, Rippling) returned 404 on both APIs — likely a different/custom ATS, not added.
- The "Indian salaries showing `$`" bug the plan flagged as worth fixing in the same pass **turned out to already be fixed** (`ADZUNA_COUNTRY_CURRENCY` map + JSearch's native currency field, both already in `job_sources.py` before this session) — no action needed.

**Verification:** 55/55 server tests pass (4 new, mocked, covering field-mapping/HTML-unescape/epoch-millis-conversion/per-board-error-isolation for both fetchers). Deployed to Cloud Run (revision `jobhunt-agent-server-00005-zvk`). Ran `refresh_job_pool()` directly against production Supabase (not through `POST /pipeline/run`, which would have triggered the full per-user loop — real push notifications and LLM follow-up drafts to actual beta users — deliberately avoided): 300 fetched, 205 inserted, live row counts by source `{greenhouse: 181, jsearch: 96, lever: 24, adzuna: 15}`, 166 India-located rows, Greenhouse/Lever descriptions confirmed free of stray HTML entities. Did **not** verify the rerank/shortlist step against a real user profile — that requires an authenticated session and touching production user data, left for the user to check in-app.

**Consequences:** Dart needed zero changes — `Job.source` is a plain string and `jobs_list_body.dart`'s filter chips are derived dynamically from whatever source values are present. Cloud Run infra parity (Phase 0) and the currency bug were already correct going in; this session's real net-new surface is the Adzuna intern/location tuning and the two new fetchers.

## ADR-019: Resume tailoring framework — JD analysis, layout selection, gap disclosure
**Date:** 2026-07-11 · **Status:** accepted

**Context:** The tailoring flow (Brick 6) only rephrased experience bullets. The user supplied a real tailoring methodology — analyze the JD (role type, ordered hard requirements, culture signal, exact title), reframe a summary line, reorder bullets and skills toward the JD, pick a layout, vary an accent color, and disclose skill gaps honestly — and asked to apply it to both the matched-job tailoring path and the JD-paste "custom resume maker." Both paths already share `tailor_and_store` → `tailor_resume` → `verify_bullets` → PDF (ADR-017), so this is one change, not two.

**Decision — split cleanly along Golden Rule 2 (LLM = language, code = logic):**
- **LLM (`services/llm.py` `TAILOR_SYSTEM_PROMPT`, temp 0.6):** expanded to a two-step prompt. Step 1 emits an `analysis` block — `role_type` (8-way enum), `hard_requirements` (in the JD's own priority order), `culture_signal` (`startup`/`corporate`), `jd_title` (verbatim). Step 2 emits the existing `tailored_bullets` (now most-relevant-first), a `summary_line` reframed toward the role from profile facts only, and `skills_ordered` (a reordering of the candidate's own skills). The user prompt now also feeds the LLM the candidate's headline and skills list (previously bullets only) so it can reframe and reorder them. Schema in `models/tailor.py`: `JdAnalysis` + `skills_ordered` on `TailorLlmResponse`.
- **Code enforces every honesty claim (`services/guardrail.py`), never the prompt:** the existing `verify_bullets()` is unchanged; two new deterministic post-checks join it. `verify_skills()` intersects the LLM's `skills_ordered` back to the real profile skills (fuzzy `ratio ≥ 80`, keeps LLM order for kept skills, appends any it dropped) so an invented skill can never enter the column. `compute_gaps()` computes which `hard_requirements` the candidate can't back up — for **disclosure to the user, never written onto the resume**, exactly the guardrail-flagged-bullet posture. Skill-in-text matching uses a **whole-word** check, not `partial_ratio` over the whole document: an early version false-flagged "React" as present because it fuzzy-matched a substring of "practices" — a real correctness bug the tests now pin.
- **Layout / accent / title are code, from the LLM's signals (`services/resume_pdf.py`):** `culture_signal == "startup"` → a 60/40 two-column layout (framework §3.2), otherwise single-column (§3.3, the safest ATS parse and the default when there's no analysis). The two-column layout is a **single borderless two-cell `Table`** (no grid, no nesting) specifically so the text layer still extracts left-cell-then-right-cell in order — honoring the framework's own §3.6 warning against ATS-breaking tables while still delivering the visual. Accent color (§3.7) is picked deterministically from the job id out of a dark, high-contrast palette (stable across recompiles, zero ATS effect). The exact `jd_title` (§3.8) prints under the name for ATS literal title-matching. A one-page auto-fit loop (§1) rebuilds at shrinking type scales until the story fits one page, with a `KeepInFrame` shrink at the tightest scale as a floor.

**Two-column vs single-column — the real tension:** the framework wants two-column by default but its own rule §3.6 warns tables/columns can scramble ATS text extraction. Chosen (with the user): build both, code-selected from `culture_signal`, and implement the two-column path as a single flat two-cell table rather than frames — the parse order stays coherent, verified by a test that reads the JD title, reframed summary, and accepted bullet back out of the two-column PDF.

**Storage:** migration `015_tailor_analysis.sql` adds nullable `analysis jsonb` + `gaps jsonb` to `tailored_resumes`. Nullable is deliberate — pre-ADR-019 rows (bullet-only) still render fine, falling back to the profile's own summary/skills and single-column. **Not yet applied to Supabase — manual step, like prior migrations.**

**Frontend:** `TailoredResume`/`JdAnalysis` Dart models parse the new fields (no `api_client` change — it already passes the row JSON through `fromJson`). `resume_diff_screen.dart` stacks three banners at the top: JD context (role type + matched title), the existing guardrail status, and — when non-empty — the gap disclosure ("Requirements you may not fully meet … not claimed on your resume").

**Verification:** 62/62 server tests pass (7 new — skill subsetting, invented-skill rejection, light-recasing match, gap flagging incl. the whole-word fix, JD-title/summary/two-column extraction, and one-page auto-fit for a long profile). `flutter analyze` clean on the two changed Dart files. **Not** exercised against a live Gemini call or on-device — the actual LLM output shape, real two-column PDFs from real profiles, and the migration apply are unverified beyond tests and code review.

## ADR-020: Gemini thinking disabled on every task — the invisible majority of the bill
**Date:** 2026-07-12 · **Status:** accepted

**Context:** The user reported Gemini usage was "so much." The `llm_calls` table said otherwise: 247 calls, ~140K input and ~60K output tokens over four days — pennies. The table was lying, and not by a little.

**Root cause:** `gemini-2.5-flash` reasons by default. Those thinking tokens **bill at the output rate** (\$2.50/1M — 8x the input rate), and the SDK reports them in `usage_metadata.thoughts_token_count` — a field `_log_llm_call` never read. It logged `candidates_token_count` alone. Measured directly against a rerank-shaped prompt: **759 thinking tokens to produce an 18-token answer**, none of it recorded. Real output spend was several multiples of what the cost dashboard showed, and every task in `services/llm.py` is structured extraction or scoring against an explicit JSON schema — none of them is open-ended reasoning that a thinking budget buys anything for.

**Decision:** `_call_gemini` now sets `thinking_config=ThinkingConfig(thinking_budget=0)` for every task, and reports `tokens_out = candidates + thoughts` — the number Google actually bills — so `services/cost_stats.py` stops understating the total.

**Verified, not assumed:** the same prompt returns the *identical* answer (`fit_score: 95`) with thinking on (759 thinking tokens) and off (0). `thinking_budget=0` was probed against both `gemini-2.5-flash` and `gemini-3.1-flash-lite` before adoption — both accept it; the 3.1-lite tier already defaults to no thinking. Quality cost: none observed. Latency drops as a free side effect.

**Consequence:** historical `llm_calls` rows under-report output and are not comparable with post-ADR-020 rows. This is accepted — a cost dashboard that is honest going forward beats one that stays consistently wrong.

## ADR-021: Batched, role-aware re-ranking — cost and match quality had the same root cause
**Date:** 2026-07-12 · **Status:** accepted

**Context:** Two complaints that turned out to be one bug. (1) Re-ranking was **137 of 247 Gemini calls and ~87% of all input tokens** — by far the dominant spend. (2) Matches ignored the user's target role: a profile with `target_roles = ['frontend developer', 'Full stack developer']` was being scored against "Key Account Director" postings. `target_roles` was **write-only** — the onboarding screen stored it, `PATCH /resume/profile/target-roles` saved it, and *nothing in `matching.py`, `embeddings.py`, or `llm.py` ever read it.* The agent never knew what job the user wanted. Both problems are the same waste: LLM calls spent on jobs that were never plausible.

**Measured before deciding:** stage-1 cosine similarity is **squashed into 0.780–0.845** (median 0.807) across 114 real matches — embeddings of "any job" vs "any resume" are all mildly alike, so an *absolute* similarity floor discriminates nothing and was rejected. 94 of those 114 matches scored `skip`. The re-ranker was overwhelmingly being paid to say "no."

**Decision — three changes, each on the right side of Golden Rule 2:**
- **Prescreen in Python (stage 1.5, `_prescreen`):** a lexical role-relevance gate drops postings outside the candidate's discipline *before* they cost a Gemini call. A job survives on any overlap between its title and the target-role vocabulary (`_ROLE_SYNONYMS`, hand-maintained and deliberately small — a junk filter, not a taxonomy), or failing that, on **two or more** real skills named in its body (one is too easy to hit by coincidence — "communication", "excel"). Safety valve: if *nothing* survives, fall back to the similarity-ordered shortlist rather than show an empty board. It fires only on empty — one on-target job is a better board than one on-target job padded with nine sales postings.
- **Batch the survivors (`llm.rerank_jobs`):** the profile is identical for every job in a shortlist, so one-call-per-job re-sent it N times. Now `RERANK_BATCH_SIZE = 10` jobs are scored per call, with a compact profile (the JSON dump of the full `ResumeProfile`, education years and all, was replaced with the headline/skills/experience that actually move a fit score) and the JD capped at 2000 chars. Ordering is guaranteed **in Python**, not by the prompt: the model echoes each job's 1-based `job_ref` and the caller re-slots by it; a job the model skips raises `RerankError` rather than silently misaligning every score after it.
- **Role intent, boosted in code:** the re-ranker is finally told the user's `target_roles` and returns `role_alignment` (0.0–1.0) — a *language* judgment ("is 'React Engineer' the frontend job this person asked for?"). The arithmetic is ours: `_final_score` adds up to `ROLE_BONUS_POINTS = 15`, and `_verdict_for` recomputes apply/stretch/skip **from the boosted score** (the model's own verdict predates the boost and would contradict it). A boost, never a penalty — a strong off-target job can still outrank a mediocre on-target one, per the user's explicit choice of "strong boost, no hard exclusion."
- **`target_roles` now feed the stage-1 embedding** (`profile_embedding_text` leads with "Seeking X roles"), so the shortlist itself is pulled toward the discipline the user is hunting in. Consequence: `PATCH /resume/profile/target-roles` **must now re-embed** — its old comment ("a preferences update has no business triggering a profile re-embed") was correct when roles were write-only and is now exactly wrong.

**No migration.** The role boost is folded into the existing `matches.fit_score` and the verdict recomputed from it, rather than adding `role_alignment`/`final_score` columns. Deliberate: this project has no direct Postgres URL (DDL means a manual Supabase SQL-editor step), and unapplied migrations have already caused one production outage this session — see ADR-022. A schema-free fix deploys atomically with the code.

**Verified against production data, not mocks:** on the real profile and real 368-job pool, re-ranking the same 20 jobs went from **20 calls / 22,752 input tokens → 2 calls / 6,344 input tokens (−90% calls, −72% input tokens)**, counted with the live token counter. A real batched call scoring 8 real jobs returned correctly-ordered verdicts and the boost behaved: "Key Account Director" → `role_alignment 0.0`, final 10, `skip`; "Lead Full Stack Developer" → `role_alignment 1.0`, raw 60 boosted to 75. 72/72 server tests pass (11 new, covering prescreen junk-dropping, skill-overlap survival, the empty-board valve, chunking, and the boost/verdict arithmetic).

**Known limit:** on the *current* pool the prescreen drops 0 of the top-40 shortlist — similarity already floats developer jobs above the sales ones, so it acts as a guard rather than a saver here. Its value shows up as the pool grows and as `target_roles` diverge from the resume. The batching is what delivers today's saving.

## ADR-022: The tailored-resume PDF bug was a stale deploy, not a code bug
**Date:** 2026-07-12 · **Status:** accepted

**Context:** The user reported that the resume PDF "is still not updated to the latest PDF maker with new rules and structured formatting" — after ADR-019 shipped exactly that.

**Diagnosis:** the code was right and had never run. The live Cloud Run revision (`jobhunt-agent-server-00006-blb`) was deployed at **2026-07-11T18:09:11Z**; the ADR-019 commit (`728338e`) landed at **2026-07-11T18:17:42Z** — **eight minutes later**. Production was serving the previous revision. Corroborated in the database: all five `tailored_resumes` rows had `analysis = NULL`, because the running server didn't know that column existed. `compile_ats_pdf` then did exactly what ADR-019 designed it to do with a null analysis — fall back to the legacy single-column layout with the profile's own headline and skill order. The "old PDF" was the documented fallback path, firing correctly, on data written by stale code.

**Notable:** migration `015` *had* been applied (the columns existed) even though ADR-019 recorded it as a pending manual step — so the schema was ahead of the deploy, the reverse of this project's usual failure mode. Neither was verified at the time; the lesson is that "tests pass + committed" is not "shipped," and this repo has now been bitten by the gap between those twice.

**Verified:** ran `tailor_and_store` + `compile_ats_pdf` against the real profile and a real Flutter job on the current code. `analysis` populated (`role_type: mobile`, `culture_signal: startup`, `jd_title: "Flutter Developer"`, reframed summary, JD-priority `skills_ordered`, `gaps: ['Flutter SDK', 'Dart programming language', 'RESTful APIs']`, `guardrail_flags: 0`), and the compiled PDF rendered to PNG and inspected: two-column startup layout, exact JD title under the name, one page. The framework works end-to-end. **The fix is a redeploy, not a code change.**

## ADR-023: DeepSeek as a second provider — one validate/retry/log flow, per-task routing, thinking disabled
**Date:** 2026-07-12 · **Status:** accepted

**Context (Phase 14):** Gemini served every LLM task. Most — job re-ranking, page extraction, follow-up drafting, skill-gap clustering, form extraction/fill — are structured extraction or scoring against an explicit JSON schema, not work needing Gemini's quality. DeepSeek V4 Flash does that class of task at roughly a fifth of the price. The goal: add it *behind the existing validate → retry-once → log discipline* (Golden Rules 3 & 5), not as a parallel path that could drift.

**Verified before coding (model names and prices are not trusted from memory):** against api-docs.deepseek.com on 2026-07-12 — current models `deepseek-v4-flash` / `deepseek-v4-pro`; the `deepseek-chat` / `deepseek-reasoner` aliases are **deprecated 2026-07-24**, so this project names neither. OpenAI-compatible API, so the official `openai` SDK pointed at `deepseek_base_url` drives it. Pricing (cache-miss): flash \$0.14 in / \$0.28 out per 1M, pro \$0.435 / \$0.87. Cache HITS are ~50× cheaper, but `llm_calls` stores `prompt_tokens` (hits + misses together), so `cost_stats.py` prices all input at the miss rate — a deliberate slight OVERESTIMATE, never a flattering one.

**The thinking trap — the whole reason DeepSeek needed care.** DeepSeek's `thinking` parameter **defaults to `enabled`**, and reasoning tokens bill at the output rate. Omitting the parameter — the intuitive way to "not use thinking" — would silently reintroduce the exact bug ADR-020 just fixed on Gemini, on the provider adopted to *save* money. `_call_deepseek` passes `thinking: {"type": "disabled"}` explicitly every call, and reports `tokens_out = completion_tokens` (which *includes* reasoning tokens, so if thinking leaks back on the dashboard shows it). **Measured, not assumed:** on a rerank-shaped prompt, thinking-enabled burned 89 reasoning + 127 completion tokens for the same answer thinking-disabled produced in 48 — 2.6× the output bill, confirming the param is load-bearing.

**Decision — eight per-task functions collapsed onto one shared runner.** Each task in `services/llm.py` carried its own ~50-line copy of call → validate → retry-once → log. Adding a provider to eight copies is how a retry gets forgotten in one, so the loop is now written once in `_run_llm_task(...)` and the task functions became thin prompt-builders. A provider only turns `(system, user, images)` into `(text, tokens_in, tokens_out)`; `_PROVIDER_CALLS` dispatches to `_call_gemini` / `_call_deepseek`. The eight identical `*_RETRY_SUFFIX` aliases became one `RETRY_SUFFIX`.

**Per-task routing (`_TASK_PROVIDERS` + `_provider_for`):**
- `parse` → **Gemini, permanently**. Vision-required; DeepSeek has no image input. `_call_deepseek` raises `LlmApiError` if handed images, so a mis-routed vision task fails loudly instead of silently parsing a resume with the pictures dropped.
- `rerank`, `extract_job`, `followup`, `skill_growth`, `extract_form`, `form_fill` → **DeepSeek**. None guardrail-adjacent; Python still computes every real number.
- `tailor` → **Gemini by default, behind `TAILOR_PROVIDER`** (A5) — the one task the anti-fabrication guardrail sits behind.
- Embeddings → untouched (`gemini-embedding-001` pinned to 768-dim for the `vector(768)` schema; DeepSeek has no compatible endpoint).

**Graceful fallback, not a hard dependency:** a missing `DEEPSEEK_API_KEY` doesn't stop boot or 401 every match — `_provider_for` falls back to Gemini for DeepSeek-routed tasks when the key is absent. Not silent where it matters: `llm_calls.provider` records the provider that ACTUALLY served the call, so `GET /stats/costs` shows a 100%-Gemini split and the misconfig is visible.

**`tailor` opt-in (A5):** `settings.tailor_provider` (default `"gemini"`). `verify_bullets()` is provider-agnostic by construction (fuzzy-matches generated text against the real resume), so flipping the flag needs no code change — but flipping it in production is gated on running `test_guardrail.py` against real DeepSeek bullets and confirming guardrail-pass parity with the Gemini baseline first, recorded here as a new ADR. Until then the default stays Gemini.

**Schema:** migration `016_llm_calls_provider.sql` adds `provider text not null default 'gemini'` (backfills correctly — every prior call *was* Gemini). `cost_stats.summarize_costs` gains a `by_provider` breakdown; `GET /stats/costs` selects the new column. Additive with a default, so safe to apply before the new code — but the new code writes `provider` on every insert, so it must land or every LLM call 500s. In MANUAL_STEPS.md.

**Verified:** 72 pre-existing server tests still pass; 16 new (`test_deepseek_provider.py`; `test_cost_stats.py` DeepSeek pricing/provider-split/pre-migration backfill). A live `deepseek-v4-flash` call returned schema-conforming JSON through both the raw client and `_call_deepseek`. **Not** verified: real guardrail-pass rates on DeepSeek `tailor` output (the A5 gate, deliberately deferred), and the migration apply (manual, pending).

## ADR-024: Input validation hardening — SSRF, length caps, strict request models
**Date:** 2026-07-12 · **Status:** accepted

**Context (Phase 14):** three request-surface weaknesses. (1) `POST /jobs/manual/parse` fetches a user-pasted URL **server-side** — a textbook SSRF vector. (2) Free-text fields had no length cap, so a megabyte of text flowed into an LLM prompt and got truncated silently deep in `llm.py` — the user billed for tokens, never told why. (3) Request models silently ignored unexpected fields.

**SSRF (`_assert_public_url` in `job_ingestion.py`):** before fetching, resolve the hostname and reject if **any** resolved address is non-global (`ip.is_global` is False for RFC1918, loopback, link-local `169.254/16` incl. the metadata endpoint `169.254.169.254`, CGNAT, multicast, reserved), and reject any non-`http(s)` scheme. Every hop is re-checked: `httpx` follows redirects itself, and a public host can 302 you to the metadata IP, so `follow_redirects=False` and each redirect target is re-validated by hand (max 5). 15s timeout unchanged. **Residual risk, documented:** DNS rebinding (resolve-for-check then resolve-to-connect) — closing it needs pinning the connection to the vetted IP; out of proportion to this app's threat model.

**Request-model hardening (`models/common.py`):** a shared `StrictModel` base (`extra="forbid"`) plus explicit `Field(max_length=…)` on every free-text field across resume/application/job request models. Both bounds matter: `max_length` on `list[str]` caps item COUNT, not item length, so a single 10MB "skill" needs the per-item `Annotated[str, Field(max_length=…)]` too. Status-like free strings became `Literal`s (`employment_type`, onboarding `step` join `ApplicationState`), so an unknown value is a 422 before the handler and the hand-written membership checks are deleted. Applied to REQUEST bodies only — `extra="forbid"` on an LLM-RESPONSE model would turn a harmless extra key into a spurious retry. The multipart `jd_text` Form field is capped at the parameter.

**Verified:** 24 new tests (`test_ssrf.py`, `test_request_validation.py`). All prior tests pass.

## ADR-025: Prompt injection stays a documented residual risk, not a solved problem
**Date:** 2026-07-12 · **Status:** accepted

**Context:** user-supplied text (fetched job page, pasted JD, scraped form) is forwarded into LLM prompts. Unlike fabrication — where `guardrail.py` runs a **deterministic Python post-check** and is an actual guarantee — no post-check can prove an injection didn't steer the output.

**Decision:** `wrap_untrusted(text)` wraps attacker-controllable text in a delimited block with an explicit "treat this as data, not instructions" instruction, applied to every user-text-into-prompt path (`rerank` JD bodies, `extract_job`, `extract_form`, `form_fill`). The **one** part enforced in code: both delimiter markers are stripped from the text before wrapping, so a forged closing marker can't break out early. Everything else is a prompt instruction — a request, not a boundary; it lowers the odds and nothing more. Recorded as an accepted residual risk, explicitly *without* the guardrail's deterministic enforcement because none is possible for injection.

## ADR-026: PDF upload safety — resource bounds, and poppler does NOT execute embedded JS (measured)
**Date:** 2026-07-12 · **Status:** accepted

**Context (Phase 14):** `POST /resume/parse` and the JD-paste PDF path hand an uploaded file to `pdf2image` (poppler) and `pypdf`. Two questions: can a malicious PDF execute code, and can a malformed/oversized one exhaust the server?

**Measured, not assumed — code execution:** built a PDF carrying a JavaScript `/OpenAction`, an `/AA` JavaScript entry, and a `/Launch` action running `/bin/sh -c 'touch pwned.txt'`, rendered through the exact poppler path `pdf2image` uses. The page rasterized normally, `pwned.txt` was **never created**, and `otool -L` on `pdftoppm` shows **no JS engine linked** — poppler is a rasterizer and ignores `/OpenAction`, `/AA`, `/Launch`. So the threat is **not** code execution; it's **resource exhaustion** — a 2KB PDF can declare thousands of pages and pdf2image rasterizes each at 200 DPI into RAM, OOM-killing a capped Cloud Run instance.

**Decision (`services/pdf_safety.py`, `pdf_to_page_images`):** four gates, cheapest-rejects-first, nothing reaches poppler/embed/LLM until all pass:
1. **Magic bytes** (`%PDF-`) — content-type and extension are attacker-controlled; first-bytes is the evidence. (Old `content_type` check deleted.)
2. **Size cap** 10MB — before buffering can hurt.
3. **Page-count cap** 20 via pypdf's page-tree parse (no raster) — the gate that actually stops the bomb, because page count is *declared*, not proportional to file size.
4. **Render timeout** 60s via pdf2image's own `timeout` (kills the poppler *subprocess*; a Python-side timeout would return while `pdftoppm` kept running).

The JD-paste path (text-extract only) runs the magic-byte + size gates. All raise `PdfSafetyError` → 422.

**Verified:** 10 new tests (`test_pdf_safety.py`, incl. a proof the page-cap gate rejects *before* the rasterizer runs). Poppler-JS finding from the live experiment above.

## ADR-027: Postgres-backed rate limiting, not in-memory
**Date:** 2026-07-12 · **Status:** accepted

**Context (Phase 14):** the LLM-backed endpoints had no abuse/cost ceiling. Cloud Run runs N instances, so an in-process counter grants N× the quota.

**Decision (`services/rate_limit.py` + migration `017_rate_limits.sql`):** a `rate_limit_events(subject, endpoint, created_at)` table — Supabase is already the shared source of truth, so one honest global count, zero new infra. A FastAPI dependency counts a caller's rows for `(subject, endpoint)` in the trailing window and either passes (recording it) or raises **429 + `Retry-After`** with the standard envelope. Order is prune → count → insert, so an expired row never counts and the Nth passes while the (N+1)th fails. `subject` is **plain text, not a FK to profiles**: most endpoints key on profile id, but `POST /resume/parse` runs *before* a profile exists, so it keys on the auth **user id** via `enforce_rate_limit_by_user` — which also means a FAILED parse (no profile created) still counts, closing the "spam the vision model with garbage PDFs" gap. Limits are config (`rate_limit_*`): rerank/tailor/pipeline-mine 5 per 5 min, resume-parse 3, manual-parse 5, jobs-refresh 10. The cron path `POST /pipeline/run` is **exempt**.

**Client (`api_client.dart`):** `_extractErrorDetail` gets a 429 branch returning the server's friendly "please wait a few minutes" message; TaskCenter surfaces it into a toast, so a rate-limited rerank/tailor shows the wait message, not a crash.

**Verified:** 6 new tests (`test_rate_limit.py`, in-memory table fake). Migration apply is manual/pending.

## ADR-028: Client-side refresh throttling — extend the SWR cache, don't add a second one
**Date:** 2026-07-12 · **Status:** accepted

**Context (Phase 14):** every tab body refetched on view. With the now-rate-limited server, rapid tab-switching or pull-spamming could burn 429s for unchanged data.

**Decision — reuse the Phase 5 stale-while-revalidate cache, don't build a parallel one.** `CacheEntry.cachedAt` already IS a per-key timestamp, so `CacheService` gains `isFresh(key, within: 5min)` and `cachedAtFor(key)` rather than parallel `_last_refresh` keys. The rule, consistent across Home, Jobs, Matches, Applications:
- **Passive triggers** (initState / tab re-entry) load with `force: false`: paint cache, and if under 5 minutes old, **skip the network entirely** (Home skips all four fetches; Matches skips GET /matches and the auto-rerank).
- **Pull-to-refresh and Retry always hit the network** (`force: true`), through a shared `RefreshThrottle` (3s cooldown) so a rapid triple-pull fires once.
- **Mutations** (bookmark, return from Add-Job) force a reload, bypassing the gate so the change shows immediately.
- `matching_loading_screen` checks `isFresh(keyJobs)` before its `POST /jobs/refresh` — the pool is shared and rate-limited, so a redundant refresh burns a slot for nothing; the per-profile rerank still fires (idempotent).
- A muted **"Updated Xm ago"** line per tab keeps the 5-minute window legible (`lastUpdatedLabel`).

**Verified:** `flutter analyze` clean (only 2 pre-existing `anonKey` deprecation infos), all 12 Flutter tests pass. **Not** verified on-device or against prototype screenshots — no Android SDK here, can't launch the app, so the throttling *logic* is analyzer/unit-verified but the on-screen result is unconfirmed. Consistent with this repo's standing constraint that Flutter UI changes here are code-verified, not device-verified.

---

## ADR-029: The app ships as "FirstRole", not "JobHunt Agent"

**Date:** 2026-07-14 · **Status:** Accepted · **Brick:** 10

**Context.** Brick 10 needed a Play Store identity. The working name "JobHunt
Agent" turned out to be unusable: there is an established incumbent on Play
literally called *"JobHunt — Job Search AI Agent"* (`work.jobhunt`, ~380k
installs, actively updated). Shipping under that name would bury us beneath an
app we cannot outrank and invites a brand-confusion complaint.

The broader ASO reality also forced the choice. Head terms — "job search", "AI
resume" — are owned by Internshala, Unstop, Naukri and Kickresume, all with
millions of installs. Play ranks on install velocity, retention and ratings; a
new app with 12 testers has none of those. The only things a new listing can win
on day one are (a) its own brand name and (b) long-tail keywords.

**Decision.** Ship as **FirstRole**, store title `FirstRole: AI Fresher Jobs`.

- The brand word *means* entry-level, so it reinforces the keyword rather than
  competing with it — and it matches what the pipeline actually returns
  (fresher/intern only, per ADR on the relevance gate).
- We target the winnable long tail ("fresher", "intern") and concede the head
  terms deliberately.
- Checked against Play: no collision. (`Foothold`, `Tailr`, `Hyre`, `Offerly`
  and `Landr` were all rejected as taken — `Foothold` is itself a career app.)

**What did NOT change, on purpose:**

- **Package ID stays `com.jobhuntagent.jobhunt_agent`.** It is permanent once
  uploaded, and it is baked into `google-services.json` (FCM) and the Supabase
  OAuth redirect scheme in `AndroidManifest.xml`. Renaming it would mean a
  different app and a broken sign-in flow, for zero user-visible benefit.
- **Dart package name stays `jobhunt_agent`** — it appears in every
  `import 'package:jobhunt_agent/...'` and is invisible to users.

So "JobHunt" survives as an internal identifier and "FirstRole" is the entire
user-facing surface. That split is intentional, not an oversight.

**Consequence.** Anything user-visible must say FirstRole. Caught during
on-device verification: the welcome screen still rendered "JobHunt Agent" —
fixed in `splash_screen.dart` and `main.dart` (`MaterialApp.title`). The splash
still uses the old *target* glyph rather than the new staircase mark; cosmetic,
tracked in `docs/PLAY_CONSOLE.md` §10.

---

## ADR-030: Release signing, R8, and why the release build is verified on-device

**Date:** 2026-07-14 · **Status:** Accepted · **Brick:** 10

**Context.** The Android release config was untouched Flutter template: it signed
release with the **debug key** (Play rejects this outright), had no keystore, and
no minification.

**Decision.**

1. **Upload key** — RSA-4096, valid to 2053 (Play requires validity past Oct
   2033), at `~/keys/firstrole-upload.jks`, i.e. **outside the repo** so that no
   `git add -A` can ever capture it. Credentials live in gitignored
   `app/android/key.properties`.
2. **key.properties is optional at configure time, mandatory for release.** A
   fresh clone has neither file, so a hard `load()` would break even debug builds.
   Instead the Gradle config treats the key as optional, then fails the build
   loudly via `gradle.taskGraph.whenReady` if a *release* task runs without it.
   The failure mode we are engineering against is a debug-signed AAB silently
   reaching a tester.
3. **R8 on** (`isMinifyEnabled` + `isShrinkResources`). `proguard-rules.pro` is
   deliberately near-empty — Flutter/Firebase/plugins ship consumer rules — with
   one `-dontwarn com.google.android.play.core.**` because the engine references
   deferred-components classes we don't bundle.

**Verified — and this is the point.** R8 is the classic "builds green, crashes on
launch" change, so a successful `flutter build` proves nothing. The release APK
was installed on the `jobhunt_pixel` emulator and launched: process alive, zero
`FATAL EXCEPTION`, zero `ClassNotFoundException`, welcome screen renders, new
launcher icon correct on the home screen. The merged release manifest was also
inspected directly: `targetSdk 36`, `minSdk 24`, and `usesCleartextTraffic`
**absent** — confirming the debug-only cleartext overlay does not leak into
release. The AAB's signer was checked with `jarsigner -verify` and is `CN=FirstRole`,
not the Android debug key.

---

## ADR-031: The OAuth deep-link scheme must not match applicationId (underscores are illegal in a URI scheme)

**Date:** 2026-07-14 · **Status:** Accepted · **Brick:** 10

**Context.** Every Google sign-in failed. After the user picked their account,
the browser landed on a raw `{"code":500,"error_code":"unexpected_failure"}` from
GoTrue and never returned to the app. Supabase's auth log named the cause exactly:

```
parse "com.jobhuntagent.jobhunt_agent://login-callback/":
first path segment in URL cannot contain colon
```

The redirect scheme had been copied from `applicationId`
(`com.jobhuntagent.jobhunt_agent`). But RFC 3986 restricts a URI scheme to
`ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )` — **an underscore is not legal**, and
`jobhunt_agent` has one. Android package names *do* allow underscores, so the two
namespaces look interchangeable and are not.

What made this expensive to find: **Android tolerates the illegal scheme.** The
intent-filter matched, and firing the deep link with `adb` launched the app
perfectly — which is exactly the evidence that made the app side look innocent.
GoTrue is written in Go, and Go's `net/url.Parse` obeys the RFC strictly: it
refuses to read the string as having a scheme, falls back to parsing the whole
thing as a *path*, and errors on the colon. So the client worked, the server
500'd, and the two facts seemed to contradict each other.

**Decision.** The deep-link scheme is now `com.jobhuntagent.firstrole` —
reverse-DNS (a bare `firstrole://` could be hijacked by any other app that claims
it) and free of underscores. `applicationId` is deliberately left alone: it is
permanent on Play and wired into FCM.

So the scheme and the applicationId now differ *on purpose*. Both
`supabase_config.dart` and `AndroidManifest.xml` carry a comment saying so, since
"these don't match, let me fix that" is the obvious wrong instinct.

**Consequence.** Supabase → Authentication → URL Configuration must list the new
scheme; the old one is now unroutable (verified: `am start` on the old scheme
returns `unable to resolve Intent`).

**Verified.** Reproduced the parse failure against the RFC scheme grammar (old
string yields no scheme and is read as a path; new one yields
`scheme=com.jobhuntagent.firstrole host=login-callback`). On-device, the
`app_links` plugin logs `Handled intent: com.jobhuntagent.firstrole://login-callback/`,
so the redirect now routes back into the app.

---

## ADR-032: Duplicate signups fail silently unless you check `identities`

**Date:** 2026-07-14 · **Status:** Accepted · **Brick:** 10

**Context.** An existing user who tapped **Sign up** instead of **Sign in** got no
error and no session — the form simply appeared to do nothing.

Supabase does not raise an error for a duplicate signup when "Confirm email" is
enabled: erroring would leak which email addresses have accounts. Instead it
returns a **decoy user with an empty `identities` list** and no session. Code that
only watches for a thrown `AuthException` therefore sees success.

**Decision.** `_submitPassword` treats `user.identities == []` as "already
registered", shows *"That email already has an account. Sign in instead."* and
flips the form to sign-in with the typed email preserved. The thrown-error path
(what Supabase does when "Confirm email" is OFF) is handled too, so the behaviour
is identical whichever way the project is configured. `_friendlyAuthMessage` also
rewrites `invalid login credentials` to point Google-signup users at the Google
button — the likeliest reason a real user's password "doesn't work".

## ADR-033: Atom-level anti-fabrication guardrail (Track B, R1)

**Date:** 2026-07-23 · **Status:** Accepted · **Track:** B (résumé quality) · **Migration:** 025

**Context.** The Brick-6 guardrail (`fuzz.partial_ratio(original, raw_resume_text)
>= 85`) had a structural blind spot: it only proved the *original* bullet was
real, then trusted the LLM that `tailored` was a faithful rephrase. Nothing
checked the tailored text itself. An inflated metric ("40%" → "60%") or a
relocated achievement ("… at Google") sailed through because the untouched
`original` still traced. Golden Rule 4 says every tailored bullet must trace to
a real source; the old check enforced that for the wrong string.

**Decision.** Decompose the **tailored** bullet into factual **atoms** and trace
each to the profile (structured fields + raw text), not the bullet as a whole:

- **numbers/metrics/dates** — normalized (`40 percent`≡`40%`, commas stripped,
  `500+`→`500`) and must appear in the source's number set. This catches metric
  and scope inflation, the highest-value fabrication.
- **tech** — a token in a curated `TECH_LEXICON` must be one the candidate
  actually has (`_skill_present`: fuzzy vs `skills[]` or whole-word in raw text).
  The lexicon's job is *lowercase* tech ("added kubernetes"); uppercase tech is
  a proper-noun candidate already.
- **proper nouns** — capitalized, non-sentence-initial, non-generic tokens must
  be named somewhere real. Catches invented employers/products ("at Google").
- **prose floats free** — verbs, connectives, framing are never checked.

Atoms may be **dropped** by tailoring, never **added, inflated, or upgraded**.
The check is a pure function (`verify_bullet_atoms` / `build_source_context`);
enforcement is `guardrail_pass` on the stored bullet plus per-atom `flagged_atoms`
surfaced in the diff UI. `verify_skills` (80) and `compute_gaps` are unchanged.

**Bias toward false negatives, never false positives.** The lexicon is
deliberately non-exhaustive and generic capitalized words are suppressed: a miss
is a logged diagnostic, a false positive is a user who stops trusting the
guardrail. Every untraceable atom is written best-effort to `guardrail_atom_log`
(migration 025) — a write failure never blocks tailoring — to tune the lexicon
and seed the R-E golden set.

**Gate.** An in-repo golden-set fixture (`test_guardrail.py::test_golden_set`)
locks the atom rules against regression. The *full* R-E golden set (a corpus of
real resumes/JDs) remains the pre-production validation gate before Track B ships
to users; this ADR is accepted for the branch, validated end-to-end at that gate.

## ADR-034: Section-level tailoring — selection is deterministic Python, not the LLM (Track B, R2)

**Date:** 2026-07-23 · **Status:** Accepted · **Track:** B (résumé quality) · **No migration**

**Context.** Brick-6 tailoring flattened *every* bullet and asked the LLM to
rephrase all of them. A one-page résumé can't hold every bullet, and "which
achievements belong on the résumé for THIS job" is a ranking decision — exactly
the kind of logic Golden Rule 2 keeps out of the LLM. Letting the model silently
choose was also unpredictable: the same profile + JD could yield different résumés.

**Decision.** Tailoring is **selection first, rephrasing second**, and the
selection is deterministic Python (`services/section_tailor.py`):

1. **Score** every bullet vs the JD by keyword overlap — a fraction of the
   bullet's own tokens that appear in the JD. Offline, exact, reproducible.
   (Embedding cosine is an optional blended signal, off by default: on this
   corpus embeddings are squashed into a narrow band — see ADR-021/matching.py —
   so lexical overlap discriminates better. Left as a documented hook.)
2. **Select** deterministically: a per-role bullet cap, a relevance floor, and
   two invariants — **the most-recent role (index 0) is never dropped** (floor
   ignored), and no other role is left a bare header (keep its single best
   bullet). Sort key is `(-relevance, original_index)`, so the choice is
   reproducible, never hash-order-dependent.
3. Only the **survivors** go to the LLM. Each survivor is mapped back to its
   `experience_index` by fuzzy-matching the echoed `original`, run through the
   R1 atom guardrail, and stored with `selected=True`.
4. Every **drop** is disclosed: trimmed bullets are stored with `selected=False`,
   `accepted=False`, and a `trim_reason` — the "Trimmed" list the UI shows. A
   one-tap **restore** is just flipping `accepted=True` (the PDF renderer and
   approve endpoint already resolve inclusion from `accepted`), so no new
   endpoint or column is needed.

Recency is inferred from **résumé order** (index 0 = most-recent), not by parsing
the free-text `duration` — date parsing is brittle and would break determinism.

**Storage.** No migration: selection/trim metadata rides on the existing
`tailored_resumes.bullets` jsonb (`experience_index`, `relevance`, `selected`,
`trim_reason`, `accepted`). The PDF renderer regroups R2 bullets by
`experience_index`, orders by relevance, and omits fully-trimmed roles; rows
without `experience_index` (legacy/bare-list callers) keep the old positional
slotting. The reframed summary line now also passes through the atom guardrail
and falls back to the stored headline if it fabricates.

**Acceptance (met by tests).** Same profile + same JD → identical selection
(`test_selection_is_deterministic`); the most-recent role never drops
(`test_most_recent_role_never_drops`); every drop is disclosed and restorable
(`test_r2_grouped_rendering_omits_trimmed_and_honours_restore`).

---

> **ADR-035 and ADR-036 are reserved** for Track B's post-Phase-10 work — R4
> two-pass generate→critique→revise (035) and R6 one-page ATS layout (036), per
> `docs/20-frontend-rebuild-master-plan.md` §4. Phase 10's decisions take 037+ so
> those numbers stay free for the work that already claimed them.

## ADR-037: Routing is declarative (go_router), redirect logic lives in one notifier

**Decision (Phase 2b).** Replace the imperative `Navigator.push`/`AuthGate`
`setState` navigation with a single `GoRouter` (`router/app_router.dart`). All
auth/onboarding gating is one pure function in `AppRouterNotifier`
(`router/app_router_notifier.dart`), wired as the router's `refreshListenable`:
it's a `ChangeNotifier`, so a sign-in, a completed-profile check, or a sign-out
each `notifyListeners()` and go_router re-runs `redirect` — the app can't get
stuck on a screen that no longer matches auth state.

**Why.** The old AuthGate branched on session state inside `build`, which meant
every new gated screen re-implemented the "am I allowed here" check and back-stack
behaviour drifted per screen. One declarative table + one redirect function makes
the allowed transitions auditable in a single place and deep-links (OAuth
callback, FCM taps) resolve through the same path as in-app navigation.

**Consequences / trade-offs.** `context.go` (replace) vs `context.push` now
matters — `/splash → /auth` uses `go`, which is why hardware-back from Auth exits
to launcher rather than popping to splash (open finding, deemed defensible; a
`PopScope` in `auth_screen.dart` would change it). The debug gallery lives behind
a `kDebugMode`-guarded route with a redirect carve-out.

## ADR-038: App state is Riverpod Notifiers, introduced only where server state is shared

**Decision (Phase 2c/5).** Server-derived, cross-screen state is held in Riverpod
`Notifier`s under `services/` — `match_feed.dart`, `task_center.dart`,
`job_filter.dart`, `career_chat.dart`, `theme_controller.dart` — composed in
`app_container.dart`. Providers are app-scoped and **reset on sign-out** (wired
through the router notifier) so one user's matches/tasks/chat never bleed into the
next session. Local, single-screen state stays `StatefulWidget` — Riverpod was
introduced deliberately from "Brick 5+", not applied uniformly.

**Why.** The Kanban board, match feed, background-task toasts, and the shared
jobs filter are read/written from more than one screen; lifting them into
`setState` owners forced prop-drilling and duplicate fetches. A `Notifier` gives
one owner, one cache, and a single place to invalidate. TaskCenter deliberately
owns the global "task complete" toast; `ChatController` runs its **own** private
poll loop so a chat reply never fires that global toast.

**Consequences.** No LangChain/Redux-style ceremony; the rule is "reach for a
Notifier only when state is genuinely shared." Widget/screen tests that pump a
Notifier-backed screen need a `ProviderScope` ancestor (see `widget_test.dart`).

## ADR-039: The wallet is cosmetic — entitlements gate, money never does

**Decision (Phase 4).** Access is gated by **tier only** (`services/entitlements.py`,
`DEFAULT_TIER`); a `free` tier returns `402` on pro-gated calls. The **wallet**
(`services/wallet.py`, §4.12) is *cosmetic*: its balance is derived live as
`grant − period-spend`, self-resets to the grant on the `subscription_period_end`
rollover, and **never blocks a call**. The per-provider "used this period" bars
split the wallet's own `spend_paise` by `/stats/costs` percentages — no second
copy of the USD→₹ rate, no fabricated transaction ledger. Top-up/Manage explain
the credits via a SnackBar rather than faking a checkout (there is no billing
backend).

**Why.** Conflating "did the user pay" with "is there budget left" produces the
worst failure mode — a paying user locked out by an accounting glitch. Splitting
them means the money view can be honest and approximate (it's informational)
while the gate stays a hard, testable boolean. It also follows the CostStats
precedent: don't invent a budget the backend can't substantiate.

**Consequences.** The wallet is **not** a spend cap — the only real dollar ceiling
is Apify's own $5 limit (Known Issue #2). Wiring the cosmetic wallet to an actual
cap is a documented future item, not shipped here.

## ADR-040: Career chat runs on DeepSeek, grounded and schema-validated

**Decision (Phase 4).** The career-chat assistant (`services/chat.py`, §4.10)
routes through `CHAT_PROVIDER` (DeepSeek by default, thinking disabled per
ADR-023), grounds every reply on the user's profile + top-10 matches + recent
applications, applies a hard anti-fabrication instruction, and returns a
schema-validated `ChatReply`. The endpoint is `POST /chat` → `202 + task`
(polled), pro-gated, and persists threads so history survives restart.

**Why.** Chat is the highest-volume free-text surface, so it belongs on the
cheaper provider (the reason DeepSeek was adopted at all, ADR-023). Grounding +
schema validation keep it from drifting into invented job facts — the same
Golden-Rule-3 discipline as every other LLM call. Async 202+task keeps a slow
model off the request thread.

**Consequences.** Chat needs `DEEPSEEK_API_KEY` + `CHAT_PROVIDER=deepseek` on
Cloud Run and migration 024 applied — until then it returns data-blank, not an
error. Known edge: a retry after a poll-timeout re-POSTs the user turn (server
persists a duplicate) — an accepted failure-path trade-off. Prompt injection
widens here and stays a documented residual (ADR-025).

## ADR-041: One haptic wrapper, four named intensities, user- and OS-respecting

**Decision (Phase 2d).** Every haptic goes through `HapticService.instance`
(`services/haptic_service.dart`) — never a raw `HapticFeedback` call. It exposes
four semantic levels (`selection`/`light`/`medium`/`heavy`) mapped to concrete
moments (tab switch & Kanban drop → selection; hold-start & task-done → light;
hold-complete & error → medium; celebration → heavy, fired once). A persisted
`enabled` flag (via `CacheService`) gates all of them; the celebration/loader
animations already honour the OS reduce-motion setting.

**Why.** Scattered `HapticFeedback.*` calls make the feel inconsistent and
impossible to mute. One wrapper gives a single on/off switch, a semantic
vocabulary the whole app shares, and one place to tune intensity — the same
"one owner" instinct as the theme and toast singletons.

**Consequences.** Haptics are unverified on-device in this environment (no
physical device); the mapping is asserted by the widget tests only insofar as the
widgets build. Real haptic feel is part of the Phase 10 physical-device pass.

## ADR-042: Free-tier iOS sideload for dev testing; push/APNs deferred

**Date:** 2026-07-25 · **Status:** accepted

**Context.** The app has shipped Android-only (ADR-007). We needed to run and
test it on a personal iPhone 16 Pro without paying for the Apple Developer
Program — i.e. a free-Apple-ID sideload (7-day signing, no TestFlight, no App
Store). The two blockers were (1) Google OAuth had no iOS redirect wired — only
Android's `AndroidManifest.xml` intent-filter registered the custom scheme —
and (2) Firebase/push has no iOS app or APNs key, so `firebase_options.dart`
throws `UnsupportedError` off Android.

**Decision.** Client/config-only pass, no backend touched:
- iOS bundle id kept as **`com.jobhuntagent.jobhuntAgent`** (camelCase, the
  Flutter default). It was briefly changed to `com.jobhuntagent.jobhunt_agent`
  to mirror Android's `applicationId`, but that **broke free-team automatic
  signing**: Xcode auto-derives the App ID *name* from the bundle id
  (`XC com jobhuntagent jobhunt_agent`), and Apple's App ID name allows only
  letters/digits/spaces — the underscore is rejected ("The attribute 'name' is
  invalid"), so no provisioning profile is issued. Same underscore rule that
  already forced the OAuth scheme to be `firstrole` (ADR-008), now hit again at
  the App-ID layer. The iOS bundle id does **not** need to match Android's — they
  are independent identities; only Apple needs it unique.
- Registered the OAuth custom-scheme redirect for iOS via `CFBundleURLTypes` in
  `Info.plist`, using scheme **`com.jobhuntagent.firstrole`** — the same scheme
  Android registers and the same one `SupabaseConfig.redirectUrl` emits. This is
  deliberately NOT the bundle id: GoTrue (Go) can't parse an underscore-bearing
  scheme (see ADR-008 lineage / the Dart + manifest comments). No custom
  `AppDelegate`/`SceneDelegate` open-URL override is needed — `supabase_flutter`
  handles the deep link through the standard plugin registration (`app_links`),
  which supports the scene-based `FlutterSceneDelegate` this project uses.
- Push is an explicit, logged early-return on iOS in `push_service.dart`
  (guard on `TargetPlatform.iOS` before `Firebase.initializeApp()`), replacing
  reliance on the try/catch swallowing the `UnsupportedError` — same no-op
  outcome, greppable intent.
- Added a Flutter `ios/Podfile` (none existed) pinned to `platform :ios, '13.0'`
  — the highest minimum among firebase_core/firebase_messaging/supabase_flutter.

**Alternatives considered.** Paying for the Developer Program now — premature
before the app is otherwise iOS-ready, and TestFlight isn't needed just to
test on one's own device. Sign in with Apple — also paid-team-only, and
redundant given email/password + Google OAuth already cover sign-in. Matching
the bundle id into the URL scheme — rejected for the documented underscore/
GoTrue reason.

**Consequences.** Sideloaded builds expire every 7 days (re-run from Xcode /
`flutter run` to renew — a free-tier limit, not a bug). iOS push stays
unbuilt until a paid account provisions a Firebase iOS app + APNs key; the
in-app notifications Settings toggle is left as-is. TestFlight distribution to
the beta group remains blocked on that same paid-account decision. Manual check
the code can't verify: Supabase → Authentication → URL Configuration must list
`com.jobhuntagent.firstrole://login-callback/` as a redirect URL (it already
must for Android — same scheme, so no change if it was added generically).
On-device verification (launch, email + Google sign-in, resume upload, tab nav,
graceful push skip) is pending — this environment has no Mac/Xcode/device.

**On-device bring-up (2026-07-25, first successful iOS launch).** The Phase A
code was correct; getting it *running* surfaced a chain of environment gotchas
worth recording, because every one of them presents as a blank **white screen**
and none is a code bug:
1. **Full Xcode + iOS platform required.** Only Command Line Tools were
   installed; a device build needs Xcode.app plus the on-demand iOS platform
   (`xcodebuild -downloadPlatform iOS`).
2. **Flutter *debug* builds can't run standalone on iOS.** Debug uses a JIT Dart
   VM, and iOS only permits JIT under a debugger — tapping a debug build's icon
   (or a slow LLDB attach when the device's dyld shared cache isn't extracted)
   yields a white screen. **Use `flutter run --release`** (AOT) for on-device
   testing; it launches from the icon at full speed. Set Xcode's Run scheme to
   Release too.
3. **The real culprit: a corrupted app *install* on the device.** The very first
   launch was the broken debug build; every subsequent `flutter run` *updated*
   that same container rather than replacing it, so the white screen persisted
   across a minimal-`main`, zero-plugin, `flutter clean` build. **Deleting the
   app from the phone and reinstalling fresh** fixed it. Bisection proved it was
   not the code, plugins, Flutter version, or device (a stock `flutter create`
   app and a plugin-loaded ref app both rendered fine on the same phone).
4. A device **reboot** un-mounts the developer disk image; it re-mounts only once
   the phone is **unlocked**, else `flutter run` fails with "developer disk image
   could not be mounted."

**Result:** the real app launches and runs on the iPhone 16 Pro via free-team
release sideload. Remaining human checks: Google OAuth round-trip, resume
upload, and the Supabase redirect-URL dashboard entry above.

## ADR-043: The career chat is grounded in the WHOLE résumé, and advice is separated from facts

**Date:** 2026-07-26 · **Status:** accepted

**Problem.** The assistant could not answer "what is my name?", "which is the
best project I've built?", or "what should I build next?" — it replied that it
didn't have the information. That was not a model failure but a *context*
failure compounded by a prompt failure:

1. `build_context_block` only carried headline, target roles and skills. Name,
   experience, projects and education were never in the prompt, so a
   correctly-behaving model told the truth: it had no such data.
2. The system prompt banned answering anything "not in the CONTEXT" without
   distinguishing **facts** from **advice**, so even "suggest a project" read as
   forbidden.

**Decision.** The context now carries the full résumé — name, experience *with
its bullets*, projects with descriptions, education — plus the onboarding facts
(branch, grad year, CGPA, employer, notice period, preferred cities), each
omitted entirely when unset so a blank field never reads as an empty claim.
Slices are capped (`_MAX_EXPERIENCE`/`_MAX_PROJECTS`/…) so a long résumé can't
blow up the prompt. The prompt now states plainly that the CONTEXT *is* the user
being spoken to, and splits the two rules: **facts** must come from the context
(fabrication ban unchanged and still explicit), while **advice** — what to learn,
what to build, how to phrase a bullet — is allowed when reasoned from what's
actually there, and may never be presented as something already done.

**Why not send the raw résumé text?** `raw_resume_text` is on the profile row,
but it's unstructured, unbounded and includes whatever the parser skipped. The
structured fields are already the app's source of truth everywhere else.

**Consequences.** Chat prompts are larger (bounded, but larger) and cost more per
turn. The anti-fabrication acceptance moves from "refuses anything not in
context" to "refuses invented *facts* while still giving grounded advice" —
pinned by `test_prompt_allows_advice_while_still_banning_invented_facts` and the
whole-résumé grounding tests in `tests/test_chat.py`.

## ADR-044: The bottom nav is a docked, edge-to-edge bar — not a floating pill

**Date:** 2026-07-26 · **Status:** accepted · **Supersedes:** design_handoff §7

**Decision.** `AppShell`'s nav is now full-bleed on both platforms: no side
margin, no bottom gap, no corner radius. It sits flush against the screen edges
with a hairline top border, and absorbs the home-indicator / gesture inset as
padding *inside* itself so the background reaches the physical edge while the
icons still clear the indicator. iOS keeps the liquid-glass treatment (blur +
translucency, now `ClipRect` rather than `ClipRRect`); Android stays opaque.

**Why.** The floating pill spent ~32px of horizontal gutter and ~20px of bottom
gap on chrome on every screen, which reads as wasted padding on the phones this
ships to. The chat FAB keeps its inset and still floats above the bar's right
end, so the one genuinely floating affordance is unchanged.

**Consequences.** `kFloatingNavClearance` drops 104 → 96 (the bar no longer
carries outer padding, and the device inset is added at the call site). The name
is now slightly wrong — kept to avoid churning every tab body that imports it.

**REVERSED by ADR-047 (2026-07-26, same day).** The docked bar was rejected on
device: the reclaimed gutter did not read as more content, and the FAB's
reserved band left a strip of dead paper between the last row and the bar.

## ADR-045: Skill growth scores *gap coverage*, not a made-up "skill score"

**Date:** 2026-07-26 · **Status:** accepted

**Decision.** The Skill Growth screen adopts the prototype's dashboard shape —
score ring, level, XP, Skills/Courses/Projects tabs, tick-to-complete cards —
but **not** its numbers. The prototype opens at a hardcoded "560 / 1000 skill
score"; shipping that would be a fabricated reading (Golden Rule 4's spirit).

What ships is *gap coverage*. Every recommendation is worth XP proportional to
`SkillGrowthItem.frequency` — how many of the user's ranked matches actually list
that gap, counted in Python from real match rows (`services/skill_growth.py`).
The score is earned XP over total XP on the table, so "410 of 780" is a literal,
checkable statement. Levels are five bands over that fraction, and the band
labels describe the *coverage* ("Closing gaps"), never the person ("In-demand") —
the agent has no basis for the latter. Per-tab weights (skill ×10, course ×6,
project ×8 per blocking match) encode effort, not evidence.

**Where the ticks live.** Device-local (`SkillProgressStore`, SharedPreferences,
namespaced by user id like `CacheService`) — not a profile column. This is a
personal checklist over the agent's suggestions: no scoring, matching or résumé
output reads it, and item ids are content-derived so a re-rank that replaces a
recommendation orphans its tick instead of attaching it to the wrong row.

**Consequences.** Progress doesn't sync across devices — acceptable for a
checklist, and revisitable as a migration if it ever needs to. The total moves
when the agent re-ranks (new gaps = new XP on the table), which is correct but
means the denominator isn't stable over time.

## ADR-046: The résumé PDF leads with a contact block; form-fill lands in the browser

**Date:** 2026-07-26 · **Status:** accepted · **Migration:** 026

**Contact block.** Compiled résumés carried only the candidate's name, so a
recruiter opening one had no way to reach them — the single most important thing
on the page. Migration 026 adds `email`, `phone`, `location`, `linkedin_url`,
`github_url`, `website_url` to `profiles`, and `resume_pdf.py` renders a centered
name over a contact line of real clickable links, with a hairline rule under each
section heading.

Populated two ways, no new onboarding step: the résumé parser extracts whatever
is printed on the uploaded file (same "extract, never infer" discipline as `usn`
— it may not invent a handle from a name), and the user confirms/corrects it on
the existing review step, or later from Settings → Contact details.

Two rules worth pinning, both tested: URLs are **scheme-gated** to
http/https/mailto/tel before becoming a clickable annotation (these are
hand-typed, so `javascript:` is untrusted input and degrades to inert text), and
clearing a field sends `''` rather than `null`, because the server's PATCH treats
a JSON null as "set to null" — `ResumeProfile.contactJson` omits nulls so the
résumé-review screen can't silently wipe a link it never displayed.

**Form fill.** "Parse & fill" now runs parse → fill → **straight into the in-app
WebView**, instead of stopping at an answer-review sheet. The sheet still exists
underneath and is reachable from the WebView's new ⋮ menu, which also carries the
JD ("tailor my résumé for this JD" when the parse captured one, else "add a job
description") and the résumé PDF the user has to attach by hand. The
learn-from-edits path (PATCH `/forms/fills/{id}` → answer-history reuse) is
unchanged. Non-Google forms still stop at the sheet — they have no prefill URL.

## ADR-047: The bottom nav floats again — and reserves only its own footprint

**Date:** 2026-07-26 · **Status:** accepted · **Reverses:** ADR-044

**Decision.** `AppShell`'s nav goes back to the design handoff's floating pill:
a `surface` capsule, 26px radius, hairline border, soft drop shadow, inset 12px
from the sides, 6px under the content and 14px above the home-indicator inset.
iOS keeps liquid glass (`ClipRRect` + `BackdropFilter`); Android stays opaque.
The active destination rides up 3px in a 38px `accentSoft` puck.

The second half matters more than the capsule: **the content's bottom gutter is
now exactly the pill's footprint** (`kNavPillTopGap + kNavPillHeight +
kNavPillBottomGap` = 88, plus the device inset) and nothing else. The chat FAB
is `Positioned` *above* the pill and floats over the content, exactly as the
prototype does (`top:-58px`), instead of being stacked in a Column that forced
the scroll view to end 40px early.

**The FAB must be a sibling of the pill in the shell's full-screen `Stack`, not
nested inside a pill-sized one.** First cut nested it: `Clip.none` let it paint
above the pill, but Flutter does not hit-test outside a parent's bounds, so the
button rendered perfectly and was completely dead to touch. Caught on device.
Regression test: `signature_widgets_test.dart` taps the FAB by semantics label
and asserts the callback fires.

**Why.** On device the docked bar didn't buy the space it promised, and the FAB's
reserved band showed up as a strip of dead paper between the last list row and
the bar — content looked clipped rather than scrolled. Reserving room for a
*floating* element was the actual bug; the bar shape was incidental.

**Consequences.** `kFloatingNavClearance` is now derived from the three pill
constants rather than hand-tuned (96 → 88 + inset), and the pill owns its height
(`kNavPillHeight`) instead of `AppSpacing.bottomNavH`, which is left in place as
a legacy token. Regression guard: a widget test asserts the gap between the
content's bottom and the pill's top stays under one pill height.

## ADR-048: First-run matching WAITS for the rerank instead of guessing 1.6s

**Date:** 2026-07-26 · **Status:** accepted · **Amends:** ADR-011 (client side)

**Decision.** `MatchingLoadingScreen` runs the real sequence — refresh pool →
rerank (awaited through `TaskCenter`) → `MatchFeed.refresh()` → hand off — and
plays the new `AgentScene` (design handoff `_scene('matching')`: the mascot
pulling tokens in, job cards shuffling, sparks) with a three-segment progress
strip that advances on actual step completion. After 40s a "Continue to home"
button appears; at 6 minutes it hands off automatically. A failure shows the
error plus a "Go to home" escape.

**Why (the real bug).** The old screen fired refresh + rerank
fire-and-forget and handed off after a fixed 1.6s. `_kickOff` then called
`ref.read(taskCenterProvider.notifier)` *after* awaiting `refreshJobs()` — by
which time this `ConsumerState` had been disposed and its `ref` was unusable, so
**the rerank was frequently never started at all**. First-run users landed on
Home's "No matches yet" empty state and only got matches after pressing
"Re-match" on the Matches tab by hand. Notifier handles are now captured in
`initState` before any await, so the flow can't be decapitated by disposal.

**Consequences.** Onboarding's last step is now as long as scoring actually
takes (minutes on a cold 20-job batch) rather than a fixed 1.6s — which is the
honest thing to show, and the escape hatch keeps it non-blocking. Belt and
braces: Home's empty state renders the same scene + "Scoring your matches…"
whenever a rerank or pipeline task is active, so arriving early never looks like
a dead end.

## ADR-049: Agent activity, skill growth and career chat are cache-first too

**Date:** 2026-07-26 · **Status:** accepted · **Extends:** ADR-028

**Decision.** The three remaining always-refetch screens adopt the tab bodies'
pattern: paint the cached payload instantly, skip the network on a *passive*
open while the cache is fresh, force a real refetch on pull-to-refresh, and show
an "Updated 5m ago · pull to refresh" line so the window is visible. Skill growth
gets its own, much longer freshness window (`CacheService.skillGrowthFreshFor`,
12h) because that endpoint is a single ~50s Gemini call whose input only changes
when the agent re-ranks. Career chat caches the thread list plus the open
conversation, so reopening the chat paints instantly instead of spinning.

**Why.** Re-entering any of these three re-ran the full fetch — on skill growth
that meant a minute of loader and a fresh LLM bill for an answer that hadn't
changed.

**Consequences.** Three new cache keys (`skill_growth`, `chat_threads`,
`chat_messages`), all user-namespaced and cleared on sign-out like the rest.
`SkillGrowthItem` and `ChatThread` now keep their raw server JSON so the payload
round-trips.

## ADR-050: Chat history is a first-class list, not just "the last thread"

**Date:** 2026-07-26 · **Status:** accepted · **Extends:** ADR-040

**Decision.** `GET /chat/threads` already returned every conversation; the client
used only `threads.first`. The controller now keeps the whole list, and the
screen surfaces it two ways: a "Recent chats" section under the greeting (up to
four) and a full bottom sheet behind the header's clock button, with
pull-to-refresh and the last-updated line. Tapping a row loads that thread;
"New chat" keeps the list intact instead of hiding the previous conversation.

**Why.** A conversation you can't get back to is a conversation you re-explain
from scratch — and the data to avoid that was already on the wire.

**Consequences.** No server change (`updated_at` and `title` were already in the
rows). `ChatState` gains `threads`/`threadsUpdatedAt`; a `_startingNewChat` flag
stops a background refresh from reopening the newest thread underneath a user
who deliberately started a blank one.

## ADR-051: Nothing on the path to first paint may wait on the network without a visible, escapable state

**Date:** 2026-07-26 · **Status:** accepted

**Symptom.** Leave the app for a long time, come back, and iOS shows a white
blank screen. Android "looked fine" — which was the clue.

**Decision.** Four changes, all on the cold-start / resume path:

1. **The iOS launch screen is brand-filled** (`#5647E0`), matching
   `android/.../launch_background.xml`. It was `red=1 green=1 blue=1` — pure
   white — so *any* delay before Flutter's first frame is, on iOS, literally a
   white blank screen. Android's was already branded, which is why the same
   delay never looked broken there.
2. **The routing profile call is bounded** (`_routingCallBudget`, 12s).
   `GET /resume/profile` was the one call in `ApiClient` with no timeout at all,
   and it gates `/loading` → `/home`. Cloud Run scale-to-zero plus a just-woken
   radio is exactly the "after a long idle" case, and the app sat there for as
   long as the socket did.
3. **Session recovery no longer wipes the routing answer.** `supabase_flutter`
   restores the session *after* `Supabase.initialize` returns, so the first
   check could run with no user — no cache namespace, no auth header — and the
   `signedIn` event that followed cleared `_profile`/`_profileChecked` and sent
   the app back to `/loading`. Now a same-user event keeps the answer, and
   `initialSession`/`tokenRefreshed` re-check only when nothing was resolved.
4. **`/loading` is a real screen** (`StartupLoadingScreen`): brand mark,
   "Getting things ready…", and after 8s an honest "still working" plus
   **Try again** / **Sign in again**. It was a bare `AppLoader` on `paper`
   (#FAFAF9) — to a user, a white screen. `errorBuilder` uses it too.

Plus `AppLifecycleListener.onResume` → `AppRouterNotifier.refreshOnResume()`,
which fills in a decision that was made without the network. It deliberately
never clears state first: **a resume must not be able to demote a working app
to a loading screen.**

**Why this shape.** The bug was not one hang, it was that a hang was invisible
and unrecoverable. Timeouts alone would still leave a blank screen for 12s;
a nicer spinner alone would still hang forever. Bound the wait, make it
visible, and give it an exit.

**Verified.** Android emulator with wifi *and* data disabled: cold start lands
on Home from cache in ~15s (screenshot in the session), where the old build's
untimed call would hold `/loading`. `startup_loading_test.dart` pins both the
first-frame copy and the 8-second escape hatch.

**Consequences.** `ResumeProfile` routing may be answered from cache alone;
`_confirmedByNetwork` tracks that so the next resume re-confirms it. The iOS
`LaunchScreen.storyboard` change needs a real iOS build to be seen — it is not
exercised by the Android emulator verification above.

## ADR-052: `/jobs/refresh` finishes migrating to ADR-011's 202+poll pattern; direct-401 forms now hit the sign-in fallback too

**Date:** 2026-08-01 · **Status:** accepted

**Symptom.** Two more `ClientException: Software caused connection abort`
reports, on `POST /jobs/refresh` this time (`/tailor/{job_id}` was already
fixed). Separately, autofilling a specific Google Form threw a raw
`Client error '401 Unauthorized'` instead of the "open it in your browser"
fallback ADR-013 built for sign-in-gated forms.

**Root cause, part 1.** ADR-011 (migration 009) moved `/matches/rerank`,
`/pipeline/run-mine`, and `/tailor/{job_id}` off the request/response cycle
for exactly this reason, but `/jobs/refresh` was missed — it still `await`ed
the full four-source fetch/dedup/embed pipeline inline. Fanning out to
Adzuna/JSearch/Greenhouse/Lever routinely runs past a minute, long enough
for Android's network stack to drop the idle socket before Cloud Run (300s
default timeout) would ever time it out itself.

**Root cause, part 2.** `fetch_form_html` (`services/form_parser.py`) only
recognized a sign-in-gated form via a redirect to `accounts.google.com` —
checked after the fetch loop finished. Some forms answer with a direct
401/403 instead of a redirect; `raise_for_status()` fires first and the
generic `except httpx.HTTPError` handler let the raw message straight
through to the UI, bypassing `FormAuthRequiredError` entirely.

**Decision.**
1. `POST /jobs/refresh` now returns `202 {task_id}` immediately and runs
   `refresh_job_pool()` via the same `create_task`/`run_task` helper as
   `/tailor` — no new machinery, just the missing call site. Requires
   `get_current_profile` (was `get_current_user_id`) since
   `background_tasks.profile_id` is `not null`; safe because every route
   that reaches this screen is already gated behind onboarding
   (`app_router.dart` redirects to `/onboarding` without a profile).
2. Client: `ApiClient.refreshJobs()` returns the task id instead of the
   result map; both call sites (`JobsListBody._refresh` — pull-to-refresh,
   and `MatchingLoadingScreen._run`'s sourcing step) now start it through
   `TaskCenter` (new `TaskKind.jobsRefresh`) and poll instead of holding one
   `await` on the HTTP call. `MatchingLoadingScreen`'s wait is capped at 90s
   and still swallows failure — sourcing was always best-effort there,
   scoring works against the existing pool either way.
3. `fetch_form_html` catches `httpx.HTTPStatusError` ahead of the generic
   `httpx.HTTPError` handler and maps a 401/403 response to
   `FormAuthRequiredError`, same as the redirect case — one reality
   ("you need to sign in"), now detected two ways instead of one.

**Why not also bound `/jobs/refresh` differently (e.g. shrink it, cache
harder).** The fix other long endpoints already used was sitting right
there; inventing a second pattern for one endpoint would just be more
surface to keep consistent later.

## ADR-053: Sign-in-gated forms now autofill in-app too — via a WebView read, never DOM injection

**Date:** 2026-08-01 · **Status:** accepted

**Context.** ADR-046/§4.8 already gave public Google Forms a real "read the
fields, autofill live" experience: `/forms/parse` deterministically parses
Google's own `FB_PUBLIC_LOAD_DATA_` JSON, the profile gets mapped onto the
answers, and the app opens an in-app `WebViewScreen` already pre-filled via
Google's own `usp=pp_url` prefill mechanism — the user reviews, attaches
their résumé, and taps Submit themselves. `form_webview_screen.dart` has a
deliberate, documented hard rule behind that: **no DOM injection** — fields
are only ever populated via the published prefill URL, never by writing
values into the rendered page, because Google Forms' DOM is a minified React
app with no stable selectors and breaks on every reskin.

That whole pipeline requires the SERVER to fetch the form, which fails
outright for a sign-in-gated form (no Google session server-side) — the app
fell back to dumping the raw URL into the EXTERNAL browser with zero fields
read and zero autofill, a materially worse experience than the public path.

**Decision.** Close the gap one hop later, reusing the existing pipeline and
the existing hard rule intact:

1. `FormFillScreen`'s `form_auth_required` banner now leads with **"Sign in
   & autofill"**, which opens the SAME in-app `FormWebViewScreen` — just
   pointed at the plain form URL (`FormWebViewArgs.signInUrl`) instead of an
   already-built prefill URL. "Open in your browser instead" stays as a
   secondary escape hatch, same posture as the WebView's own overflow-menu
   fallback.
2. The user signs into their own Google account inside that WebView —
   Google's native UI, we never see the credentials, identical guarantee to
   the browser fallback it replaces.
3. Once the WebView lands somewhere that isn't `accounts.google.com`/
   `ServiceLogin` (`FormWebViewScreen._maybeAutofillAfterSignIn`), it does a
   **one-time READ** of that page — `document.documentElement.outerHTML` via
   `runJavaScriptReturningResult`. This is the one JS call the screen ever
   runs, and it only ever reads; nothing is written into the page, filled, or
   submitted. New `POST /forms/parse-html` (`ParseFormHtmlRequest`) takes that
   HTML and runs the EXACT SAME `_parse_schema_from_html` helper `/forms/parse`
   uses (extracted from `/parse` in this same change — zero new parsing
   logic, so the two paths cannot silently drift apart).
4. The resulting schema goes through the existing `/forms/fill` unmodified,
   and the WebView navigates ITSELF to the resulting prefill URL — the same
   `usp=pp_url` mechanism, arriving at the identical "already filled, review
   and submit" state the public-form path reaches directly. Still no DOM
   injection anywhere in the fill step.
5. A `FormAutofillHandoff` (parsed form + answers + prefill URL + fill id) is
   carried back to `FormFillScreen` via a typed `context.push` result when
   the user taps "Review & edit answers" — the underlying answer sheet ends
   up in the same state the public-form path gives it directly, instead of
   staying empty for a form that needed sign-in.

**Why not scrape the DOM and inject values directly ("truly live" autofill
with no page reload).** That was the first shape considered and rejected —
it reverses the documented no-DOM-injection rule for exactly the reason that
rule exists: Google's rendered markup has no stable hooks, and simulating a
checkbox/dropdown click reliably across their reskins is genuinely fragile.
Reading the page once to recover the SAME embedded JSON the public path
already trusts is stable (the parser comment notes it's "stable for years")
and reuses 100% of the existing mapping/prefill code instead of inventing a
second, riskier fill mechanism for one code path.

**Security note.** `/forms/parse-html` takes client-supplied HTML rather than
fetching a URL itself, so ADR-024's SSRF gate doesn't apply here — there is no
outbound fetch to gate. `form_url` is only ever used as the parsed schema's
`form_url` (for building the prefill URL) and is still capped (`MAX_URL_LEN`);
`html` is capped at `MAX_FORM_HTML_LEN` (3M chars) so a malformed or hostile
payload can't turn into an unbounded parse.

**Bug fix, same day.** First real-device test (a sign-in-gated form pasted as
a `forms.gle` short link) claimed "prefilled 8 fields" but every field on
screen was empty. Root cause: `forms.gle`'s redirect is a static,
pre-registered mapping that DROPS any query string appended to the short
link — confirmed live (`curl -I "forms.gle/xxx?entry.1=y"` redirects to the
long URL with the entry param gone, `usp` silently rewritten to
`send_form`). Both `parse_form` and the new sign-in flow were building the
prefill URL against the ORIGINAL possibly-short URL instead of the resolved
one. Fix: `fetch_form_html` now returns `(html, final_url)` instead of just
`html`, and `parse_form` uses `final_url` for everything downstream; the
client's `_maybeAutofillAfterSignIn` uses the WebView's actual current `url`
(already past any short-link redirect) instead of `widget.signInUrl`. The
canonical `docs.google.com/forms/d/e/.../viewform` URL does NOT drop query
params, even through its own sign-in redirect (verified live: `continue=`
carries the full encoded query string back after login) — so building on
the resolved URL fixes both the new gated-form path and the pre-existing
public-form path whenever a user pastes a short link, which nothing had
exercised before now.

## ADR-054: Location/salary preference boost, and matching stops promising resumes it can't build

**Date:** 2026-08-02 · **Status:** accepted

**Context.** Two gaps reported from real use of the Matches board:

1. `profiles.target_locations` and `profiles.min_salary` were captured at
   onboarding and used to steer job **ingestion** (`services/job_sources.py`)
   and career chat, but never read by `services/matching.py`. The re-ranker
   scored purely on resume/role fit — a candidate's stated city and salary
   floor had zero effect on which jobs scored highest.
2. A fresher with real project work but no formal `experience` entries could
   score a genuine 100 "apply" (the LLM's fit_score was honest — the profile
   really was a strong fit), then hit a hard 422 the moment they tried to
   generate a resume: `services/section_tailor.py`'s SELECTION step only
   ever looked at `profile.experience[].bullets`, and a profile with none had
   nothing to select. The failure toast offered "Retry," which was
   guaranteed to fail again identically — nothing about retrying changes
   what's in the profile.

**Decision — location/salary become a boost, not a filter.** Same shape and
same reasoning as ADR-021's role-intent boost: both are STRUCTURED facts (a
city name, a number), so they're compared in Python, never sent to the LLM
(Golden Rule 2), and they only ever ADD to the score, never subtract or
exclude. A hard filter was considered and rejected: job `location` text is
inconsistent across sources ("Hyderabad, Telangana" vs "Hyderabad" vs blank)
and most postings in this pool list no salary at all, so excluding on either
would silently wipe out otherwise-strong matches — the same failure mode
ADR-021's prescreen safety valve already exists to avoid on the role side.
`LOCATION_BONUS_POINTS = 10`, `SALARY_BONUS_POINTS = 10` (vs role's 15 —
role is what the candidate explicitly said they want; these are secondary).
Remote always satisfies any location preference. A job within 15% of the
salary floor gets a half boost.

**Decision — split the stored score so a preference change doesn't need a
re-rank.** Migration 030 adds `matches.raw_fit_score` and
`matches.role_alignment`, alongside the existing (already-boosted)
`matches.fit_score`. `rescore_cached_matches()` recomputes
`fit_score`/`verdict` for every cached match of a profile from the CURRENT
location/salary preferences — pure Python arithmetic over already-cached
values, no LLM call. `PATCH /resume/profile/target-locations` and `PATCH
/resume/profile/target-roles` (which also carries `min_salary`) now call it
synchronously, so the Matches board reorders the moment a preference is
saved. This does NOT extend to `target_roles` changes themselves:
`role_alignment` was the LLM's judgment of "is this posting the role they
asked for" against whatever roles were current at score time, and
re-judging that for a new role list is a language call — still needs a real
`rerank_shortlist()` run.

**Decision — a bare "apply" must mean tailoring can actually happen.**
`services/matching.py::_has_tailorable_content()` checks, in Python, whether
the profile has at least one experience bullet or one project with a
description. When it doesn't, a computed "apply" verdict is downgraded to
"stretch" and a fixed, de-duplicable message is appended to `matches.gaps`
explaining why. The LLM's fit_score is left untouched — it isn't wrong, the
board's promise was.

**Decision — tailoring itself now uses projects when there's no formal
experience**, rather than only softening the failure message.
`routers/tailor.py::tailor_and_store` only 422s (`PROFILE_INCOMPLETE:` — a
stable prefix, see below) when the profile has **neither** experience
bullets **nor** projects. Otherwise `services/llm.py::tailor_resume` now
also receives `projects`, and `TAILOR_SYSTEM_PROMPT` explicitly allows
grounding `summary_line` in them ("final-year CS student who built X using
Y" is a legitimate, traceable summary). `tailored_bullets` stays empty in
this case — projects are never turned into fabricated experience bullets;
they already render verbatim in the résumé's own PROJECTS section
(`services/resume_pdf.py`, unchanged). `ResumeDiffScreen` shows a "Built
from your projects" banner instead of the (wrong, in this case) "All
bullets verified" one when `bullets` is empty.

**Decision — Retry stops lying.** `PROFILE_INCOMPLETE:` is a stable prefix
the client (`task_center.dart`) pattern-matches on to swap the failure
toast's action from "Retry" (guaranteed to 422 again) to "Add resume",
pushing straight to `/resume-upload` — there is no structured
experience/projects editor yet, so a resume re-parse is the only way to add
either.

**Also:** `GET /jobs/role-suggestions` (new) backs the target-roles
suggestion chips with roles the live job pool actually has postings for
(`tech_category`, migration 028, busiest first), followed by a small curated
list for roles the pool doesn't specifically label. Replaces a 3-item
hardcoded list in `target_roles_screen.dart`.

## ADR-055: Posting-legitimacy signal (career-ops integration, Brick 1)

**Context.** `docs/21-career-ops-integration-plan.md` scoped six features
inspired by the career-ops OSS project; the plan's suggested build order
starts with the one that's pure Python, gates nothing, and validates the
"additive, non-breaking" claim before anything generative ships. Career-ops's
own version (Block G in its `oferta.md` evaluation mode) leans on live
WebSearch and an LLM judgment call. This app has neither a search
integration nor a reason to spend an LLM call on every ingested row (Golden
Rule 2), so the signal set is deliberately narrower and entirely
deterministic.

**Decision — signals computed from data already on the row, no LLM, no new
external calls.** `services/job_legitimacy.py::score_posting()` is a pure
function over `description`, `salary_min`/`max`, `posted_at`, `redirect_url`
and `source` — every one of those already exists on `jobs` before this
migration. Three tiers (`high_confidence` / `proceed_with_caution` /
`suspicious`), same vocabulary and same "observations, not accusations"
framing career-ops uses. A small point system (description length,
freshness, salary presence, application-link presence) sets the tier for
the ambiguous middle; a distinct, India-pool-specific spam-phrase regex
("earn ₹X per day", "pay a registration fee", "WhatsApp only" — patterns
that actually recur in this Unstop/Internshala-heavy pool, not career-ops's
own Glassdoor/Blind-oriented signals) overrides the point system outright
when matched, the same way career-ops treats "multiple ghost-job
indicators" as decisive. Missing salary is explicitly NEVER penalized —
ADR-054 already established that most of this pool carries no salary at
all, so treating absence as concerning would flag the honest majority.
Unknown posted-date is neutral, not concerning, for the same "never default
to Suspicious without evidence" reason career-ops states for its own
liveness gate.

**Decision — employment-classification language is a separate, orthogonal
note, not a tier input.** Mirrors career-ops's own posture: a contractor/
services-status phrase ("1099", "invoice for services", "labour contract")
is reported alongside the tier, never used to demote a posting that's
otherwise clean — it's information for the candidate to weigh, not evidence
of a fake listing.

**Decision — computed inline during ingestion, not as a separate pass.**
`_dedup_embed_insert()`'s existing per-row loop already computes
`work_type`/`category` from fields already on `payload`; `legitimacy_tier`/
`legitimacy_signals` join that same loop rather than becoming a second
batched step like `tech_category` (which genuinely needs batching because it
sometimes calls an LLM). `insert_manual_job()` computes it too, so a
user-pasted job gets a badge like every discovered one.
`backfill_job_legitimacy()` (mirrors `backfill_tech_categories`/
`backfill_job_embeddings`) catches rows ingested before migration 031.

**Decision — surfaced as a badge only when there's something to flag.**
The client (`StatusPill`'s new `PillContext.legitimacy`) renders nothing for
`high_confidence` and a pill for `proceed_with_caution`/`suspicious` only —
badging every card green would be noise; the point of this feature is
directing attention to the minority worth a second look. No new filter
chip, no new screen — reuses `job_card.dart`/`match_card.dart`'s existing
meta row, per the plan's "one brick at a time" build order.

**Consequences:** two new nullable `jobs` columns (migration 031), no
existing column's meaning changes, `GET /jobs`/`GET /matches` pick the new
fields up automatically (`select("*")`), no new rate-limit surface (no new
user-triggered endpoint besides the ops-only `/jobs/backfill-legitimacy`,
same shape as `/jobs/backfill-embeddings`), zero LLM cost. Revisit the point
weights once real usage surfaces false positives/negatives — the diagnostic
`legitimacy_signals` column exists specifically so that retuning has
evidence to work from, same role `guardrail_atom_log` (025) plays for the
résumé guardrail.

## ADR-056: Cover letter generation (career-ops integration, Brick 2)

**Context.** `docs/21-career-ops-integration-plan.md` §1.1 scoped this as
the highest-reuse item on the six-feature list: the tailor → guardrail →
human-approval → PDF chain Brick 6 already built needed a new prompt and a
new one-page template, not new architecture. career-ops's own version
(`modes/oferta.md`'s cover-letter block) generates a draft from CV bullets
+ JD and refines it interactively; this app's version is non-interactive
(matches the existing tailoring UX) but keeps the same anti-fabrication
posture.

**Decision — a separate `cover_letters` table (migration 032), not a column
on `tailored_resumes`.** A cover letter and a tailored résumé have
independent lifecycles: a user may regenerate one without touching the
other, or have one without the other. Same ownership/RLS shape as
`tailored_resumes` (mirrors migration 001/004's pattern exactly).

**Decision — no bullet-selection step.** Brick 6's tailoring pipeline runs
`services/section_tailor.py`'s scoring/selection machinery because a résumé
has to fit every survivor bullet onto one page. A cover letter is 3-5
sentences referencing 2-3 achievements the LLM itself picks as most
JD-relevant — there's nothing to select or trim. `services/llm.py::
generate_cover_letter` hands the LLM every bullet and project directly, and
`COVER_LETTER_SYSTEM_PROMPT` asks for exactly `opening` + 1-3
`body_paragraphs` + `closing`, mirroring `TAILOR_SYSTEM_PROMPT`'s
anti-fabrication rules line for line.

**Decision — reuse the atom-level guardrail on prose directly, no new
guardrail code.** `services/guardrail.py::verify_bullet_atoms` is already
generic over any string of tailored text checked against a
`SourceContext` — `routers/tailor.py` already calls it on `summary_line`
(prose, not a bullet) for exactly this reason. `routers/cover_letters.py`
calls it once per paragraph (opening, each body paragraph, closing) with
zero changes to guardrail.py. Same diagnostic logging to
`guardrail_atom_log` (025) as the résumé flow, via a near-identical
`_log_untraceable_atoms` helper (kept as a small duplicate, not extracted,
since the two call sites' surrounding context — bullets vs. paragraphs —
differs enough that a shared helper would need its own parameter for what
it's logging).

**Decision — a rejected/flagged paragraph is DROPPED from the compiled PDF,
not swapped for alternate text.** This is the one place cover letters
diverge from the résumé pattern: `resume_pdf.py`'s `_accepted()` picks
between the TAILORED and the ORIGINAL bullet text, because a résumé bullet
always has a real, already-approved fallback. A cover letter paragraph has
no such fallback — it's new prose about one achievement, not a rephrase of
something that already exists elsewhere on the page. So
`cover_letter_pdf.py`'s identically-named `_accepted()` gates INCLUSION,
not text choice: an excluded paragraph is simply absent from the letter.
Same "missing `accepted` falls back to `guardrail_pass`" default as the
résumé flow.

**Decision — Gemini by default, not DeepSeek, for the same reason as
`tailor`.** Added to `_TASK_PROVIDERS` directly (`"cover_letter": GEMINI`)
rather than its own settings knob like `tailor_provider` — this is new
enough that A/B-ing guardrail-pass rates between providers isn't a live
question yet; revisit only if it becomes one.

**Decision — one screen, not three.** `ResumeDiffScreen` →
`ResumePreviewScreen` is a two-screen flow because compiling a résumé PDF is
a distinct step from reviewing the diff. A cover letter's PDF is directly
the approved paragraphs, so `CoverLetterScreen` combines generate → review →
approve → share into one screen, reusing `TaskCenter`'s existing 202-poll
pattern (`TaskKind.coverLetter`, new) and `share_plus`'s share-sheet flow
(already a dependency, used identically by `ResumePreviewScreen`).

**Consequences:** one new table (032), one new router
(`routers/cover_letters.py`, registered in `main.py`), one new rate-limit
key (`rate_limit_cover_letter`, same default as `rate_limit_tailor`), one
new cost-dashboard task label ("Cover letters"), one new Flutter screen
reachable from Match Detail as a secondary action alongside "Tailor résumé
for this JD" — independent actions, since a user may want either without
the other. No existing table, endpoint, or screen changes meaning.

## ADR-057: Application/referral/cold email drafts (career-ops integration, Brick 3)

**Context.** `docs/21-career-ops-integration-plan.md` §1.6 — the last of the
three "generate grounded outbound text" bricks (tailoring, cover letters,
now first-contact emails). career-ops has no direct equivalent (it's a
local CLI with no send capability at all); this brick is native, modeled on
this app's own existing `applications.followup_*` columns and
`routers/applications.py`'s follow-up drafting endpoint — the closest
prior art in this codebase for "one short grounded email, human approves,
then sends via Resend."

**Decision — a new `application_emails` table (migration 033), not more
columns on `applications`.** Follow-up drafts overwrite `applications.
followup_subject`/`followup_body` in place because there's only ever one
live follow-up nudge at a time. First-contact emails are different: a
candidate reasonably wants an application-ask draft, a referral-ask draft
for a specific contact, and a cold-outreach draft for a different contact,
side by side — and may want to keep old drafts as history after sending.
So every draft is its own row (`application_id`, `kind`, `subject`, `body`,
`guardrail_pass`, `flagged_atoms`, `sent_at`), not an overwrite-in-place
pair of columns.

**Decision — `kind` is a closed enum (`application` | `referral` | `cold`),
chosen by the user before drafting, not inferred by the LLM.** Golden Rule
2: which tone to use is a decision, not a language task, so it's a request
parameter (`DraftApplicationEmailRequest.kind`) the Flutter kind-selector
sets, and `APPLICATION_EMAIL_SYSTEM_PROMPT` branches its instructions on it
server-side. The LLM only ever writes the one tone it's told to.

**Decision — synchronous, not 202-plus-poll.** A ~150-word single Gemini
call is the same shape as `draft_followup` (which has never needed
`TaskCenter`), not tailoring or cover letters' multi-paragraph background
job. `POST /application-emails/{application_id}` returns the finished row
directly.

**Decision — sync core + thin async route handler, matching
`tailor_and_store`/`generate_and_store_cover_letter`.**
`draft_and_store_application_email(profile, application_id, kind) -> dict`
holds all the logic (ownership check, profile-completeness check, LLM call,
guardrail, insert) as a plain function with no event loop dependency; the
`@router.post` handler is three lines that unwrap `body.kind` and re-wrap
the result in the `{"data": ..., "error": null}` envelope. Keeps every
router in this codebase directly unit-testable the same way.

**Decision — reuse `verify_bullet_atoms` on the whole email body as one
block, not per-paragraph like cover letters.** A first-contact email is a
single short paragraph, not several — cover letters check paragraph by
paragraph because each one stands alone in the compiled PDF; here there's
only one block of prose to verify, same `guardrail_atom_log` diagnostic
logging as both other flows.

**Decision — Gemini by default, same reasoning as `tailor`/`cover_letter`.**
Added to `_TASK_PROVIDERS` directly (`"application_email": GEMINI`).

**Decision — sending reuses `services/email.py`'s Resend integration via a
new `send_application_email` function, not a shared `send_followup_email`
call.** Both delegate to the same private `_send()` helper now (refactored
out of what was a single follow-up-only function) so the two flows share
one Resend call path and one error-handling block, but keep separate named
entry points so logs and error messages stay honest about which flow
triggered a send. Same "Approve & send" human-gate posture as follow-up
(Golden Rule: no auto-submitting anywhere) — requires `applications.
contact_email` to already be set.

**Consequences:** one new table (033), one new router
(`routers/application_emails.py`, registered in `main.py`), one new
rate-limit key (`rate_limit_application_email`, same default as the other
two generation endpoints), one new cost-dashboard task label ("Application
emails"), a new "Application emails" section on `AppDetailScreen` — a kind
selector, a drafts list, and a per-draft send action — sitting below the
existing follow-up card, since the two are independent tools for different
moments in the pipeline (first contact vs. chasing silence). No existing
table, endpoint, or screen changes meaning.

## ADR-058: Interview-prep v1 + story bank (career-ops integration, Brick 4)

**Context.** `docs/21-career-ops-integration-plan.md` §1.2. career-ops's own
interview-prep mode depends on live web search (Glassdoor, levels.fyi,
Blind) for company-specific research; this app has no search integration
today. Rather than skip the feature or fake the research, v1 ships the
search-free half honestly: questions and STAR answers grounded ONLY in the
JD text plus the match's already-computed `gaps`/`strengths`
(`services/matching.py`) — zero new data dependency — with anything not
literally traceable to the JD labeled `inferred=true`, mirroring career-ops's
own `[inferred from JD]` tagging for ungrounded content. A v2 with real
company research is explicitly out of scope until a licensed search API is
chosen (plan §3).

**Decision — a pack is generated fresh every time and never stored; a saved
story is the only thing that persists (migration 034).** These are two
different things with two different lifecycles. An interview pack is
disposable — one Gemini/DeepSeek-cheap call, cheap enough to just re-run,
and nothing about "5 questions for this JD" is worth a table row and a
migration. A story the user chooses to keep is different: it's a real,
reusable answer that should survive across every future interview, not just
this one job. So `POST /interview-prep/{application_id}` writes nothing;
`interview_stories` is the only new table, and "Save as story"
(`InterviewPrepScreen`) is the one explicit bridge between the two.

**Decision — keyed on `application_id`, not `job_id`.** Unlike cover
letters/tailoring (which run before any application exists), an interview
pack needs the match's cached `gaps`/`strengths` for the specific job AND
makes the most sense once a candidate is actually in the pipeline for that
job — so this follows application-email/follow-up's precedent, not
tailor/cover-letter's. A manually-added job with no cached `matches` row
(Add Job, JD-paste) still works — gaps/strengths just come back empty and
the prompt runs on the JD text and profile alone.

**Decision — reuse `verify_bullet_atoms`, but per STAR FIELD, not on the
joined block.** First attempt joined situation+task+action+result into one
string and ran the atom check once; this produced false positives, because
`verify_bullet_atoms`'s proper-noun pass deliberately skips a sentence's
first word (ordinary capitalization, not a fabrication signal) — joining
four independent sentences made three of those first words look
mid-sentence and wrongly flaggable. Fixed by checking each field
separately and pooling the flags onto the one question. A real lesson for
any future caller: this guardrail assumes its input is ONE sentence/block,
not several concatenated ones.

**Decision — `reflection` is never LLM-generated.** Nothing in this app can
know how a real interview actually went, so `interview_stories.reflection`
is nullable and only ever written by the user's own hand, after the fact.

**Consequences:** two new tables — well, one (034; the pack itself is
stateless) — one new router (`routers/interview_prep.py`, two feature
families in one file: the disposable pack endpoint and the story-bank
CRUD), one new rate-limit key (`rate_limit_interview_prep`; the CRUD gets
none, same as other plain-DB-write endpoints), two new cost-dashboard task
labels ("Interview prep"; DeepSeek per the plan's own cost table), two new
Flutter screens (`InterviewPrepScreen`, `StoryBankScreen`) reachable from
`AppDetailScreen`'s new "Prepare" section and from Profile. No existing
table, endpoint, or screen changes meaning.

## ADR-059: Offer-prep contract reader (career-ops integration, Brick 5)

**Context.** `docs/21-career-ops-integration-plan.md` §1.3. Pairs with the
Kanban's existing `offer` state (migration 001), which has tracked that
pipeline stage since Brick 7 with no feature actually behind it. Hard
guards copied directly from career-ops's own offer-prep mode because
they're correct for this domain: never output a verdict ("safe to sign" /
a risk score), never state what the law requires from memory, no web
research — contract text and comp figures never leave the model call as a
search query.

**Decision — the hard guards are structural, not just prompted.** The
no-verdict guard lives in two places: `OFFER_REVIEW_SYSTEM_PROMPT` asks for
it, AND `models/offer_review.py::OfferReviewLlmResponse` has no
verdict/score field for the model to fill in even if a future prompt edit
slipped and asked for one. This is the same posture as `guardrail.py`'s
enforcement-vs-prompt distinction elsewhere in this app (Golden Rule 4): a
prompt instruction is a request, a schema with nowhere to put the thing is
closer to a guarantee. The jurisdiction guard stays prompt-only by
necessity — there's no deterministic way to verify a model didn't state law
from memory — so `questions_for_lawyer` is the honest escape valve, and
`test_offer_reviews_router.py::test_schema_has_no_verdict_field` pins the
schema shape so a future change can't silently reintroduce a verdict field.

**Decision — a new deterministic check, `services/offer_review.py::
verify_clause_grounding`, not a reuse of `guardrail.py`.** Every other
generative brick's guardrail proves a claim about the CANDIDATE traces to
their real profile. Offer review generates no claims about the candidate at
all — it's reading a document handed to it — so the equivalent enforcement
is different in shape: does the model's quoted `clause_text` actually
appear (whitespace/case-normalized) in the source document, or did it
paraphrase/invent one? `OFFER_REVIEW_SYSTEM_PROMPT` explicitly instructs
verbatim quoting so this check is meaningful, not prompt noise to be
tolerated away. A new small module rather than a `guardrail.py` addition,
since the two checks verify fundamentally different things (candidate-fact
grounding vs. document-quote grounding) and have no shared code between
them.

**Decision — insert-only (`offer_reviews`), not one row per application.**
A candidate may paste a revised offer after negotiating; each read is kept
as history rather than overwritten, same posture as `application_emails`
(ADR-057) and unlike `applications.followup_*`'s single-slot columns.

**Decision — Gemini, not DeepSeek.** Unlike `interview_prep`, this isn't a
cost-sensitive high-frequency task (the plan estimates a handful of calls
per user, ever) and it's a harder structured-extraction task over a full
contract — worth the higher-quality tier the same way `parse` is, even
though offer review has no fabrication-guardrail dependency in the
`tailor`/`cover_letter` sense.

**Consequences:** one new table (035), one new router
(`routers/offer_reviews.py`), one new service module
(`services/offer_review.py`), one new rate-limit key
(`rate_limit_offer_review`), one new cost-dashboard task label ("Offer
review"), one new Flutter screen (`OfferReviewScreen`) reachable from
`AppDetailScreen`'s "Prepare" section — paste text, read the clauses, see
questions for a lawyer, done. No existing table, endpoint, or screen
changes meaning.

## ADR-060: Contact discovery v1 (career-ops integration, Brick 6)

**Context.** `docs/21-career-ops-integration-plan.md` §1.4. career-ops's
full version finds NAMED people (hiring manager, recruiter, peer) and
drafts short outreach messages per contact — real value-add, but real-people
lookup needs the same licensed search API integration that interview-prep's
v2 needs (plan §3), and is explicitly out of scope here. v1 ships exactly
what the plan scoped: a deep-linked LinkedIn people search, zero LLM cost.

**Decision — no backend at all.** Every other brick in this integration
added a migration, a router, and Flutter plumbing. This one is pure URL
templating from data the app already has (`job.company`, `job.title`) — so
it's implemented as one pure Dart function
(`services/contact_discovery.dart::buildLinkedInSearchUrl`) plus a
`launchUrl` call, with zero server-side surface. There is nothing to
validate, log, rate-limit, or guardrail — Golden Rule 2 taken to its
logical conclusion: when the "logic" is a string template, code handles it
without needing a network hop to a server that would just template the
same string.

**Decision — a Google search restricted to LinkedIn (`site:linkedin.com/in
"{company}" "{role}"`), not a direct LinkedIn search URL.** LinkedIn's own
search requires a logged-in session and rate-limits/blocks unauthenticated
query URLs; a search-engine redirect works from a cold browser tab and
still lands the user on real LinkedIn profile results. The user does the
actual browsing in their own authenticated session — nothing here scrapes
or automates LinkedIn itself, which is what keeps this on the right side of
the ToS line ADR-003 already drew for job-board scraping ("no login-based
scraping, ever").

**Consequences:** one new file (`services/contact_discovery.dart`), one new
button on `AppDetailScreen`'s "Prepare" section ("Find people at
{company}"), opening the external browser via the same `launchUrl` pattern
`job_card.dart` already uses for "view original posting". No new table, no
new endpoint, no new LLM cost, no existing screen behavior changed.

## ADR-061: Referral rewards + full-match quota (Plan 21)

**Context.** `docs/` Plan 21 asked for a two-sided referral system tied to
bonus "full analysis" match unlocks, with a base free limit of 3 and +5 per
referral to both sides. The stated motivation is twofold: growth, and cost —
stage-2 re-ranking is the expensive LLM call in this app (ADR-020/021), so
capping how many jobs reach it caps the bill per profile.

**Conflict found before implementing.** The plan was written assuming "the
current shape of [any Pro-entitlement] system isn't visible", and treated the
quota as independent of it. It IS visible: `services/entitlements.py` +
migration 022 already implement `subscription_tier` (free/pro), documented as
"the ONLY thing that gates access in this app", with every profile backfilled
to `'pro'` and `default_tier="pro"`. Building the quota independently would
have meant every current beta user — all `'pro'` — dropped to 3 full matches,
so "Pro" would come to mean strictly *less* than it did the day before, and a
future paying subscriber would still be capped at 3 unless they recruited
friends.

**Decision — tier wins, quota gates the free tier only.** `subscription_tier`
stays the single access seam. `effective_match_limit()` returns the full
`DEFAULT_RERANK_LIMIT` for a `'pro'` profile and only applies
`BASE_FREE_MATCH_LIMIT + bonus_match_quota` below that. Referrals are the free
tier's growth lever rather than a tax on Pro, and when billing ships "Pro =
unlimited matches" is a coherent thing to sell.

**Decision — beta stays on `'pro'`, so the gate ships inert.** This reverses
the plan's "gate goes live now, for existing beta users too". Flipping the
beta to `'free'` was the alternative and was considered; keeping them on
`'pro'` was chosen to avoid visibly shrinking existing users' match lists
mid-beta. The consequence, accepted deliberately: the gate has no effect on
anyone today and starts biting only when a real `'free'` tier exists. It also
makes Plan 21's Phase 3 beta-comms step moot — there is no shrink to warn
anyone about (see MANUAL_STEPS).

**Decision — the clamp lives in `matching.py`, twice.** `rerank_shortlist`
clamps before planning any LLM call, so `POST /matches/rerank?limit=50` on a
3-limit profile re-ranks 3 jobs; the cap is a cost control, not a serializer
restriction. `get_ranked_matches` clamps again on read, which is NOT redundant:
the first clamp bounds LLM calls *per run*, so a gated profile legitimately
accumulates more than 3 cached `matches` rows across daily pipeline runs as the
job pool turns over. Without the read clamp the gate would widen a little every
day.

**Decision — locked teasers carry no stage-2 fields.** The `locked` array is
stage-1 similarity only (title/company/`similarity_pct`). Nothing is withheld
client-side, because nothing was computed: the LLM never saw those jobs. The
app blurs placeholder bars rather than real text, so there is no hidden
analysis sitting in the widget tree — the honest version of a paywall blur.

**Decision — reward on signup alone, guarded at the DB.** Per the plan, the
+5 releases on redemption with no activation gating. The guardrails are
deliberately lightweight and structural rather than behavioural: a UNIQUE on
`referrals.referred_profile_id` (the actual once-ever guarantee, holding under
a double-POST), CHECK constraints against self-referral on both tables, and a
`MAX_BONUS_MATCH_QUOTA` cap applied to the sum at grant time. No velocity
checks or device fingerprinting — out of scope until volume justifies them.

**Decision — `referral_code` is generated by a column DEFAULT, not in Python.**
Migration 036 defines a plpgsql generator and installs it as the column
default, so every profile-creation path gets a code without any Python change.
There are two insert sites today and there will be more; a default cannot be
forgotten the way a code path can. The backfill loops row-at-a-time on purpose
— a single set-based UPDATE would run every collision check against the
statement's start snapshot and could mint duplicates within itself.

**Migration numbering.** The plan specified `019_referral_system.sql`; 019
through 035 were already taken, so it shipped as `036_referral_system.sql`.

---

## ADR-062: Global remote boards — We Work Remotely + Remotive (ADR-003 v5)

**Date:** 2026-08-06
**Status:** Accepted, shipped disabled (`ENABLE_GLOBAL_REMOTE=false`)

**Context.** A widely-circulated listicle of "16 websites that pay in USD for
remote work" prompted the question of whether we could pull from them the way we
pull from Unstop. Ten were named: We Work Remotely, Hubstaff Talent, Wellfound,
Remotive, WorkWave, The AI Job Board, Remote Woman, Toptal, FlexJobs, JS
Remotely.

**Decision — only two of the ten are ingestible, and only two are worth it.**

| Board | Verdict |
| --- | --- |
| We Work Remotely | **Adopted.** Public RSS per category, no key, publisher-provided |
| Remotive | **Adopted.** Public documented JSON API, no key |
| Wellfound | Rejected — no public API, Cloudflare-gated, ToS forbids scraping |
| FlexJobs | Rejected — listings sit behind a paid subscription; scraping is paywall circumvention |
| Toptal | Rejected — not a board. You apply to Toptal's network; there are no listings to fetch |
| Hubstaff Talent | Rejected — reverse direction, a directory of freelancers for employers |
| WorkWave | Rejected — **the listicle is wrong.** `workwave.com` is field-service management software |
| AI Job Board / Remote Woman / JS Remotely | Rejected — no feed or API, HTML-scrape only, for a handful of listings each |

The two adopted are explicitly *not* scraping: both publish these feeds so third
parties can redistribute their listings. ADR-003's ban is on login-based
scraping and its risk calculus doesn't apply. They still run cron-only, for a
different reason — Remotive's terms ask for at most ~4 calls/day and the app's
"Run agent now" button has no such ceiling.

**Decision — adopted with eyes open, because the yield is near zero.** Measured
live on 2026-08-06 *before* writing any code, then confirmed end-to-end after:

```
WWR     215 unique tech postings → 21 fresh (≤10d) → 1 passes the gate
Remotive 31 rows (whole feed) → 8 open to India → 2 fresh → 0 pass the gate
```

And the single WWR survivor — "DevOps Engineer IV (Obs)" — is a **false
positive**: `is_entry_level` reads the description when the title doesn't match,
and that JD says "mentor junior engineers". The honest yield on the day of
writing was **zero genuine fresher roles**.

This is a supply problem, not a gate problem, and that distinction is the whole
point. ADR-003 v3 widened Unstop because the *role gate* was throttling a
catalogue already full of fresher postings — loosening it unlocked ~87/day. Here
the catalogue itself is senior-heavy and small: these boards serve experienced
devs chasing USD contracts. No gate change creates supply that isn't there.
Expected steady state is ~1-3 jobs/day.

Shipped anyway at the builder's explicit call, having been shown these numbers:
the few that land are genuinely remote and USD-paying, which no other source in
the pool offers. **Do not read the health log's single digits as a broken
source.** That is this source working correctly.

**Decision — a positive geo allowlist, rejecting unknowns.** `is_geo_eligible`
admits only regions that plausibly include India (worldwide / anywhere / global /
remote / india / asia) and rejects everything else, which inverts how
`_primary_city` treats an unrecognized place. The live distribution is why: 23 of
Remotive's 31 rows are hard country locks ("USA", "Brazil", "Uruguay", "USA, CST
(UTC-6)"), and storing one costs an embedding and a re-rank slot to show the user
a job they cannot legally take. An unrecognized region here is nearly always a
country name. A *missing* region is still treated as eligible — an unstated
restriction is not a restriction.

**Decision — `location` is hardcoded to `"Remote"`, not copied from the feed.**
Both boards are remote-only by construction, so this is structural knowledge
rather than an inference from JD text — the same move as the `wfh` branch in
`_unstop_row_to_job`. It's also load-bearing: the feeds say "Anywhere in the
World" and "Worldwide", neither of which `job_filter._REMOTE_LOCATION` matches,
so without this the location gate would reject the entire source.

**Decision — gate override is `entry` only.** `location` is redundant given the
line above (it can only pass), and `role` would take an already-thin source to
zero — requiring fullstack/frontend/cloud on top of entry-level leaves 0 of 215.
Entry-level stays for the reason it does everywhere: a staff-engineer contract is
dead weight in a fresher's pool.

**Decision — these sources are NEVER retired on absence.** The trap this pair
sets. Internshala and Instahyre use `retire_stale_jobs` because their listing
pages are a *complete* view of what's open. An RSS feed is not — it's a rolling
window of the most recent N items, so a live posting drops out simply by being
pushed down by newer ones, and retiring on absence would hide open jobs within
days. WWR publishes a real per-listing `expires_at` (like Unstop, unlike every
other source here) and Remotive falls back to the `job_expiry_days` age rule;
both are handled by `retire_expired_jobs()`. There is a test asserting
`retire_stale_jobs` is never called.

**Remotive attribution.** Their terms, returned in the payload's own
`0-legal-notice`, require linking back to the Remotive URL and naming Remotive as
the source. Both are satisfied structurally: `redirect_url` *is* the remotive.com
posting URL and `source="remotive"` renders as the source chip. Their other
conditions (no resyndication to third-party aggregators, no email-capture gating)
describe things this app does not do. Their feed is also delayed 24h by design —
harmless against a 10-day freshness window, but it means nothing here is same-day.

**Known follow-up, not fixed here.** `is_entry_level` falling back to the
description lets "we mentor junior engineers" mark a senior role entry-level. It
inflates every source's yield slightly and dominates this one's. Tightening
`_ENTRY` would shift Unstop/Internshala/Instahyre yields too, so it's a
deliberate separate change rather than a drive-by on a thin new source.

**No migration.** New sources are rows in `jobs`, not schema.
