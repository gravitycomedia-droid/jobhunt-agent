# Job-Hunt Agent — Design System

An AI job-search assistant (Flutter, Android + iOS, **portrait-first**): matches a resume
against live postings, tailors resume bullets per application, and tracks the pipeline to offer.
This project is the synced design system — **tokens first, then shared components**, ahead of
composing the 17-screen catalog.

Source brief: `uploads/job-hunt-agent-frontend-design-analysis.md` (keyed to repo commit `fa080a8`).

---

## Status (this pass)

**Foundation + all 14 shared components built and rendering.**

- ✅ **Tokens** — color (brand + 4 semantic ramps + neutral), typography, spacing, radius, elevation, fonts. Entry point: `styles.css`.
- ✅ **Core trio** — `AppShell`/BottomNav, `StatusPill`, `JobCard` (+ shared `Icon`).
- ✅ **Remaining 11** — `ScoreRing`, `SimilarityBar`, `DiffRow`, `MatchCard`, `KanbanColumn`, `ActivityLogItem`, `Banner`, `FormField`, `ChipInput`, `EmptyState`, `LoadingSkeleton`.
- ⏳ **Screens** — deferred until components are validated (next: re-skin the 4 built screens, then design-ahead Shortlist → Matches → Tailoring Diff → Applications Kanban).

---

## Visual foundations

- **Brand / accent** — violet-leaning indigo (`--brand-600 #5647E0`). Deliberately violet so it never collides with the **Informational blue** used for pipeline stages & source chips. *(This is the refinement of the placeholder indigo — flagged for your sign-off.)*
- **Semantic color** — success (green): apply / offer / guardrail-pass · warning (amber): stretch / stale / gap · critical (red): skip / fail / rejected · info (blue): applied / replied / interview / source chips. Each ramp exposes `--<role>-fill` (solid), `-text` (on soft bg), `-soft` (tinted bg), `-border`.
- **Neutral** — grey hue-biased ~275° toward brand. `bg` = 50, `surface` = white, `border` = 200, text 900/600/500.
- **Type** — `Plus Jakarta Sans` (display→caption) + `JetBrains Mono` (scores, salary, token cost). Roles: display 32 · heading 22 · title 16 · body 15 · caption 13 · label 11 · mono-data 14.
- **Spacing** — 4px grid; core 4/8/12/16/24/32.
- **Radius** — cards 16, buttons/tiles 12, inputs 8, chips/pills full.
- **Elevation** — restrained; e1 card → e4 sheet, shadow tinted with the neutral (indigo) hue.

## Content tone
Warm-professional, second person ("your matches today"), sentence case, no emoji.
Data (%, salary, cost) always in mono for scannability.

## Iconography
No icon assets ship in the source app, so the `Icon` primitive substitutes **Lucide** (ISC)
line glyphs, 24×24, stroke-based, `currentColor`. **Flag:** swap for your own set if the app standardizes on one.

---

## Manifest

- `styles.css` — entry point (import list only)
- `tokens/` — `colors · typography · spacing · radius · elevation · fonts`
- `components/`
  - `icons/Icon` · `navigation/AppShell` · `feedback/{StatusPill,Banner,EmptyState,LoadingSkeleton}` · `cards/{JobCard,MatchCard,ActivityLogItem}` · `dataviz/{ScoreRing,SimilarityBar,DiffRow}` · `kanban/KanbanColumn` · `forms/{FormField,ChipInput}`
  - `core-trio.card.html` · `data-composite.card.html` · `forms-feedback.card.html` — rendered specimens
- `guidelines/` — foundation specimen cards (Colors / Type / Spacing / Radius+Elevation)

Each component ships `<Name>.jsx` (React reference), `<Name>.d.ts` (props contract), `<Name>.prompt.md` (usage).

## Open questions (from the brief, need product calls)
1. **Accent color** — keep refined indigo `#5647E0`, or nudge hue/saturation?
2. Onboarding "skip resume upload for now" — allowed, given matching needs a profile?
3. Kanban stage set confirmed as New / Applied / Replied / Interview / Offer / Rejected?
