# 17 — FirstRole Frontend Requirements (v2)

**Read this before writing any code.** This file is the reconciliation layer
between the design bundle and the existing codebase. Where the design and the
code disagree, this file decides.

---

## 0. Reference files and their authority

You have been given four references. They do not carry equal weight.

| File | Authority | Use it for |
|---|---|---|
| `JobHuntAgent.dc.html` | **Pixel truth.** Every style is inline and explicit. | Exact colors, spacing, radii, type sizes, layout, motion timing. When a value is not written down anywhere else, read it here. |
| `FLUTTER_GUIDE.md` | **Implementation truth.** | Token structure, `ThemeExtension` shape, `CustomPainter` code for gauge and mascot, hold-button mechanics, animation durations and curves. Adapt this Dart, don't reinvent it. |
| `README.md` (design bundle) | **Behavior truth.** | What each screen does, interaction rules, state shape, design language intent. |
| **This file** | **Reconciliation truth.** | Wherever the design contradicts the shipped backend, or omits something the data requires. This file wins. |

The design bundle was written without sight of the backend. It is accurate
about *intent* and unreliable about *data*. Every conflict below is real and
already resolved — implement the resolution, do not re-decide it.

---

## 1. Product identity

The app is **FirstRole** (ADR-029). The design bundle and older docs call it
"Job-Hunt Agent" — that is the repo name and the server name, not the product
name. UI-facing strings say FirstRole.

One-line model: **the user approves; the agent executes.** Every consequential,
external-facing action requires a deliberate human press. This is not
negotiable and it shapes the UI: consequential actions are press-and-hold, never
a tap.

---

## 2. What already exists (do not rebuild)

The backend is substantially ahead of the design bundle's assumptions. Verified
at commit `3bad610`, migrations through `018` applied and confirmed live.

| Capability | Status |
|---|---|
| Form autofill | **Built.** `form_parser.py` (deterministic Google Forms parse, choice-membership guardrail, prefill-URL builder, answer-history reuse), `POST /forms/parse`, `POST /forms/fill`, `PATCH /forms/fills/{id}`, `form_fills` table, `form_fill_screen.dart`. |
| Résumé PDF | **Built.** `resume_pdf.py` (ReportLab, deterministic layout, one-page fit), `GET /tailor/{id}/pdf`. |
| Async long tasks | **Built.** `background_tasks` table, `GET /tasks/{id}`, `task_center.dart`. Live on `/matches/rerank`, `/tailor/{job_id}`, `/pipeline/run-mine`. |
| Client cache | **Built.** `cache_service.dart`, stale-while-revalidate over `SharedPreferences`, user-namespaced, 24h staleness. |
| Refresh throttle | **Built.** `refresh_throttle.dart`, 3s cooldown, `lastUpdatedLabel()`. |
| Onboarding state machine | **Built.** `profiles.onboarding_step` with CHECK, `student_info_screen.dart`, `profiles.employment_type` / `usn`. |
| Salary + currency | **Built.** `jobs.salary_currency`, `salary.py::infer_currency`, `Job.salaryLabel`. |
| Release signing | **Built.** Real upload keystore, R8, hard-fails without `key.properties`. |
| JD-paste résumé builder | **Built.** `POST /jobs/from-jd/parse`, `POST /jobs/from-jd`, `jd_resume_screen.dart`. |

**Confirmed absent** (`NOT FOUND` in the audit): career chat, subscription,
wallet, notification persistence, score history, `jobs.work_type` column,
per-profile target locations, dark theme, `go_router`, Riverpod, haptics.

---

## 3. Deliberate deviations from the design bundle

Implement the right column. Do not implement the design as drawn.

