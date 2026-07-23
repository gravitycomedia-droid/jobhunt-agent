# Handoff: Job-Hunt Agent — Mobile App

## Overview
An AI job-hunting agent app. The agent searches five job boards while you sleep, ranks your fit, tailors résumés, drafts follow-ups, and auto-fills application forms — but **every consequential action (submit, send, approve) waits for a deliberate human press**. The signature idea is "motion as agency": the agent drifts, shimmers and works ambiently; the user presses-and-holds to commit.

## About the Design Files
The file in this bundle (`JobHuntAgent.dc.html`) is a **design reference created in HTML** — an interactive prototype showing the intended look, motion and behavior. It is **not production code to copy directly**.

The target is **Flutter** (the user is implementing in a Flutter project, using an agentic IDE such as Google Antigravity). Recreate these designs as idiomatic Flutter: `ThemeData`/`ColorScheme` for tokens, standard widgets, `CustomPainter` for the gauges/mascot, and `AnimationController`/`Tween` for motion. `FLUTTER_GUIDE.md` in this folder contains ready-to-adapt Dart code for the tokens, the signature widgets, and the animations.

## Fidelity
**High-fidelity.** Final colors, typography, spacing, radii and interactions are all specified. Recreate pixel-close. Where a value isn't listed, read it from the HTML file (every style is inline and explicit).

## Design language (read first)
- **Precision numerals**: every number a user should trust (fit scores, salaries, token counts, dates, costs) is set in a **monospace** face (`JetBrains Mono`). Prose/UI is a humanist sans (`Inter`). The big hero score uses a display serif (`Playfair Display`).
- **Restraint**: one accent (indigo), warm off-white paper, one-to-two surface greys. No gradients except the wallet card and the score gauge arc. No emoji except the celebration modal.
- **Agent motif**: a rounded-head robot **mascot** (blinking eyes, antenna, bob) represents the agent in loading states, pull-to-refresh, chat and about. A softer **orb** (breathing gradient circle) is the same agent in onboarding/tailoring.
- **Motion as agency**: consequential actions are **press-and-hold** with a fill that sweeps left→right and completes at ~1.1s; ambient agent work is spinners/shimmer/drift.

## Screens / Views
Router is a single `screen` string. Bottom-nav screens: `home, jobs, matches, track, profile`. Others are pushed/overlaid.

