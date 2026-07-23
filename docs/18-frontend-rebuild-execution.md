# 18 — FirstRole Frontend Rebuild v2 — Execution Prompt

**Companion to `17-frontend-requirements.md`.** That file is the *what*; this is
the *how, in what order, and how you know a phase is done*.

**Baseline:** commit `3bad610`, clean working tree, migrations through `018`
applied and verified. Branch from `main`.

---

## How to work

- Work **one phase at a time**. Stop at each phase boundary and report before continuing.
- **Merge to `main` at every phase boundary.** Do not accumulate a large uncommitted tree — this project has been bitten by that before.
- Read `17-frontend-requirements.md` §3 before any screen work. Twelve documented deviations from the design bundle are already decided; implementing the design as drawn is a bug.
- When the design bundle and the shipped backend conflict and §3 does not cover it, **stop and ask.** Do not silently pick one.
- `flutter analyze` and `pytest` stay green at every boundary. No phase merges red.
- Every new backend endpoint gets a pytest file in the same phase that adds it.

## Golden rules (hard constraints, every phase)

Restated from `17-frontend-requirements.md` §5 — they are not optional and not
subject to convenience:

1. Secrets server-side only.
2. LLMs handle language; code handles logic.
3. Every LLM output schema-validated, retried once, failed gracefully.
4. The anti-fabrication guardrail is sacred.
5. Every LLM call logged with its real provider.
6. No auto-submit, ever.
7. Consequential actions are `HoldButton`, never a tap.
8. Scraping stays cron-only — no UI control may reach a paid source.
9. Never persist sensitive form answers.
10. Widgets read tokens, never a literal hex or px.
11. All money in ₹, stored as integer paise.
12. Do not regress 202+poll, SWR cache, refresh throttle, rate limits, SSRF guard, PDF safety bounds.

---

## Phase 1 — Documentation reconciliation

The audit found **20 contradictions** between documentation and code. A coding
agent reading `CLAUDE.md` today will refuse legitimate scraping work and write
against the wrong host. Fix this first; it is cheap and it unblocks every later
phase.

**Tasks**
- Fix Drifts 1–20 exactly as quoted in `docs/audits/CODEBASE_STATE_2026-07.md` §10.2:
  - Hosting → **Cloud Run** (`CLAUDE.md`, `01-architecture-and-tech-stack.md`, `12-deployment-and-infra.md`).
  - Embedding model → `gemini-embedding-001` (`BRICKS.md`, `CLAUDE_PROJECT_SETUP.md`).
  - LLM providers → the real `_TASK_PROVIDERS` split, not "Gemini for everything".
  - Scraping policy → ADR-003 v2 wording, replacing every "no scraping, ever".
  - Source list → all nine fetchers, including Internshala and Unstop.
  - Release signing → real upload keystore; delete the debug-keystore TODO references.
  - `MAX_JOB_AGE_DAYS` → documented default 10, not 60.
- Add `**Date:**` lines to ADRs 010–028 (19 consecutive entries missing them), inferred from `git log` commit dates.
- Regenerate `docs/claude-project-knowledge/` from current code — the whole pack predates migration `009`.
- Rewrite `MANUAL_STEPS.md` §3 from Render to Cloud Run (`git push` deploys nothing now).
- Write a real root `README.md`. None exists.

**Acceptance:** grep for `Render`, `text-embedding-004`, `no scraping`,
`onrender.com` — every surviving hit is a deliberate historical reference inside
an ADR body, never a live instruction.

---

## Phase 2 — Foundation: theme, router, state, haptics

### 2a — Tokens and dark mode
- New `theme/app_colors.dart` — `AppColors extends ThemeExtension<AppColors>`, light and dark sets verbatim from `FLUTTER_GUIDE.md` §1, plus `gaugeGradient`.
- New `theme/app_theme.dart` — `appLight` / `appDark` per §2. Inter body, JetBrains Mono numerals, Playfair Display hero score, via `google_fonts`.
- `MaterialApp` gains `darkTheme` and `themeMode`. Mode persists through the existing `CacheService` — **do not add a second storage layer.**
- Keep `theme/app_tokens.dart` for now so existing screens compile. It is deleted in Phase 10.