| # | Design says | Implement instead | Why |
|---|---|---|---|
| 1 | Kanban has **4 columns** (Saved/Applied/Interview/Offer) | **6 columns** — `saved`, `applied`, `replied`, `interview`, `offer`, `rejected` | The DB CHECK constraint has six states. Dropping two would orphan live rows. Horizontal scroll absorbs the extra width. |
| 2 | Wallet is **prepaid credits** with a working Top up | **Subscription + displayed balance.** Seeded ₹200. Top up is present but inert and clearly labelled. No payment processor. | Personal-scope app. Building payments is out of proportion. |
| 3 | Everyone sees an **"Upgrade to Pro"** upsell | **Every user is already Pro.** Card reads as an active-plan card, not an upsell. | `DEFAULT_TIER=pro`. Build the real entitlement check anyway — see §5. |
| 4 | Usage bars labelled **"GPT-4o"** | **Gemini / DeepSeek / Embeddings** | Those are the actual providers. `GET /stats/costs` returns `by_provider`. |
| 5 | Currency is **$**, salary range **$0–$200k+** | **₹ throughout.** Histogram ₹0–₹50L+. INR shows lakhs (₹28L) above ₹1L, else thousands (₹90k). | Indian market. Money is stored as integer **paise**, never float. |
| 6 | Non-INR jobs unspecified | Render the **source currency and its symbol**, never a converted figure | We have no FX source. A fake conversion is worse than an honest foreign number. |
| 7 | **5 source chips** (LinkedIn/Indeed/Unstop/Internshala/Naukri) | **11 values.** Add `adzuna`, `jsearch`, `greenhouse`, `lever`, `manual`, `jd_paste`, plus an unknown-source fallback | `jobs.source` is free text with **no CHECK constraint**. An unmapped value must render a neutral chip, not crash. |
| 8 | Filter source toggles imply **fetching** from that source | Toggles **filter the shared pool**. They never trigger a fetch. | The job pool is global and shared. Scraped sources are cron-only (§5, rule 8). Copy must not imply on-demand fetching. |
| 9 | Left **"Jump to" rail** | **Do not port.** Prototype review aid only. | Stated in the design README. |
| 10 | **Skeletons** are absent; mascot loaders everywhere | Correct — **delete** `loading_skeleton.dart` and `page_skeletons.dart` at every call site | Design language: "no skeletons." |
| 11 | Design omits **Skill Growth** and **Shortlist** | Keep both, as Profile sub-screens | Both work today. Deleting a working feature by omission is a bug, not a decision. |
| 12 | Chat greeting "Hey Aditi" | Use the profile's real `name` | Placeholder in the prototype. |

---

## 4. Screen requirements

Each row: what exists now → what must change → what data it needs.

### 4.1 Onboarding (`onboard`)

Six segments with a small agent orb across the top.

Welcome slides (growing orb + progress ring) → résumé upload (idle / uploading
ring / parsed / error) → **student vs professional fork** (one card settles, the
other recedes) → branch-specific detail form → split profile review
(résumé-parsed vs self-entered, visually distinguished) → target roles / salary
/ **locations**.

- Extends the existing `onboarding_step` machine and `student_info_screen.dart`. Do not replace them.
- New `profiles` fields required: `branch`, `grad_year`, `cgpa`, `company`, `experience_years`, `notice_period_days`, `target_locations`.
- The `onboarding_step` CHECK constraint must be widened for any new step value.
- Résumé upload is **not skippable**. Everything after the fork is.
- A force-quit must resume on the correct step.

### 4.2 Home (`home`)

Greeting + notification bell with unread count · state pills · **fit gauge** ·
dark refresh pill · "LAST UPDATED …" · top-match detail card · "New jobs today"
· "Agent activity" feed.

- **Fit gauge:** 270° arc, gradient `#F5842B → #E0B33A → #2E9E6B`, count-up 900ms easeOutCubic to `target+5`, correct-down 520ms easeInOut to target. Arc tracks the number live. `0` / `100` end labels.
- **Delta chip (+4↑):** requires real history from `GET /stats/score-history`. **Hide the chip entirely until two snapshots exist.** Never render a fabricated delta.
- **Refresh pill:** fires `POST /pipeline/run-mine` → 202 + task id → poll `GET /tasks/{id}` → agent overlay → toast. It must **not** reach any scraped source.
- **LAST UPDATED:** from the most recent snapshot, or the cache age via `lastUpdatedLabel()`.

### 4.3 Jobs (`jobs`)

Title + filter button (dot when a filter is active) + refresh · state pills ·
job cards · pull-to-refresh revealing the mascot.