1. **Onboarding** (`onboard`) — 3 welcome slides (growing orb + progress ring) → résumé upload (idle / uploading ring / parsed / error) → user-type fork (Student vs Professional card, one settles & the other recedes) → branch-specific detail form → split profile review (résumé-parsed vs. self-entered) → target roles/salary/locations. 6-segment progress + small agent orb across the top.
2. **Home** (`home`) — greeting + notification bell; state pills (Populated/Loading/Empty); **CRED-style fit gauge** (270° gradient arc orange→amber→green, delta chip "+4↑", big Playfair number that counts up, overshoots, and corrects to 92; `0`/`100` end labels; dark "refresh now" pill; "LAST UPDATED …" footer); top-match detail card with "Tailor résumé & apply"; "New jobs today" list; "Agent activity" feed.
3. **Jobs** (`jobs`) — title + filter button (dot when active) + refresh; state pills; job cards (role, company·loc, bookmark, salary chip, source logo chip, freshness). **Pull-to-refresh reveals the bot mascot** scaling in. (Sources are configured in the Filter sheet, not on this page.)
4. **Jobs Filter** (sheet over `jobs`) — Airbnb-style bottom sheet: horizontally-scrolling **source cards with brand-color logo tiles** (LinkedIn/Indeed/Unstop/Internshala/Naukri); Work type segmented (Any/Remote/Hybrid/Onsite); **Salary range** histogram + range slider ($0–$200k+); **Locations** chips with landmark glyph icons (Remote=home, Hyderabad=Charminar, Bengaluru=Vidhana Soudha, Delhi=India Gate, Mumbai=Gateway, Pune=pin); footer Clear all / Show N jobs.
5. **Matches** (`matches`) — title + "Rerank now"; state pills; list of match cards (fit ring with score, role, company, salary, NEW badge). No hero gauge (removed).
6. **Match detail** (`matchDetail`) — fit ring, role/company/salary/source, JD highlights, matched vs. gap keyword chips, "not tailored yet" nudge; footer: "Tailor résumé for this JD" + hold-to-apply-as-is.
7. **Tailor flow** (`tailor`) — JD source (paste/from match) → tailoring animation (orb + particles + checklist) → bullet-by-bullet diff (strikethrough original → tailored, added-keyword chips, per-bullet Accept, one guardrail flag, hold-to-approve-all) → generating → résumé preview + Download PDF / hold-to-apply.
8. **Apply via form** (`gform`) — paste form link → in-app WebView mock auto-fills fields with green ticks → popup offering to tailor résumé (uses JD from form or asks) → tailoring → preview + Download, with a "you submit, the agent won't" handoff banner.
9. **Track** (`track`) — 4-column Kanban (Saved/Applied/Interview/Offer); **drag cards between columns**; dropping in Offer fires celebration.
10. **Career chat** (`chat`) — Copilot-style: back / "Career agent" / new-chat; mascot + "Hey Aditi, how can I help your career?"; horizontally-scrolling example-question chips (tap to send); user/agent bubbles; typing indicator; input bar with "Agent" model chip + send.
11. **Profile** (`profile`) — avatar card (name, role, email, **résumé-completion bar** with hatched remainder + %); "Upgrade to Pro" accent card; 3-stat row (Applied/Interviews/Offers); grouped list (My résumé, Saved jobs, Notifications, Ask the agent, Apply via form, Agent wallet) + Dark-mode toggle; About + Delete-account rows; Sign out.
12. **Agent wallet** (`cost`) — gradient prepaid card (balance $14.82, "≈3,140 actions left", Top up / Manage); "Used this month" with per-model bars (GPT-4o, Embeddings, Re-ranking, Form parsing) each with token count + $; recent-activity list.
13. **Notifications** (`notifs`) — list with type icon, title/body, time, unread dot; one actionable "Send follow-up".
14. **About** (`about`) — floating icon-tile cluster around a central mascot tile; logo "Job-Hunt Agent", version card + release notes, "Our mission" card, Terms/Privacy/Credits links.
15. **Account deletion** (`deleteacc`) — Revolut-style "Hey, wait! Before you go…", broken-heart-over-card illustration, "Keep my account free" (primary) / "Delete account permanently" (critical).
16. **Global overlays** — full-screen agent overlay (fetch/rerank: spinning ring + core + drift particles + phase text + source-logo chips lighting up); bottom agent toast (done state); celebration modal (confetti + emoji).

## Interactions & Behavior
- **Navigation**: bottom-nav pill switches the 5 primary screens; a floating chat FAB sits above the nav on the right; sub-screens use a back chevron. A left "Jump to" rail exists only in the prototype for review — **do not port it**.
- **Score reveal** (Home): on entering Home / pressing refresh → brief scan (3 pulsing dots) → number counts 0→~97 (ease-out, 900ms) → corrects to 92 (ease-in-out, 520ms); the arc fill tracks the number live.
- **Press-and-hold** (submit/apply/approve): fill grows 0→100% over 1100ms; releasing early animates it back (200ms); completing fires the action + celebration. Never a plain tap for these.
- **Pull-to-refresh** (Jobs): drag from top; mascot scales `0.45→1.0` with pull distance; release past ~52px triggers the fetch overlay.
- **Kanban drag**: pointer-drag a card; on release it snaps to the nearest column; Offer column → celebration.
- **Filter**: toggling sources/work-type/salary/locations updates the "Show N jobs" count; Apply runs the fetch overlay then shows results; nav closes the sheet.
- **Chat**: tapping an example chip or send appends a user bubble, shows typing (~1.3s), then a canned agent reply keyed to the question.
- **Loading**: **no skeletons** — every loading state shows the bot mascot scene + caption. Empty/error states use line illustrations / the dizzy-bot error scene.
- **Theme**: light/dark toggle (Profile row and prototype rail); everything is driven by tokens so both themes are automatic.

