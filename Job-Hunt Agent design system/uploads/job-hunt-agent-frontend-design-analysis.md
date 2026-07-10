# Job-Hunt Agent — Frontend Design Analysis
### Review of Sheet B-0 (Full Screen Catalog), rev. 2026-07-08

---

## 1. Snapshot

- **17 screens** catalogued across 4 phases, in user-journey order (not build order)
- **4 screens already built**, functional, but unstyled: Home/Dashboard, Resume Upload, Profile Review, Jobs List
- **13 screens net-new** — design-ahead of the code
- **14 shared components** identified that account for the majority of every screen
- **1 design token exists today** (a placeholder indigo). Everything else — semantic color, spacing, radius, type — is a gap
- Companion to Sheet A (Frontend Status Report); keyed to repo commit `fa080a8`

This sheet is a *brief*, not a spec — its own closing section (B-6) is explicit that the deliverable is a synced Claude Design System project, not this document.

---

## 2. Where the leverage actually is

The sheet's core insight is component reuse, not screen count. A few components unlock disproportionate screen coverage:

| Component | Screens it touches | Why it's high-leverage |
|---|---|---|
| **AppShell / BottomNav** | Every screen | Structural — nothing else can be composed without it |
| **StatusPill** | Matches, Tailoring, Applications | One component, three semantic contexts (verdict / guardrail / Kanban stage) |
| **JobCard** | Jobs, Shortlist, and base for MatchCard | Reused/extended across 3 of the 4 highest-traffic screens |
| **EmptyState** | Jobs, Shortlist, Matches, Applications, Activity Log | 5 screens share one pattern |
| **FormField** | Profile, Settings, Sign In | Every text-entry surface in the app |

Validating these 5 early collapses a large share of the remaining 17-screen problem into composition work rather than new design.

---

## 3. Screen inventory by phase

| Phase | Screens | Built | New |
|---|---|---|---|
| 1 — Onboarding & Auth | 5 (Splash, Sign In/Up, Welcome, Upload Resume, Target Roles) | 0 | 5 |
| 2 — Resume → Jobs → Matches | 7 (Home, Resume Upload, Profile Review, Jobs List, Shortlist, Matches, LLM Cost Stats) | 4 | 3 |
| 3 — Tailor → Apply → Track | 4 (Tailoring Diff, Applications Kanban, Agent Activity Log, Follow-up Approval) | 0 | 4 |
| 4 — Account | 1 (Settings) | 0 | 1 |

Notably, **Phase 1 (Onboarding & Auth) is 100% undesigned** despite being the first five minutes of the product — it's scheduled for Brick 9 in the build order, but the sheet flags that designing it now avoids retrofitting later bricks around it.

---

## 4. Design token gap

Current state: one placeholder hue, no semantic layer.

Needed, per B-5a:

- **Brand/accent** — primary buttons, active nav, links
- **Success (green)** — strength chips, "apply" verdict, offer stage, guardrail-pass
- **Warning (amber)** — gap chips, "stretch" verdict, stale-application banner
- **Critical (red)** — "skip" verdict, guardrail-fail highlight, rejected stage
- **Informational (blue)** — applied/replied/interview stages, source chips
- **Neutral scale** — 5–7 steps, grey hue-biased toward brand
- **Spacing scale** — 4/8/12/16/24/32px starting point
- **Corner-radius scale**
- **Type scale** — display / heading / body / caption / mono-data

Every downstream component depends on this layer existing first — it's the correct starting point, not just a suggested one.

---

## 5. Recommended sequencing

Aligned to both the sheet's own B-6 guidance and the existing brick roadmap:

1. **Tokens** (B-5a) — one-time cost, blocks everything else
2. **AppShell, StatusPill, JobCard** — highest screens-unlocked-per-hour
3. **Remaining 11 components** — MatchCard, ScoreRing, SimilarityBar, DiffRow, KanbanColumn, ActivityLogItem, Banner, FormField, ChipInput, EmptyState, LoadingSkeleton
4. **Re-skin the 4 built screens** — cheapest wins, validates the token/component system against real, working code
5. **Design-ahead the 13 new screens**, roughly in brick order: Shortlist (Brick 4) → Matches + LLM Cost Stats (Brick 5) → Tailoring Diff (Brick 6) → Applications Kanban (Brick 7) → Agent Activity Log + Follow-up Approval (Brick 8) → Onboarding/Auth/Settings (Brick 9)

---

## 6. Open questions / risks flagged in the sheet

- **Onboarding — Upload Resume:** should "skip for now" be allowed, given matching can't run without a profile? Unresolved — needs a product decision before that screen is finalized.
- **Resume Upload (built):** no upload progress % today, only a bare spinner — noted as a known gap in the companion Sheet A.
- **Jobs List (built):** salary and posted date are already fetched from the APIs but not yet surfaced in the UI — a "free" improvement once the JobCard component is redesigned.

---

## 7. Immediate next action

Per the sheet's own B-6 section: create (or point Claude Design to) a Design System project, and start with tokens + the AppShell/StatusPill/JobCard trio — see the accompanying kickoff prompt.