- Card: role, company · location, bookmark, ₹ salary chip (mono font), source logo chip, freshness label.
- Freshness from `jobs.posted_at`, falling back to `ingested_at`. `Job.postedAtLabel` already handles the implausible-age case — keep it.
- Pull-to-refresh: mascot scales `0.45 → 1.0` with pull distance; release past ~52px triggers the overlay.
- Respects `RefreshThrottle`.

### 4.4 Jobs Filter (sheet over `jobs`)

`showModalBottomSheet`, `isScrollControlled`, radius-24 top corners.

Horizontally-scrolling source cards with brand-color logo tiles · work-type
segmented control (Any / Remote / Hybrid / Onsite) · ₹ salary histogram (17
bars) + range slider · location chips with landmark glyphs (Remote=home,
Hyderabad=Charminar, Bengaluru=Vidhana Soudha, Delhi=India Gate, Mumbai=Gateway,
Pune=pin) · footer Clear all / **Show N jobs**.

- **Blocked on `jobs.work_type`**, which does not exist. It is computed at ingestion by `job_filter.py::is_remote` and then **discarded**. Migration `019` must persist it and backfill.
- Histogram buckets and the live count come from a new `GET /jobs/facets`. Pure SQL, no LLM.
- Filter state is one Riverpod provider shared by the sheet, the list, and the count badge.

### 4.5 Matches (`matches`)

Title + "Rerank now" · state pills · match cards (small fit ring, role, company,
₹ salary, NEW badge). **No hero gauge** — deliberately removed.

- NEW badge from `matches.ranked_at`.
- Rerank → `POST /matches/rerank` (202) → overlay → toast.

### 4.6 Match detail (`matchDetail`)

Fit ring · role / company / ₹ salary / source · JD highlights · matched vs gap
keyword chips · "not tailored yet" nudge · footer: "Tailor résumé for this JD" +
hold-to-apply-as-is.

- Matched chips from `matches.strengths`, gap chips from `matches.gaps`. Both already stored.

### 4.7 Tailor flow (`tailor`)

JD source (paste or from match) → tailoring animation (orb + particles +
checklist) → bullet-by-bullet diff → generating → preview + Download PDF /
hold-to-apply.

- Both entry points exist: `POST /tailor/{job_id}` and the JD-paste path.
- Diff shows strikethrough original → tailored, added-keyword chips, per-bullet Accept, **guardrail flags always visible**, hold-to-approve-all.
- Download via `GET /tailor/{id}/pdf`.
- The tailoring call is 202 + poll. The animation is driven by real task state, not a fixed timer.
- **This flow is being substantially reworked in parallel — see `19-resume-quality-plan.md`.** The diff screen gains section-level reorder/drop review and a metric-prompt affordance. Build the UI against that plan, not against the current bullet-only diff.

### 4.8 Apply via form (`gform`)

Paste form link → **in-app WebView** with fields filling and green ticks → JD
popup → tailoring → preview + Download, with a "you submit, the agent won't"
handoff banner.

- Backend exists. This is wiring plus a WebView.
- **JD popup logic:** if `POST /forms/parse` returned a job description (it extracts one when the description is ≥600 chars), use it silently. If not, popup asks the user to paste a JD. Then offer "Create résumé" → existing tailoring pipeline → preview + download.
- **Hard constraint:** Google Forms prefill **cannot populate a file-upload question**, and file-upload questions require the respondent to be signed into a Google account. We fill every fillable field; the user attaches the PDF and submits. **The copy must say this plainly.** Do not write UI that promises full autofill.
- **Do not inject into the WebView DOM** as a workaround. It breaks on every Google reskin and is a worse posture than the published prefill mechanism.
- Answer reuse already exists in `form_parser.py`. Verify it keys per-question, not per-form; extend if not.
- **Never persist** government ID, DOB, bank details, passwords, or anything matching those patterns into `form_fills.answers`. Use once, discard.

### 4.9 Track (`track`)

Six-column Kanban, drag cards between columns, dropping in Offer fires
celebration.

- `Draggable` / `DragTarget`, snap to nearest column on release.
- Persist via `PATCH /applications/{id}`. Optimistic update, revert on failure.
- Offer → confetti + `heavyImpact`, once.

### 4.10 Career chat (`chat`)

Back / "Career agent" / new-chat · mascot + "Hey {name}, how can I help your
career?" · horizontally-scrolling example chips · user/agent bubbles · typing
indicator · input bar with model chip + send.

