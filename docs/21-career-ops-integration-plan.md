# Career-Ops Integration — Implementation Plan

> Written 2026-08-03, from a direct inventory of the live codebase (30 migrations,
> `server/services/`, `server/routers/`) plus a clone of
> [career-ops](https://github.com/BobbyWang0120/career-ops) (MIT). Companion to
> `docs/ROADMAP_PROPOSALS.md`, which already scoped 3 of the 6 features below
> independently — this plan absorbs those and adds the ones that weren't on the
> roadmap at all. Treat this as a proposal, not committed scope: nothing here is
> built yet, and per Golden Rule 6, it should still land one brick at a time.

## Status

- [x] **Brick 1 — posting legitimacy (§1.5, §5 step 1)** — shipped. Migration
  031, `services/job_legitimacy.py`, ingestion hooks (auto + manual),
  `backfill_job_legitimacy()` + `POST /jobs/backfill-legitimacy`, 11 passing
  pytest cases, and the `StatusPill` badge on `JobCard`/`MatchCard`/jobs
  list/shortlist/matches. See DECISIONS.md ADR-055 for the full reasoning.
- [x] **Brick 2 — cover letter generation (§1.1, §5 step 2)** — shipped.
  Migration 032 (`cover_letters`), `models/cover_letter.py`,
  `COVER_LETTER_SYSTEM_PROMPT` + `generate_cover_letter` (services/llm.py),
  guardrail reuse (no guardrail.py changes — `verify_bullet_atoms` applied
  per paragraph), `services/cover_letter_pdf.py`, `routers/cover_letters.py`
  (4 endpoints), 8 passing pytest cases, and `CoverLetterScreen` reachable
  from Match Detail. See DECISIONS.md ADR-056.
- [x] **Brick 3 — application/referral/cold email drafts (§1.6, §5 step 3)** —
  shipped. Migration 033 (`application_emails`), `models/application_email.py`,
  `APPLICATION_EMAIL_SYSTEM_PROMPT` + `generate_application_email`
  (services/llm.py), guardrail reuse (whole-body `verify_bullet_atoms`,
  no guardrail.py changes), `services/email.py` refactored around a shared
  `_send()` helper plus new `send_application_email`, `routers/
  application_emails.py` (3 endpoints: draft, list+attachments-checklist,
  send), 5 passing pytest cases, and a new "Application emails" section on
  `AppDetailScreen` (kind selector, drafts list, per-draft send) below the
  existing follow-up card. See DECISIONS.md ADR-057.
- [x] **Brick 4 — interview-prep v1 + story bank (§1.2, §5 step 4)** —
  shipped. Migration 034 (`interview_stories`), `models/interview_prep.py` +
  `models/interview_story.py`, `INTERVIEW_PREP_SYSTEM_PROMPT` +
  `generate_interview_pack` (DeepSeek, services/llm.py), per-STAR-field
  guardrail reuse (no guardrail.py changes), `routers/interview_prep.py`
  (pack generation — disposable, never stored — plus story-bank CRUD),
  16 passing pytest cases, and two new Flutter screens
  (`InterviewPrepScreen`, `StoryBankScreen`) reachable from
  `AppDetailScreen`'s new "Prepare" section and from Profile. See
  DECISIONS.md ADR-058.
- [x] **Brick 5 — offer-prep contract reader (§1.3, §5 step 5)** — shipped.
  Migration 035 (`offer_reviews`), `models/offer_review.py` (no verdict
  field, structurally), `OFFER_REVIEW_SYSTEM_PROMPT` + `analyze_offer`
  (Gemini, services/llm.py), a new deterministic clause-grounding check
  (`services/offer_review.py`, distinct from guardrail.py — verifies
  document-quote grounding, not candidate-fact grounding),
  `routers/offer_reviews.py`, 9 passing pytest cases, and `OfferReviewScreen`
  reachable from `AppDetailScreen`. See DECISIONS.md ADR-059.
- [x] **Brick 6 — contact discovery v1, search-URL only (§1.4, §5 step 6)**
  — shipped. Zero backend: `services/contact_discovery.dart` builds a
  deep-linked LinkedIn people search (`site:linkedin.com/in "company"
  "role"`), opened via the same `launchUrl` pattern `job_card.dart` uses —
  no new table, router, or LLM cost. "Find people at {company}" button on
  `AppDetailScreen`. See DECISIONS.md ADR-060.

## 1. What we're adding

Six features, each mapped to career-ops's implementation and re-cast into this
app's architecture (Pydantic schema → guardrail → human approval, Golden Rules
2–5 throughout).

