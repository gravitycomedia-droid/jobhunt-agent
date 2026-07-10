# Status & Roadmap

## Brick checklist (per CLAUDE.md)

- [x] Brick 1: Foundations (Flutter↔FastAPI loop)
- [x] Brick 2: Resume parser (vision LLM → structured profile)
- [x] Brick 3: Job ingestion (Adzuna + JSearch + dedup + Supabase)
- [x] Brick 4: Embeddings + pgvector search
- [x] Brick 5: LLM re-ranker (two-stage RAG complete)
- [x] Brick 6: Resume tailoring + guardrail + diff view
- [x] Brick 7: Application tracker (Kanban)
- [x] Brick 8: Agent loop (cron + FCM push + follow-up drafts) — **Android push
      unverified on-device**
- [x] Brick 9: Auth + polish + beta users — Google OAuth + multi-tenant
      RLS/scoping + AppShell bottom-nav + Profile screen + empty/loading state
      audit — **sign-in/push flows unverified on-device**
- [ ] Brick 10: Play Store launch + README + demo video — **not started**

"Done" for Bricks 1–9 means: implemented, chain-verified through
server-side/scripted checks (curl, Supabase queries, `flutter analyze`/`build`),
and demonstrable — but with a repeated, explicit caveat that **no physical
Android device or emulator has been available during development**, so the
actual on-device experience (sign-in redirect, push notification delivery,
resume upload UX, etc.) has never been directly observed.

## Important: uncommitted work in the working tree right now

As of the last inventory (2026-07-10), `git log` shows only 5 commits on
`main`, but `git status` shows **63 changed paths** (21 modified, 2 deleted, 40
untracked, nothing staged). This means:

- All of ADR-009's "frontend rebuild, all 4 phases complete" work — roughly 30
  new Dart files (new screens, models, services, the entire `lib/theme/` design
  system, `lib/widgets/` component library) — exists **only in the working
  tree**, not in git history.
- Much of ADR-008's auth/polish pass is also uncommitted.
- Two old screens (`home_screen.dart`, `jobs_list_screen.dart`) are deleted on
  disk but the deletion isn't committed either.
- New Firebase config files (`google-services.json`, `google-services-2.json`,
  `app/firebase.json`) and the entire `Job-Hunt Agent design system/` reference
  folder are untracked.

**Practical implication**: the committed git history significantly undersells
the real state of the app. Anyone (including a future Claude session) reasoning
from `git log` alone would think only Bricks 1–3 plus a single large "bricks
4-9" commit exist — the truth is there's a full second frontend generation
sitting uncommitted. This should be committed (likely in logical chunks
matching ADR-008/009's phases, or as directed by the user) before it's at risk
of being lost, and before Brick 10 work begins on top of it.

## What's functionally complete right now

- End-to-end golden path: sign up → upload resume → parse → review/edit
  profile → set target roles → jobs fetched/matched → tailor resume for a
  match → guardrail-checked diff → approve → submit to Kanban tracker → track
  through interview stages → draft/send follow-ups.
- Daily autonomous loop: job refresh, re-rank, follow-up drafting, one summary
  push notification — gated entirely by per-user notification preferences.
- Multi-tenant auth via Supabase (Google OAuth + email/password), with
  application-layer ownership checks on every mutating endpoint.
- Cost/usage transparency: every LLM call logged and surfaced in a per-user
  cost dashboard.
- A real, token-based design system (`lib/theme/`) driving 25 screens and 16
  reusable widgets — not just ad-hoc styling per screen.
- Backend deployed and live on Render; first APK built (sideloadable, debug-signed).

## Known gaps / open risks

1. **On-device verification** — nothing has been confirmed working on a real
   phone. Google OAuth redirect, FCM push delivery, camera/file-picker resume
   upload, and general touch/scroll UX are all unverified. This is the top
   priority before any Play Store submission.
2. **Uncommitted frontend rebuild** (see above) — needs to be committed.
3. **Release signing** — the Android release build currently uses the debug
   keystore (`TODO: Add your own signing config` in `build.gradle.kts`); a real
   upload keystore is required for Play Store submission.
4. **No CI** — no `.github/workflows/`; all verification has been manual/
   scripted against the live stack. `server/tests/` (6 pytest files covering
   `activity`, `cost_stats`, `dedup`, `embeddings`, `guardrail`, `matching`) and
   a single Flutter `widget_test.dart` exist but aren't run automatically on
   push.
5. **No root README** — `app/README.md` is still Flutter's unmodified
   boilerplate. Explicitly scoped into Brick 10 ("Play Store launch + README +
   demo video"), so this is expected, not an oversight.
6. **No `render.yaml`** — the Render service and its environment variables were
   configured directly through Render's dashboard/API, not as code in the
   repo. The deployment is not currently reproducible from the repo alone.
7. **`docs/PROMPTS.md` embeddings section is stale** — still references
   `text-embedding-004`, not updated after ADR-006's switch to
   `gemini-embedding-001`.
8. **iOS is entirely out of scope so far** — no Firebase iOS app, no APNs key,
   `firebase_options.dart` throws `UnsupportedError` for every non-Android
   platform. This project is Android-first/Android-only for now.

## Brick 10 — what's left (per CLAUDE.md's own definition)

- [ ] Commit the pending frontend-rebuild work
- [ ] Verify the full flow on a real Android device or emulator
- [ ] Real Play Store release signing/keystore
- [ ] Root-level README (project pitch, setup instructions, screenshots)
- [ ] Demo video
- [ ] Play Store listing + submission

## Future scope beyond Brick 10 (not yet planned in detail — ideas only)

These are **not** committed roadmap items — they're logical next steps
consistent with the project's stated non-goals in CLAUDE.md, called out here
only so a future conversation knows what's deliberately been deferred rather
than forgotten:

- iOS support (would require a real Apple Developer account, APNs key, and a
  second Firebase app registration).
- Riverpod adoption for state management — CLAUDE.md explicitly scopes this to
  "Brick 5+" but it was never introduced; the app still uses plain
  `StatefulWidget`/`setState` throughout. Worth revisiting once screen-to-screen
  state sharing gets unwieldy.
- A `render.yaml` (or equivalent) to make the Render deployment reproducible
  from the repo.
- CI (GitHub Actions) running `pytest` and `flutter test`/`flutter analyze` on
  every push.
- Expanding job source coverage (more legal job-board APIs) if Adzuna+JSearch
  coverage proves too narrow in practice.
- Revisiting the vector-DB choice (pgvector → dedicated vector DB) only if the
  job pool grows toward ~1M+ rows (ADR-002's own stated threshold) — not
  currently anywhere close.