- Fully new. `POST /chat` (202 + poll), `chat_threads` + `chat_messages`.
- **Grounded:** retrieve the caller's profile, top ~10 matches, and application states; inject as context; hard-instruct against asserting anything outside that context. Same anti-fabrication posture as tailoring.
- Provider: DeepSeek via `settings.chat_provider`.
- Schema-validated, logged to `llm_calls`, rate-limited.

### 4.11 Profile (`profile`)

Avatar card (name, role, email, **résumé-completion bar** with hatched remainder
+ %) · plan card · 3-stat row (Applied / Interviews / Offers) · grouped list (My
résumé, Saved jobs, Notifications, Ask the agent, Apply via form, Agent wallet,
Skill growth) + dark-mode toggle · About + Delete-account rows · Sign out.

- Completion % computed in Python from populated profile fields. Not an LLM guess.
- Stats counted from `applications`. Not an LLM guess.

### 4.12 Agent wallet (`cost`)

Gradient card (₹200 balance, "≈N actions left", Top up / Manage) · "Used this
month" per-provider bars with token count + ₹ · recent activity.

- Balance from `profiles.wallet_balance_paise`.
- **"Actions left" is derived** from the trailing 30-day mean cost per action in `llm_calls`. Never a hardcoded number.
- Bars from `GET /stats/costs` `by_provider`.

### 4.13 Notifications (`notifs`)

List with type icon, title/body, time, unread dot; one actionable "Send
follow-up" row.

- Fully new table. Push is currently fire-and-forget with no persistence.
- The daily pipeline writes a row whenever it sends a push.

### 4.14 About (`about`)

Floating icon-tile cluster around a central mascot tile · logo · version card +
release notes · "Our mission" card · Terms / Privacy / Credits links. Static.

### 4.15 Account deletion (`deleteacc`)

"Hey, wait! Before you go…" · broken-heart-over-card illustration · "Keep my
account free" (primary) / "Delete account permanently" (critical).

- `DELETE /account` cascades every profile-scoped table, then deletes the Supabase auth user.
- Destructive path is a **`HoldButton`**, never a tap.

### 4.16 Global overlays

Full-screen agent overlay (spinning ring + core + drift particles + phase text +
source chips lighting up) · bottom agent toast · celebration modal.

- The overlay is driven by real `GET /tasks/{id}` polling, not a fixed animation.
- Source chips light up per source as ingestion reports them — degrade gracefully when the task returns no per-source detail.

---

## 5. Non-negotiable constraints

1. **Secrets server-side only.** The client holds the Supabase URL and anon key. Nothing else.
2. **LLMs handle language; code handles logic.** Scores, state transitions, counts, money, percentages, diffs — all Python.
3. **Every LLM output is schema-validated**, retried exactly once with the error appended, then failed gracefully.
4. **The anti-fabrication guardrail is sacred.** Its *mechanism* changes under `19-resume-quality-plan.md`; its *purpose* does not. Nothing untraceable ever reaches a résumé unflagged.
5. **Every LLM call is logged** to `llm_calls` with the provider that actually served it.
6. **No auto-submit.** Applications, emails, form submissions all require a deliberate human action.
7. **Consequential actions are `HoldButton`**, never a plain tap.
8. **Scraping stays cron-only.** The structural split in `daily_pipeline.py` — `_refresh_scraped_if_due()` reachable only from `run_daily_pipeline_for_all()`, never from `_refresh_and_backfill()` — must survive untouched. No UI control may reach a paid source.
9. **Never persist sensitive form answers.**
10. **Widgets read tokens, never a literal hex or px.**
11. **All money in ₹, stored as integer paise.**
12. **Do not regress** the 202+poll pattern, SWR cache, refresh throttle, rate limits, SSRF guard, or PDF safety bounds.

---

## 6. Out of scope

- Payment processing of any kind.
- iOS. No APNs key, `firebase_options.dart` throws for every non-Android platform.
- ATS platforms beyond Google Forms (Greenhouse / Lever / Workday apply pages). Those are different parsers with no prefill mechanism.
- Changing scraping policy, cadence, or source list.
- Anything that makes a paid source reachable from the UI.