### 2b — go_router
- Add `go_router`. Route table covering all 16 design screens plus retained ones.
- Five tab routes under a `StatefulShellRoute` so tab state survives switching (replaces the current `IndexedStack`).
- **OAuth deep link — the one thing most likely to break.** `com.jobhuntagent.jobhunt_agent://login-callback/` currently lands in `AuthGate`; under go_router it hits the router. Needs an explicit route plus a `redirect` keyed on Supabase auth state via `refreshListenable`. **Do not change the scheme** — ADR-031 documents that it must not match `applicationId`.
- Replace all 30 imperative `Navigator.push` calls across 12 screens.
- Every sub-screen: working back chevron **and** correct Android system-back.

### 2c — Riverpod
- Add `flutter_riverpod` (no codegen). Wrap in `ProviderScope`.
- Convert `MatchFeed` → `AsyncNotifier`, `TaskCenter` → `Notifier`. These two hand-rolled singletons are the most likely casualties of go_router's rebuild semantics — convert them before building on top.
- New screens use Riverpod from the start; existing screens migrate opportunistically, not in a big bang.

### 2d — Haptics
- New `services/haptic_service.dart` — single wrapper over `HapticFeedback`, reads a Settings toggle, respects the system haptic setting.

| Event | Feedback |
|---|---|
| Tab switch, chip/filter toggle | `selectionClick` |
| Hold-button start / complete | `lightImpact` / `mediumImpact` |
| Kanban pickup / drop | `lightImpact` / `selectionClick` |
| Celebration | `heavyImpact`, once |
| Guardrail flag appears | `lightImpact` |
| Background task done | `lightImpact` |
| Error | `mediumImpact` |

**Nothing during loading. Nothing on scroll. Nothing repeating.** Flutter offers
no continuous or waveform haptic without platform channels, and Android quality
varies enormously by device — discrete events are the only thing that feels
consistent.

**Acceptance:** `flutter analyze` clean; all 27 existing screens reachable via
the router; back navigation correct from every sub-screen; dark mode toggles and
survives restart; **Google OAuth sign-in completes and lands on the right
screen**; haptics fire on tab switch and nowhere else yet.

---

## Phase 3 — Signature widget library

Build against `FLUTTER_GUIDE.md` §3–§8. No screen work in this phase.

| Widget | Spec |
|---|---|
| `fit_gauge.dart` | 270° gradient arc; count-up 900ms easeOutCubic to `target+5`; correct-down 520ms easeInOut. Arc tracks the number live. |
| `agent_mascot.dart` | `CustomPainter`. Bob 2600ms, blink 3600ms. |
| `agent_orb.dart` | Radial-gradient breathing circle, 3000ms, scale 1↔1.05. |
| `hold_button.dart` | 1100ms fill, 200ms spring-back, haptic on start and complete. |
| `source_chip.dart` | **11 sources** + unknown fallback. `jobs.source` has no CHECK constraint — an unmapped value must render neutral, never crash. |
| `agent_overlay.dart` | Full-screen; driven by real `GET /tasks/{id}` polling, not a fixed timer. |
| `agent_toast.dart` | Replaces `task_toast.dart`. |
| `celebration_modal.dart` | Confetti, 1600–2900ms easeIn. |
| `mascot_loader.dart` | Mascot + caption. Replaces `loading_skeleton.dart` and `page_skeletons.dart` at every call site. |
| `hatched_progress.dart` | Completion bar with diagonal hatched remainder. |

**Acceptance:** a debug-only gallery route renders every widget in both themes;
gauge timings match spec; no widget contains a literal hex or px.

---

## Phase 4 — Backend: schema and endpoints

Six migrations, `019`–`024`. Migration `018` is confirmed as the current head.