### 1.1 Cover letter generation
*Career-ops equivalent: `modes/oferta.md`'s cover-letter block.*

Reuses the tailor → guardrail → approve → PDF chain that already exists for
résumés. New: `CoverLetterLlmResponse` (Pydantic), a `generate_cover_letter`
task in `services/llm.py`, a `cover_letters` table (mirrors
`tailored_resumes`: `bullets`→`paragraphs`, same `approved` flag), and a
one-page ReportLab template. **Guardrail requirement:** every factual claim
in a cover letter paragraph must run through the same atom-level check
(`guardrail.verify_bullet_atoms`) résumé bullets already use — a cover letter
inventing a metric is the same trust failure as a résumé doing it, so this is
not optional.

### 1.2 Interview-prep packs + story bank
*Career-ops equivalent: `modes/interview-prep.md`.*

Two tiers, because career-ops's version depends on live WebSearch (Glassdoor,
levels.fyi, Blind) and **this app has no web-search capability today**:

- **v1 (no new infra):** `generate_interview_pack(job, match, profile)` — an
  LLM task grounded only in the JD text + the match's existing `gaps`/
  `strengths` (already computed, zero new data dependency). Produces likely
  questions + STAR-format suggested answers, explicitly labeled
  `[inferred from JD]` the way career-ops tags ungrounded questions. This is
  exactly `docs/ROADMAP_PROPOSALS.md` proposal #4 — build this first.
- **v2 (stretch, needs a new integration):** company-specific research
  (interview process, comp data, culture) requires a real search API. See
  §3 — this is the one place in the whole plan that isn't purely additive.

New table `interview_stories` (profile_id, situation, task, action, result,
reflection, source_job_id, created_at) — the "story bank" career-ops
accumulates across evaluations. Distinct from the pack itself: packs are
per-job and disposable, the story bank persists and grows across every job
a user preps for, so a story written for one interview surfaces again for
the next matching one.

### 1.3 Offer-prep / contract reading companion
*Career-ops equivalent: `modes/offer-prep.md`.*

A clause-by-clause plain-English reader for an offer letter/contract, paired
with your Kanban's existing `offer` state. Deliberately narrow scope, copied
directly from career-ops's own hard guards because they're correct: **never
outputs a verdict** ("safe to sign"/risk score), **never states law from
memory** (jurisdiction questions go to a "questions for your lawyer" list,
never answered inline), **no web research** — contract text and compensation
figures never leave the model call as a search query. New table
`offer_reviews` (profile_id, application_id, raw_text, clauses jsonb,
questions_for_lawyer jsonb). This is a different feature from
`ROADMAP_PROPOSALS.md` #8 (Adzuna salary percentiles — pure Python, no LLM);
the two are complementary, not overlapping — #8 tells you what the market
pays, this explains what the document in front of you says.

### 1.4 Contact discovery + outreach drafts
*Career-ops equivalent: `modes/contacto.md`.*

Same two-tier split as interview-prep, for the same reason:

- **v1 (no new infra):** ship `ROADMAP_PROPOSALS.md` #10 as originally
  scoped — a deep-linked LinkedIn *search* URL per match
  (`site:linkedin.com/in "{company}" "{role}"`), zero LLM cost, ToS-safe
  because the user does the browsing in their own session.
- **v2 (needs the same search API as §1.2):** career-ops actually finds
  named people (hiring manager / recruiter / peer) and drafts a
  ≤300-character message per contact type with a 3-sentence framework
  (fit → proof → CTA). Real value-add over v1, but real-people lookup is
  exactly the kind of external data fetch that needs the same new,
  ToS-clean integration as interview research — batch these two together
  once that integration is built.

### 1.5 Posting-legitimacy / ghost-job signal
*Career-ops equivalent: `modes/oferta.md` Block G.*