## State Management
Single screen router + per-feature state objects (mirror the prototype's `state`):
- `theme` ('light'|'dark'), `screen`
- `onb` {phase, slide, upload, pct, userType, form fields…}
- `homeState`/`jobsState`/`matchesState` ('populated'|'loading'|'empty'|'error')
- `scorePhase` ('scan'|'count'|'done') + `scoreVal`
- `sources{}` (per-board on/off), `bookmarks{}`, `filter{workType,salary,locs,active,open}`
- `apps[]` (kanban stage per card), `notifs[]`
- `tailor{step,accepted{}}`, `gform{step,filled,popup}`, `chat{msgs[],typing}`
- `agentFull` (overlay), `hold{key,progress}`, `celebrate`
Data fetching: all mocked here. Real endpoints implied (job fetch, ranking, tailoring, form-parse, wallet) — see "Backend notes".

## Design Tokens
See `FLUTTER_GUIDE.md` for the exact `ColorScheme`. Raw values:

**Light** — ink `#14141C`, ink-soft `#5B5B66`, ink-faint `#9A9AA3`, paper `#FAFAF9`, surface `#FFFFFF`, surface-2 `#F4F4F3`, accent `#5750E8`, accent-soft `rgba(87,80,232,.10)`, border `#E7E7EA`, success `#2E9E6B`, warning `#B9852F`, critical `#D2544B`, info `#4B78C9`.

**Dark** — ink `#F2F2F5`, ink-soft `#A7A7B2`, ink-faint `#6A6A76`, paper `#0E0E13`, surface `#17171F`, surface-2 `#1E1E28`, accent `#7A73FF`, accent-soft `rgba(122,115,255,.15)`, border `#26262F`, success `#3FB57F`, warning `#D6A24E`, critical `#E56A61`, info `#6E97DE`.

**Gauge arc gradient**: `#F5842B` → `#E0B33A` → `#2E9E6B`.

**Radii**: chips 8–9, cards 14–18, sheets 24 (top corners), pill nav 26, buttons 13–15, full circles for avatars/FAB.
**Spacing**: base grid of 4; screen padding 18–20; card padding 14–20; gaps 6/8/10/12.
**Type scale**: 10–12 (mono labels/meta), 13.5–15 (body/buttons), 16–24 (titles), 46–82 (hero score). Weights 400/500/600; 700/800 for the serif score.
**Shadows**: cards `0 6–14px 18–34px -8…-14px rgba(0,0,0,.3–.4)`; FAB/accent glows use `color-mix` of accent.

**Currency formatting**: symbol by ISO (USD $, GBP £, EUR €, INR ₹); INR shows lakhs (₹28L) else thousands (₹90k); others thousands ($165k). Salary + currency code shown together.

## Assets
No raster assets. All icons are inline SVG (stroke, 24×24 viewBox) → port as Flutter `Icon`s or `CustomPaint`. Source "logos" and location "landmarks" are drawn glyphs / brand-colored monogram tiles — **swap in real logo SVGs** (LinkedIn/Indeed/etc.) and real landmark icons when available. Fonts: Inter, JetBrains Mono, Playfair Display (Google Fonts → `google_fonts` package).

## Backend notes (flagged as needed)
Job fetch across boards; fit-ranking model; résumé tailoring + PDF generation; Google-Form parse + prefill (in-app WebView); wallet balance/usage metering; onboarding profile fields (usn/college/branch/grad/cgpa or company/role/experience/employment/notice) that don't exist on a typical `profiles` table today.

## Files
- `JobHuntAgent.dc.html` — the full interactive prototype (all screens; every style inline and explicit).
- `FLUTTER_GUIDE.md` — Flutter/Dart implementation guide: tokens, theme, signature widgets (gauge, mascot, hold-button, source chips), animation specs, and a screen scaffold.