| Migration | Adds |
|---|---|
| `019_jobs_work_type.sql` | `jobs.work_type text` CHECK in `('remote','hybrid','onsite')`, nullable. Backfill using the same logic as `job_filter.py::is_remote`. **Currently computed at ingestion and discarded** — the filter sheet cannot work without it. |
| `020_score_snapshots.sql` | `score_snapshots` (`id`, `profile_id` FK cascade, `top_fit_score int`, `avg_fit_score real`, `match_count int`, `captured_at timestamptz`). Index `(profile_id, captured_at desc)`. RLS owner-read. |
| `021_profile_onboarding_fields.sql` | `profiles.branch`, `grad_year`, `cgpa`, `company`, `experience_years`, `notice_period_days`, `target_locations jsonb default '[]'`. Widen the `onboarding_step` CHECK for any new step value. |
| `022_subscription_and_wallet.sql` | `profiles.subscription_tier text not null default 'pro'` CHECK in `('free','pro')`; `subscription_status`; `subscription_period_end`; `wallet_balance_paise bigint not null default 20000`. Backfill all existing rows. |
| `023_notifications.sql` | `notifications` (`id`, `profile_id` FK cascade, `kind`, `title`, `body`, `action_type`, `action_ref uuid`, `read_at`, `created_at`). Index `(profile_id, created_at desc)`. RLS owner-read. |
| `024_chat.sql` | `chat_threads` (`id`, `profile_id` FK cascade, `title`, `created_at`, `updated_at`); `chat_messages` (`id`, `thread_id` FK cascade, `role` CHECK in `('user','assistant')`, `content`, `created_at`). RLS owner-read on both. |

**New endpoints**

| Method | Path | Notes |
|---|---|---|
| GET | `/stats/score-history` | Last 30 snapshots. Powers the delta chip and "LAST UPDATED". |
| GET | `/jobs/facets` | ₹ salary histogram buckets, work-type counts, location counts, total for "Show N jobs". Pure SQL, no LLM. |
| GET | `/notifications` | Paginated; unread count in the envelope. |
| PATCH | `/notifications/{id}/read` | |
| POST | `/notifications/read-all` | |
| POST | `/chat` | **202 + task id.** Grounded career chat. |
| GET | `/chat/threads`, `/chat/threads/{id}` | History. |
| GET | `/subscription` | Tier, status, period end. |
| GET | `/wallet` | Balance in paise + `actions_remaining`, derived from the trailing 30-day mean cost per action in `llm_calls`. **Never hardcoded.** |
| DELETE | `/account` | Cascade every profile-scoped table, then delete the Supabase auth user. `HoldButton` only. |

**Changes to existing backend code**
- `daily_pipeline.py::_process_profile` writes one `score_snapshots` row per run.
- `daily_pipeline.py` writes a `notifications` row whenever it sends a push.
- `job_ingestion.py` persists `work_type` instead of discarding it.
- New `services/entitlements.py` — `require_tier(profile, 'pro')`. Real check; passes for everyone while `DEFAULT_TIER=pro`. Build the seam now so flipping it later is config, not a refactor.
- New `services/chat.py` — retrieves profile + top ~10 matches + application states, injects as context, hard-instructs against asserting anything outside it. Schema-validated, logged, rate-limited.

**Security fixes to land here** (found in the audit; you are in these files anyway)
- `POST /forms/parse` takes a plain `BaseModel` with an uncapped `url: str` and **does not call `_assert_public_url`**. Move it to `StrictModel` and route `form_parser.py::fetch_form_html` through the SSRF guard.
- Add rate limits to `/forms/parse`, `/forms/fill`, `/applications/{id}/followup`, `/stats/skill-growth` — all four make LLM calls with none today.

**Acceptance:** every new endpoint has a pytest file; `pytest` green; cross-user
access returns 404 on all new routes; `/wallet` derives its number from real
`llm_calls` rows; a test flips `DEFAULT_TIER` to `free` and asserts a 402.

---

## Phase 5 — Core tabs

Rebuild the five bottom-nav screens on the Phase 3 widgets. Per-screen detail in
`17-frontend-requirements.md` §4.2, §4.3, §4.5, §4.9, §4.11.

**Acceptance:** all five render populated / loading / empty / error; the gauge
shows a real delta **or hides itself**; Kanban drag persists via `PATCH
/applications/{id}` with optimistic update and revert-on-failure; every
consequential action is a `HoldButton`; no skeleton widget survives on these
screens.