This is the one addition that should be **mostly Python, no LLM**, per
Golden Rule 2 — and the data to compute most of it already exists in the
`jobs` table: `posted_at`/`expires_at` (freshness, migrations 019/029),
`description` length and boilerplate ratio, `salary_min`/`salary_max`
presence, `work_type`. A new `services/job_legitimacy.py::score_posting()`
computes a deterministic tier (`high_confidence` / `proceed_with_caution` /
`suspicious`) from these signals at ingestion time — shared across the whole
job pool, computed once, not per-user, so it's nearly free. Two new
`jobs` columns: `legitimacy_tier text`, `legitimacy_signals jsonb`. An
**optional** LLM pass (DeepSeek, cheap) only for the one signal Python can't
do well — career-ops's employment-classification check (contractor-status
language like "1099"/"invoice for services") — run once per job at
ingestion, same shared-cost logic as embeddings already use.

### 1.6 Application email drafts
*Career-ops equivalent: `modes/email.md`.*

Distinct from the existing 7-day follow-up nudge (`generate_followup_draft`)
— this is a *first-contact* draft: formal application email, recruiter
email with CV attached, referral request, cold outreach. Small addition:
one new LLM task (`generate_application_email`) following the exact same
shape as `generate_followup_draft` already does, stored on a new
`application_emails` table (not bolted onto `applications`, since an
application can have several draft variants before the user picks one).

---

## 2. Does it break the existing app?

**No.** Every addition here follows the same additive pattern your own 30
migrations already establish — `create table if not exists` or
`alter table ... add column if not exists`, never a rewrite of an existing
column's meaning. Concretely, by layer:

| Layer | Impact | Why it's safe |
|---|---|---|
| Database | +6 new tables, +2 columns on `jobs` | No existing table's schema changes meaning; matches the exact pattern of migrations 009 (`background_tasks`), 012 (`form_fills`), 023 (`notifications`), 024 (`chat_*`) — all additive, all shipped without touching existing tables' semantics |
| `services/llm.py` | +5 new task functions | They plug into the existing `_run_llm_task` runner (ADR the collapsed-eight-functions decision) — validation, retry-once, and `llm_calls` logging come for free, zero new failure modes |
| `services/guardrail.py` | Reused, not modified | `verify_bullet_atoms`/`verify_bullets` are already provider-agnostic pure functions; cover letters and application emails call the *same* functions résumés use |
| `services/entitlements.py` | Reused, not modified | `require_tier(profile, "pro")` already exists as an unused seam (everyone is 'pro' today) — gate all 6 new features through it now, so a future paid tier is a config flip, not new code |
| `services/rate_limit.py` | +5-6 new endpoint keys | Additive registrations, same as every router addition to date |
| Daily pipeline | +1 optional branch | An interview-reminder or deadline-nudge hook into `_process_profile` follows the existing `notification_prefs`-gated pattern (`alerts`, `followup_nudge`) — opt-in, doesn't change behavior for anyone who doesn't enable it |
| Flutter app | +6-8 new screens, 0 nav restructuring | Every new screen hangs off an existing entry point that already exists — the match card (cover letter, interview prep), the Kanban `offer` card (offer-prep), the app detail screen (contact discovery, application email). No new bottom-nav tab required |

**The two things that are NOT risk-free and need honest scoping up front:**

1. **Web search dependency.** The "v2" tiers in §1.2 and §1.4 — and the
   full richness of career-ops's actual interview-prep and contact-discovery
   modes — depend on live web search against Glassdoor/LinkedIn/levels.fyi.
   This app has no search integration today, and scraping those sites
   directly would sit in the same category your own ADR-003 already
   rejected for job boards ("no login-based scraping, ever"). The correct
   path is a licensed search API (there are several that explicitly permit
   this use), which means a new server-side secret (Golden Rule 1 — never
   in the Flutter app), a new cost line, and a ToS review before writing
   any code. Ship the v1 (search-free) tiers first; treat v2 as its own
   scoped decision, not a silent scope-creep inside this plan.
