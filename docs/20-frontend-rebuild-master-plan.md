# 20 — FirstRole Frontend Rebuild — Master Plan

**Single source of execution truth.** Consolidates `17-frontend-requirements.md`
(the *what*), `18-frontend-rebuild-execution.md` (the *how/order*), and
`19-resume-quality-plan.md` (the parallel résumé-quality track) into one ordered
plan with every previously-unresolved irregularity now decided.

**Baseline:** commit `3bad610`, clean tree, migrations through `018` applied and
verified. Branch from `main`. Product name is **FirstRole** (ADR-029).

**Authority order** (unchanged from doc 17 §0): `JobHuntAgent.dc.html` = pixel
truth · `FLUTTER_GUIDE.md` = implementation truth · design `README.md` = behavior
truth · doc 17 = reconciliation truth · **this file** = execution truth (order,
ownership, and the resolutions below).

---

## 0. Resolutions decided in this plan

These close the open irregularities found when reconciling the three docs. They
are decided — implement them, do not re-litigate.

| # | Issue | Resolution |
|---|---|---|
| R-A | **Migration numbering across two parallel tracks.** Doc 18 claims `019`–`024`; doc 19 needs migrations with no assigned numbers. | Doc 18 owns `019`–`024`. **The résumé track owns `025`–`026`, numbered in the order they apply:** `025_guardrail_unextractable_log.sql` (needed by R1, which runs first) and `026_metric_answers.sql` (needed by R5, which runs fourth). Neither track may take a number outside its block, and within a block numbers apply in ascending order. |
| R-B | **Wallet drains to ₹0 and stays there forever.** "Decrement and clamp at zero" leaves every user staring at a permanent "₹0 · ≈0 actions left" card while the app keeps working — the UI states something false. | **Balance is cosmetic telemetry that never gates, and resets monthly.** It decrements as real LLM spend accrues, and **resets to ₹200 (20000 paise) on the `subscription_period_end` rollover** (migration `022` already has the column; matches the design's "subscription grants monthly credits" intent). It still **never gates anything** — tier (`subscription_tier`) is the only real entitlement, via `entitlements.py`; `wallet_balance_paise` is never read in an authorization path. |
| R-C | **`actions_remaining` divides by an empty `llm_calls` history** for a new user. | When the trailing-30-day sample is empty, `/wallet` returns `actions_remaining` computed from a config constant `WALLET_FALLBACK_COST_PAISE` and sets `"estimated": true` **inside the `data` object** (not beside it — the envelope stays `{"data": ..., "error": null}`). Once real rows exist, the derived mean takes over and `estimated` is `false`. Never a hardcoded action count. |
| R-D | **Delta chip computes to ~0 and becomes permanently meaningless.** Plumbing is correct (`/pipeline/run-mine` → `run_daily_pipeline_for_profile` → `_process_profile` writes a `score_snapshots` row, no paid source reached) — but run-mine is rate-limited to 5/300s, so a user refreshing three times a minute writes three snapshots minutes apart, and a delta against the *immediately-previous* row is ~0 every time. | **Keep both write paths.** Change the read: `GET /stats/score-history` computes the delta against **the latest snapshot at least 24h older** than the current one, not the previous row. Day-over-day was the point. Still hide the chip entirely until such a prior snapshot exists (never a fabricated delta). |
| R-E | **R1 golden-set (≥30 labelled bullets) is a merge gate with no owner.** | The golden-set is a **named deliverable of R1**, authored before R1 code merges, committed at `server/tests/data/guardrail_golden_set.jsonl`. R1 does not merge without it (doc 19 risk #1). |
| R-F | **Fonts.** `google_fonts` fetches at runtime by default — a release app should not depend on a network call for its typeface. | **Bundle Inter, JetBrains Mono, and Playfair Display as `assets/fonts/`** and configure `google_fonts` to prefer bundled assets (`GoogleFonts.config.allowRuntimeFetching = false`). Removes FOUT and offline first-launch failure. |
| R-G | **OAuth deep-link + go_router redirect** is called out as the likeliest thing to break. | Build it as an **isolated de-risking spike at the very start of Phase 2b**, proven end-to-end (sign-in lands on the right screen) *before* migrating the 30 `Navigator.push` calls onto go_router. Do **not** change the URI scheme (ADR-031). |

---

## 1. How to work (hard process rules)

- **One phase at a time.** Stop at each phase boundary, report, and **merge to `main`.** Do not accumulate a large uncommitted tree.
- Read doc 17 §3 before any screen work — 12 deviations are already decided; implementing the design as drawn is a bug.
- When design and backend conflict and doc 17 §3 does not cover it, **stop and ask.**
- `flutter analyze` and `pytest` stay **green at every boundary.** No phase merges red.
- Every new backend endpoint gets a pytest file in the same phase that adds it.

## 2. Golden rules (every phase, non-negotiable)

1. Secrets server-side only (client holds Supabase URL + anon key, nothing else).
2. LLMs handle language; code handles logic (scores, states, counts, money, %, diffs → Python).
3. Every LLM output schema-validated, retried once with the error appended, then failed gracefully.
4. The anti-fabrication guardrail is sacred. Its *mechanism* changes under the résumé track (ADR-033); its *purpose* does not.
5. Every LLM call logged to `llm_calls` with the provider that actually served it.
6. No auto-submit, ever — every consequential action is a deliberate human press.
7. Consequential actions are `HoldButton`, never a tap.
8. Scraping stays cron-only. The `daily_pipeline.py` split (`_refresh_scraped_if_due()` reachable only from `run_daily_pipeline_for_all()`) survives untouched. No UI control reaches a paid source.
9. Never persist sensitive form answers (gov ID, DOB, bank, passwords).
10. Widgets read tokens, never a literal hex or px.
11. All money in ₹, stored as integer **paise**.
12. Do not regress: 202+poll, SWR cache, refresh throttle, rate limits, SSRF guard, PDF safety bounds.

---

## 3. Track A — Frontend rebuild (Phases 1–10)

### Phase 1 — Documentation reconciliation
Fix Drifts 1–20 from `docs/audits/CODEBASE_STATE_2026-07.md` §10.2 exactly as quoted:
Cloud Run (not Render) · `gemini-embedding-001` · real `_TASK_PROVIDERS` split ·
ADR-003 v2 scraping wording · all nine fetchers (incl. Internshala + Unstop) ·
real upload keystore · `MAX_JOB_AGE_DAYS=10`. Add `**Date:**` lines to ADRs
010–028. Regenerate `docs/claude-project-knowledge/`. Rewrite `MANUAL_STEPS.md`
§3 for Cloud Run. Write a real root `README.md`.
**Acceptance:** grep for `Render`, `text-embedding-004`, `no scraping`, `onrender.com`
— every surviving hit is a deliberate historical reference inside an ADR body.

### Phase 2 — Foundation: theme, router, state, haptics
- **2a Tokens + dark mode** — `theme/app_colors.dart` (`AppColors extends ThemeExtension`, light+dark verbatim from FLUTTER_GUIDE §1 + `gaugeGradient`); `theme/app_theme.dart` (`appLight`/`appDark`, Inter body / JetBrains Mono numerals / Playfair hero). **Bundle fonts per R-F.** `MaterialApp` gains `darkTheme`+`themeMode`, persisted through the existing `CacheService` (no second storage layer). Keep `app_tokens.dart` until Phase 10.
- **2b OAuth spike + go_router** — **first, the R-G spike**: prove `com.jobhuntagent.jobhunt_agent://login-callback/` completes sign-in and lands correctly under a `redirect` keyed on Supabase auth state via `refreshListenable`. **Do not change the scheme** (ADR-031). Then: add `go_router`, route table for all 16 design screens + retained; five tab routes under a `StatefulShellRoute` (replaces `IndexedStack`); replace all 30 `Navigator.push` calls across 12 screens; working back chevron **and** Android system-back everywhere.
- **2c Riverpod** — add `flutter_riverpod` (no codegen), wrap in `ProviderScope`. Convert `MatchFeed`→`AsyncNotifier`, `TaskCenter`→`Notifier` (most likely casualties of go_router rebuild semantics). New screens use Riverpod from the start; existing migrate opportunistically.
- **2d Haptics** — `services/haptic_service.dart`, single wrapper over `HapticFeedback`, reads a Settings toggle + respects system setting. Map per doc 18 §2d. **Nothing on loading, scroll, or repeating.**

**Acceptance:** `flutter analyze` clean; all 27 screens reachable; back nav correct; dark mode survives restart; **Google OAuth completes and lands on the right screen**; haptics fire on tab switch and nowhere else yet.

### Phase 3 — Signature widget library (no screen work)
Build against FLUTTER_GUIDE §3–§8: `fit_gauge.dart` (270° arc, 900ms easeOutCubic
to `target+5`, 520ms easeInOut correct-down, live-tracking) · `agent_mascot.dart`
· `agent_orb.dart` · `hold_button.dart` (1100ms fill, 200ms spring-back, haptics)
· `source_chip.dart` (**11 sources + unknown fallback** — `jobs.source` has no
CHECK; unmapped renders neutral, never crashes) · `agent_overlay.dart` (driven by
real `GET /tasks/{id}`) · `agent_toast.dart` (replaces `task_toast.dart`) ·
`celebration_modal.dart` · `mascot_loader.dart` (replaces skeletons at every call
site) · `hatched_progress.dart`.
**Acceptance:** debug-only gallery route renders every widget in both themes; gauge timings match; no literal hex/px in any widget.

### Phase 4 — Backend: schema + endpoints
Migrations `019`–`024` (head is `018`):

| Migration | Adds |
|---|---|
| `019_jobs_work_type.sql` | `jobs.work_type` CHECK `('remote','hybrid','onsite')` nullable; backfill via `job_filter.py::is_remote` logic (currently computed then discarded). |
| `020_score_snapshots.sql` | `score_snapshots(id, profile_id FK cascade, top_fit_score int, avg_fit_score real, match_count int, captured_at)`; index `(profile_id, captured_at desc)`; RLS owner-read. |
| `021_profile_onboarding_fields.sql` | `profiles.branch, grad_year, cgpa, company, experience_years, notice_period_days, target_locations jsonb default '[]'`; widen `onboarding_step` CHECK for new steps. |
| `022_subscription_and_wallet.sql` | `subscription_tier text not null default 'pro'` CHECK `('free','pro')`; `subscription_status`; `subscription_period_end`; `wallet_balance_paise bigint not null default 20000`; backfill all rows. |
| `023_notifications.sql` | `notifications(id, profile_id FK cascade, kind, title, body, action_type, action_ref uuid, read_at, created_at)`; index `(profile_id, created_at desc)`; RLS owner-read. |
| `024_chat.sql` | `chat_threads(...)`, `chat_messages(... role CHECK ('user','assistant') ...)`; RLS owner-read on both. |

**New endpoints:** `GET /stats/score-history` (**delta computed against the latest snapshot ≥24h older, per R-D; chip hidden until one exists**) · `GET /jobs/facets` (pure SQL histogram+counts) · `GET /notifications` (+unread count in envelope) · `PATCH /notifications/{id}/read` · `POST /notifications/read-all` · `POST /chat` (202+task) · `GET /chat/threads`, `/chat/threads/{id}` · `GET /subscription` · `GET /wallet` (**R-B cosmetic monthly-reset balance + R-C `actions_remaining` with `estimated` inside `data`**) · `DELETE /account` (cascade all profile-scoped tables + Supabase auth user, `HoldButton` only).

**Backend changes:** `_process_profile` writes a `score_snapshots` row (R-D); `daily_pipeline` writes a `notifications` row on each push; `job_ingestion.py` persists `work_type`; new `services/entitlements.py` (`require_tier(profile,'pro')`, real seam, passes for all while `DEFAULT_TIER=pro`); new `services/chat.py` (grounded on profile + top ~10 matches + application states; hard-instructed against out-of-context assertions; schema-validated, logged, rate-limited).

**Security fixes (you're in these files anyway):** move `POST /forms/parse` to `StrictModel`, route `form_parser.py::fetch_form_html` through `_assert_public_url` (SSRF); add rate limits to `/forms/parse`, `/forms/fill`, `/applications/{id}/followup`, `/stats/skill-growth`.

**Acceptance:** every new endpoint has a pytest file; `pytest` green; cross-user access → 404 on all new routes; `/wallet` derives its number from real `llm_calls` (and falls back per R-C for empty history, with `estimated` inside `data`); `/stats/score-history` returns a delta only when a snapshot ≥24h older exists, else no delta (R-D); a test flips `DEFAULT_TIER=free` and asserts 402.

### Phase 5 — Core tabs
Rebuild the five bottom-nav screens (Home §4.2, Jobs §4.3, Matches §4.5, Track §4.9, Profile §4.11) on Phase-3 widgets.
**Acceptance:** all five render populated/loading/empty/error; gauge shows a real delta **or hides itself** (never a fabricated delta — hide until two snapshots exist); Kanban drag persists via `PATCH /applications/{id}` optimistic + revert-on-failure; every consequential action is a `HoldButton`; no skeleton survives here.

### Phase 6 — Filter sheet + onboarding
Filter sheet §4.4 (depends on migration `019` `work_type` + `GET /jobs/facets`; filter state = one Riverpod provider shared by sheet/list/badge; toggles **filter the shared pool, never fetch**). Onboarding §4.1 (extends `onboarding_step` machine + `student_info_screen.dart`; résumé upload not skippable; force-quit resumes on correct step; target locations persist per-profile).
**Acceptance:** filter updates the count without a full refetch; force-quit resumes correctly; both fork branches reach `done`; the sheet triggers **no** fetch.

### Phase 7 — Match detail, tailor flow, form fill
Match detail §4.6 · Tailor flow §4.7 · Apply-via-form §4.8 (in-app WebView, honest "you attach the PDF and submit" copy — Google Forms prefill **cannot** populate file-upload; **no DOM injection**; answer reuse keyed per-question; never persist sensitive answers).
**Coordinate with Track B:** in a single-agent run, **R1 → R3 → R2 land immediately before this phase** (§4), so build the real section-review + "Trimmed" restore UI here — no stub. The metric-prompt affordance (R5) comes later; leave a slot for it but do not block on it. Only build the bullet-only diff + stubbed section-review if you are genuinely running two agents and R2 has not landed.
**Acceptance:** a real Google Form parses/prefills/opens in-app; a file-upload form degrades with honest copy; a second fill reuses prior answers; guardrail flags visible; PDF downloads.

### Phase 8 — Career chat (§4.10)
`POST /chat` 202+poll; grounded on profile/matches/applications; refuses to invent; DeepSeek via `settings.chat_provider`; schema-validated, logged, rate-limited.
**Acceptance:** answers a profile-specific question; **refuses to invent** a job/skill/employer not in context; history survives restart; call shows in `GET /stats/costs` under the right provider.

### Phase 9 — Wallet, notifications, about, deletion
Wallet §4.12 (**R-B: cosmetic, never gates, resets to ₹200 on `subscription_period_end` rollover**; bars from `GET /stats/costs` `by_provider`; `actions_remaining` per R-C) · Notifications §4.13 · About §4.14 (static) · Deletion §4.15 (`HoldButton` only).
**Acceptance:** wallet number moves as real spend accrues, **never blocks**, and **resets to ₹200 on the period rollover** (a test advancing past `subscription_period_end` sees the balance restored); notifications mark read + persist; deletion removes every profile-scoped row **and** the auth user, verified by query.

### Phase 10 — Cleanup + verification
Delete `app_tokens.dart`, `loading_skeleton.dart`, `page_skeletons.dart`, superseded screens. Give **Skill Growth** + **Shortlist** a home as Profile sub-screens (deleting a working feature by omission is a bug). Widget tests for the new signature widgets. `flutter analyze` clean incl. `anonKey → publishableKey`. **On-device verification** (ADR-007 gap): sign-in, push, upload, WebView, Kanban drag, haptics, both themes, real Android device. New ADRs: go_router, Riverpod, subscription/wallet model, chat provider, haptic policy.

---

## 4. Track B — Résumé quality (slotted around Phase 7, not truly parallel)

A single Claude Code session executes both tracks interleaved, so "parallel" is
a fiction that would make you build the Phase 7 diff screen twice (once as a
stub, once for real). **Slot the JD-selection prerequisites — R1 → R3 → R2 —
between Phase 6 and Phase 7**, so Phase 7 always gets the real section-review UI
and the stub never exists. **R5 → R4 → R6 continue after Phase 10.** Only reach
for the Phase-7 stub if you are genuinely running two agents in parallel.

Own migrations **`025`–`026`** (R-A), applied in ascending order. Full execution
order across the slots: **R1 → R3 → R2** (before Phase 7) then **R5 → R4 → R6**
(after Phase 10).

- **R1 — Atom-level guardrail** (replaces whole-bullet fuzzy match). Decompose each tailored bullet into factual atoms (numbers/metrics exact, tech vs lexicon+`skills[]`, employers/titles from structured fields, dates exact, scope claims never upgraded); every atom must trace to source; atoms may be dropped, never added/inflated/upgraded; prose floats free. Keep `verify_skills` at 80 and `compute_gaps` unchanged. **Requires ADR-033 + the golden-set (R-E) before merge.** Log unextractable tokens to storage from **migration `025`**.
- **R3 — Deterministic prose lint** (no LLM, pure functions, fully unit-tested): weak openers, verb repetition (≤2), passive voice, >~180 char length, tense consistency, filler, pronouns, zero-atom density. **Advice only — never blocks.**
- **R2 — Section-level tailoring** (selection, not just rephrasing; Python-first): score every experience/bullet vs JD (embedding cosine + keyword overlap, **no LLM**) → deterministic select (relevance floor, per-experience bullet caps, always keep most-recent role) → order by recency/relevance → rephrase survivors → **disclose every drop** in `tailored_resumes.gaps` with one-tap restore. Also tailor `profiles.headline` under the same atom guardrail. **ADR-034.** **Acceptance:** same profile + same JD → **identical selection every run** (selection is Python; if it isn't reproducible it isn't deterministic); the most-recent role never drops; every drop appears in the Trimmed list and is restorable.
- **R5 — Metric prompting** (ask, never invent): where R3 flags zero density and the JD wants measurable impact, the diff shows an inline prompt; free-text feeds a single-bullet regen; **answers persist to `profiles.metric_answers` (migration `026`)** so the same question is never re-asked; optional, never blocks.
- **R4 — Two-pass generate→critique→revise** (ADR-035): pass 2 runs **only** on drafts with a lint finding or low self-score; logs under `tailor` vs `tailor_critique`; `tailor_provider` **stays Gemini** (DeepSeek-for-tailoring remains gated on an un-recorded A/B — do not flip here).
- **R6 — One-page ATS-safe layout** (ADR-036): change `resume_pdf.py` from shrink-to-fit to **cut-to-fit** using R2's ranking; single column, standard headings, embedded selectable text, no header/footer contact, one accent colour max. **Acceptance:** output is **always exactly one page**, and text **extracts cleanly via `pypdf` in correct reading order**; content is cut by relevance, never shrunk below the readable band; a two-column layout is never produced.

---

## 5. Execution order (single-agent, interleaved)

One session runs both tracks as one sequence:

```
1 → 2 → 3 → 4 → 5 → 6 → [ R1 → R3 → R2 ] → 7 → 8 → 9 → 10 → [ R5 → R4 → R6 ]
```

Phases 1→2→3→4 strictly sequential. R1→R3→R2 slot between Phase 6 and Phase 7 so
Phase 7 gets the real section-review UI (no stub). R5→R4→R6 run after Phase 10.
Phases 8 and 9 are independent of each other and of 7.

**Two-agent variant only:** if a second agent runs Track B truly in parallel,
revert to R1→R3→R2→R5→R4→R6 on its own track and use the Phase-7 stub handshake.

---

## 6. Manual steps (dashboard/CLI — not code-executable)

- [ ] Phase 4: apply migrations `019`–`024` in Supabase SQL Editor; record in `applied_migrations`.
- [ ] Phase 4: add `DEFAULT_TIER=pro`, `CHAT_PROVIDER=deepseek`, and `WALLET_FALLBACK_COST_PAISE` (R-C) to the Cloud Run env-vars file.
- [ ] Phase 4: confirm `DEEPSEEK_API_KEY` is readable by the Cloud Run runtime service account — chat depends on it.
- [ ] Track B: apply `025_guardrail_unextractable_log.sql` (with R1), then `026_metric_answers.sql` (with R5), in Supabase SQL Editor; record in `applied_migrations`.
- [ ] Phase 10: capture Play Console screenshots (`docs/PLAY_CONSOLE.md:46`).
- [ ] Phase 10: release build on a physical Android device.

---

## 7. Known issues this plan does not close

1. `jobs_embedding_idx` dropped (migration `013`) — stage-1 similarity is brute-force; fine at current scale, bites before ~100k rows.
2. **No dollar spend cap in code** — Apify $5 ceiling is Apify-enforced only. (The cosmetic wallet under R-B does *not* substitute for this; wiring it to a real cap is a candidate future item.)
3. `POST /pipeline/run` is fully synchronous — the all-users loop on one request; will time out as users grow.
4. Prompt injection (ADR-025) — chat + form parsing widen the surface; `wrap_untrusted` is best-effort, not a boundary.