---

## Phase 6 — Filter sheet and onboarding

Detail in `17-frontend-requirements.md` §4.4 and §4.1.

**Acceptance:** filter changes update the count without a full refetch; a
force-quit resumes on the correct onboarding step; both fork branches write
their fields and reach `done`; target locations persist per-profile; the filter
sheet triggers **no** fetch from any source.

---

## Phase 7 — Match detail, tailor flow, form fill

Detail in `17-frontend-requirements.md` §4.6, §4.7, §4.8.

**Coordinate with `19-resume-quality-plan.md`** — the tailor flow's diff screen
gains section-level review and metric prompting. If that plan's Phase R2 has
landed, build the new UI. If not, build the bullet-only diff and leave the
section-review slot stubbed.

**Acceptance:** a real Google Form parses, prefills, and opens in-app; a form
with a file-upload question degrades with honest copy; a second fill of the same
form reuses prior answers; guardrail flags visible in the diff; PDF downloads.

---

## Phase 8 — Career chat

Detail in `17-frontend-requirements.md` §4.10.

**Acceptance:** answers a profile-specific question correctly ("what roles am I
closest to?"); **refuses to invent** a job, skill, or employer not in context;
history survives restart; the call appears in `GET /stats/costs` under the right
provider.

---

## Phase 9 — Wallet, notifications, about, deletion

Detail in `17-frontend-requirements.md` §4.12, §4.13, §4.14, §4.15.

**Acceptance:** the wallet number moves as real LLM spend accrues; notifications
mark read and persist; deletion removes every row across all profile-scoped
tables **and** the auth user, verified by query.

---

## Phase 10 — Cleanup and verification

- Delete `app_tokens.dart`, `loading_skeleton.dart`, `page_skeletons.dart`, and any superseded screen.
- Give **Skill Growth** and **Shortlist** a home as Profile sub-screens. Both work today; deleting them by omission is a bug.
- Widget tests for the new signature widgets — there are currently tests for 2 of 27 screens.
- `flutter analyze` clean, including the `anonKey → publishableKey` deprecation.
- **On-device verification** — the standing gap since ADR-007. Sign-in, push, upload, WebView, Kanban drag, haptics, both themes, on a real Android device.
- New ADRs: go_router adoption, Riverpod adoption, subscription/wallet model, chat provider choice, haptic policy.

---

## Execution order

Phases 1 → 2 → 3 → 4 strictly in sequence.

From Phase 5: 5, 6, 7 may interleave. Phases 8 and 9 are independent of each
other and of 7. Phase 10 last.

`19-resume-quality-plan.md` runs on its own track and only touches Phase 7.

---

## Manual steps (dashboard/CLI — not code-executable)

- [ ] Phase 4: apply migrations `019`–`024` in the Supabase SQL Editor, and record them in `applied_migrations`.
- [ ] Phase 4: add `DEFAULT_TIER=pro` and `CHAT_PROVIDER=deepseek` to the Cloud Run env-vars file.
- [ ] Phase 4: confirm `DEEPSEEK_API_KEY` is readable by the Cloud Run runtime service account — chat depends on it.
- [ ] Phase 7: no new secrets; `webview_flutter` needs no key.
- [ ] Phase 10: capture Play Console screenshots (`docs/PLAY_CONSOLE.md:46`, still open).
- [ ] Phase 10: release build on a physical device.

---

## Known issues this plan does not address

1. **`jobs_embedding_idx` is dropped** (migration `013`) — stage-1 similarity is a brute-force scan. Fine at current scale; will bite before ~100k rows.
2. **No dollar spend cap in code.** The Apify $5 ceiling is enforced by Apify alone. Deserves its own item.
3. **`POST /pipeline/run` is fully synchronous** — the entire all-users loop on one request. Deliberate for a cron caller, but it will time out as user count grows.
4. **Prompt injection** remains a documented residual risk (ADR-025). Chat and form parsing both widen the surface; `wrap_untrusted` is best-effort, not a boundary.