2. **Guardrail coverage is a must-do, not a nice-to-have.** Cover letters
   and application emails are new *generative* surfaces. If they ship
   without running through `verify_bullet_atoms`, Golden Rule 4 is
   silently violated the first time either feature paraphrases a metric
   that doesn't exist. This should be a blocking item in each brick's
   definition-of-done, not a follow-up.

---

## 3. Before / after

**Before:**
30 migrations · 34 services · 12 routers · tailoring pipeline covers résumés
only · Kanban tracks state + one follow-up-email type · zero interview-prep,
zero cover letters, zero contract reading, zero contact discovery, zero
posting-legitimacy signal · `require_tier` gate exists but nothing uses it.

**After:**
~36 migrations · ~40 services · ~17 routers · tailoring pipeline covers
résumés **and** cover letters through the same guardrail · Kanban's `offer`
state has a real feature behind it (contract reading) instead of being a
label with no content · every match/job carries a legitimacy signal computed
for free from data already in the table · users get a growing, reusable
interview story bank instead of re-answering the same behavioral questions
from scratch each time · `require_tier` gates all 6 new features, so flipping
`DEFAULT_TIER=free` in one env var instantly turns this into the paid-tier
feature set without a code change · cost dashboard (`GET /stats/costs`)
gains 5 new task labels alongside the existing 9.

Nothing in the "before" column stops working. This is additive scope on top
of Bricks 1–9, not a rework of them.

---

## 4. LLM cost impact

Pricing is your own `services/cost_stats.py` table (USD per 1M tokens),
current as of ADR-023's verification:

| Model | In | Out |
|---|---|---|
| gemini-2.5-flash | $0.30 | $2.50 |
| gemini-2.5-flash-lite | $0.10 | $0.40 |
| deepseek-v4-flash | $0.14 | $0.28 |

Per-call estimates below, same "close enough to be useful, not a billing
system" bar `cost_stats.py` already applies — these are engineering
estimates, not measured numbers, until real usage exists.

| Feature | Provider | Est. tokens (in/out) | Est. cost/call | Trigger frequency |
|---|---|---|---|---|
| Cover letter | Gemini flash (shares tailor's guardrail-sensitive routing) | ~1,500 / 500 | ~$0.0017 | User-initiated, roughly 1 per tailored résumé at most |
| Interview pack (v1, no search) | DeepSeek | ~2,000 / 1,000 | ~$0.0006 | User-initiated, once per `interview`-stage application |
| Offer-prep contract read | Gemini flash | ~4,000 / 2,000 | ~$0.0062 | Rare — once per received offer, a handful of times per user ever |
| Contact outreach draft (v1: no LLM, pure URL) | — | — | $0 | Free |
| Posting legitimacy (base signals) | none (pure Python) | — | $0 | Free, computed at ingestion |
| Posting legitimacy (contractor-language pass) | DeepSeek | ~300 / 150 | ~$0.00008 | Once per NEW job at ingestion, shared across all users — **not** per-user |
| Application email draft | DeepSeek | ~1,200 / 400 | ~$0.0003 | User-initiated, comparable frequency to existing follow-up drafts |

**Net effect at current beta scale:** the per-user recurring costs (rerank,
embeddings, parse) are unchanged — none of these six features run inside the
daily automatic pipeline by default. Every one is user-initiated, so cost
scales with actual usage, not with the size of the user base sitting idle.
The one shared-pool cost (legitimacy contractor-check) adds roughly
$0.01–0.02/day *total* across every user combined at ~100–200 new jobs/day
ingestion volume — same order of magnitude as embeddings already cost per
day, not a new cost category.

**Realistic per-active-user/month estimate**, assuming a moderately engaged
user generates 3 cover letters, preps for 2 interviews, reads 1 offer
contract, and drafts 2 application emails in a month: roughly
**$0.02–0.03/month/active user** — small next to what resume tailoring and
daily re-ranking already cost per user, and gated behind `require_tier` so
it can be scoped to paying users only from day one if that's the intent.

**If v2 (search-grounded interview-prep / contact discovery) is ever built:**
that's a materially different cost line — a per-query search API charge on
top of the LLM call, plus larger prompts (search results are context). Don't
fold that estimate into "adding career-ops features" broadly; price it
separately once the specific search provider is chosen.

---

## 5. Suggested build order

One brick at a time, per Golden Rule 6:

1. **Posting legitimacy (base signals)** — pure Python, no LLM, no new UI
   required beyond a badge on the job card. Cheapest, safest first brick;
   validates the whole plan's "additive, non-breaking" claim in production
   before anything generative ships.
2. **Cover letter generation** — highest reuse of existing infrastructure
   (tailor → guardrail → PDF chain already built).
3. **Application email drafts** — smallest new surface, same shape as the
   follow-up draft that already exists.
4. **Interview-prep v1 + story bank** — new table, new screen, but no new
   external dependency.
5. **Offer-prep contract reader** — rare-trigger, higher per-call cost, but
   self-contained (no search dependency, explicit hard guards already
   defined in §1.3).
6. **Contact discovery v1 (search-URL only)** — trivial, ship alongside #4
   or #5 whenever convenient.
7. **Decision point:** evaluate a licensed search API for v2 of
   interview-prep and contact discovery, as its own scoped brick with its
   own ADR — not bundled into this plan.

---

## 6. Future features — what career-ops's *methodology* teaches, beyond its feature list

These aren't features to port directly; they're design patterns visible in
how career-ops is built that could improve this app's own architecture over
time.

**Bounded research budgets.** career-ops caps company research at "5 total
WebSearch queries, stop early when enough evidence exists" — a hard ceiling
on cost/latency for any LLM-adjacent research step. Worth adopting as a
standing rule for whatever the eventual search-API integration (§3) becomes,
rather than letting an "investigate this company" feature run open-ended.

**Archetype detection before scoring.** career-ops classifies a role's
archetype (IC vs. management-track, startup vs. enterprise) *before* running
its evaluation blocks, so the scoring weights adapt to what's actually being
evaluated. `services/matching.py` currently uses one scoring shape for every
job; a cheap classification step feeding a deterministic weight lookup
(still Golden Rule 2-clean — the LLM classifies, Python weights) is a
natural evolution of the re-ranker once the single `fit_score` starts
feeling too coarse.

**Structured multi-axis evaluation.** career-ops's A–G blocks (role summary,
CV match, level strategy, comp research, personalization, interview prep,
legitimacy) suggest `MatchResult` could grow richer sub-scores (culture fit,
comp fit, growth trajectory) instead of one `fit_score` + free-text
strengths/gaps — worth revisiting once real user feedback says the single
number is hiding useful nuance.

**Cheap/local-model tiers for cost-sensitive tasks.** career-ops ships
standalone evaluators against free-tier and fully local models
(`gemini-eval.mjs`, `ollama-eval.mjs`) as a budget path. This app already
does two-provider routing (Gemini/DeepSeek per ADR-023); the same idea
applied to `gemini-2.5-flash-lite` or a local model for the lowest-stakes
new tasks (e.g., the legitimacy contractor-check) could matter once the
wallet/subscription feature (migration 022) becomes a real cost cap instead
of the current cosmetic counter.

**Learned writing voice.** career-ops maintains a per-user "voice DNA"
profile so generated outreach messages and cover letters sound like the
candidate, not like a template. Nothing in this app currently learns from a
user's edits to tailored content — a natural pairing with cover-letter
generation (§1.1): if a user consistently rewrites the tone of drafts, that
signal could feed back into future generations, the same anti-genericness
problem career-ops's voice-DNA system solves.

**Batch/parallel evaluation for bulk actions.** career-ops evaluates 10+
saved offers in parallel via sub-agent workers. The existing
`background_tasks` async pattern (migration 009, already used for
`POST /matches/rerank`) is the right primitive to extend into a "generate
interview packs for all my `interview`-stage applications at once" bulk
action later — no new infrastructure, just fanning out calls that already
exist.

**Company research as a standalone feature.** Once a licensed search API
exists for interview-prep/contact-discovery (§3), the same integration
naturally extends into career-ops's `deep` mode — a standalone "research
this company" feature (AI strategy, recent moves, culture, candidate angle)
that feeds personalization back into both cover letters and tailoring.
Worth treating as the second thing built on that integration, not a
separate cost center.
