# Architecture Decision Log (condensed)

Full record lives in `DECISIONS.md` at the repo root — this is a condensed
version for quick reference. Format per entry: Context → Decision → why
alternatives were rejected → consequence.

**ADR-001 — Two-stage RAG matching.** ~500 jobs/day is too costly to send all
to an LLM. Decision: pgvector cosine similarity shortlists top 50 (cheap,
~20ms), then the LLM re-ranks only the top 20 with structured reasoning.
Rejected: pure-LLM (too costly), pure-keyword (misses semantic matches),
pure-embeddings (no reasoning/explanation for the user). Result: ~96% reduction
in LLM tokens versus naive matching.

**ADR-002 — pgvector inside Supabase, not a dedicated vector DB.** Rejected
Pinecone/Weaviate/Qdrant as unnecessary complexity at thousands (not millions)
of vectors. One datastore for relational + vector + auth + storage; revisit
only past ~1M vector rows.

**ADR-003 — Legal job APIs only, no scraping.** Adzuna (primary) + JSearch/
RapidAPI (secondary) with a dedup layer, plus a manual paste-a-job feature.
Rejected LinkedIn/Naukri scraping as ToS-violating and brittle. Tradeoff:
narrower job coverage in exchange for full legal/stability compliance.

**ADR-004 — Anti-fabrication guardrail with a deterministic post-check.**
Tailoring returns `{original, tailored}` bullet pairs; `guardrail.py`
fuzzy-verifies every `original` exists in the stored resume (threshold ≥85,
`partial_ratio`), flags failures in the diff UI, requires manual approval.
Rejected prompt-only instructions (unenforceable) and human-review-alone
(users skim). This establishes "LLM handles language, code enforces truth" as
the project's core safety boundary. See
[06-resume-tailoring-and-guardrail.md](06-resume-tailoring-and-guardrail.md).

**ADR-005 (2026-07-08) — Switched `gemini-2.0-flash` → `gemini-2.5-flash`.**
The live API key showed 0/0 free-tier quota for 2.0 Flash; 2.5 Flash and
Flash-Lite had real free allowances. Chose full `gemini-2.5-flash` over
`-lite` for better vision-extraction quality on resume parsing (the RPM
difference was irrelevant for a single-user app at the time). One-line config
change since the model is always read from `Settings.gemini_model`.

**ADR-006 (2026-07-09) — Switched `text-embedding-004` → `gemini-embedding-001`.**
`text-embedding-004` wasn't available at all on this API key (404, not quota
exhaustion). Standardized on `gemini-embedding-001` pinned to 768-dim output to
match the existing `vector(768)` schema with no migration needed. Rejected
native 3072-dim output (doubles index cost, unneeded at this scale) and
preview embedding models (stability risk).

**ADR-007 (2026-07-09) — Stubbed FCM push, cron via Render, manual trigger.**
No Firebase project existed at decision time, so `notify.py` originally just
logged "would notify"; `POST /pipeline/run` doubled as both the future cron
target and a manual "run now" button. **Same-day update**: a real Firebase
project (`jobhuntagent-27b32`) was provisioned; real
`firebase_admin.messaging.send()` wired in with log-only fallback on
failure/missing token; `profiles.fcm_token` added (migration `003`); Android
registered via `flutterfire configure`. iOS explicitly out of scope (no APNs
key). **Not verified on-device** (no Android SDK/emulator in the development
environment).

**ADR-008 (2026-07-09) — Supabase Auth (Google OAuth) for multi-tenancy,
service-role scoping over RLS enforcement.** Real login replaced an earlier
single-global-profile assumption. `services/auth.py` verifies bearer tokens via
Supabase's Auth API (no local JWT decoding). Split `/pipeline/run` (cron,
shared-secret header) from `/pipeline/run-mine` (per-user, JWT) since a cron
job has no session. RLS (migration `004`) is explicit defense-in-depth only —
the server always connects with the service-role key and bypasses it; real
isolation is enforced in Python by `get_current_profile` and per-router
ownership checks. This fixed a real bug: any UUID could previously be PATCHed
by anyone. **"Polish" update (2026-07-10)**: adopted `AppShell` bottom-nav,
added a real Profile/Settings screen, split screens into body-only widgets
composed via `MainTabScreen`/`IndexedStack` (preserves tab state across
switches), fixed a broken widget test. Never verified on-device.

**ADR-009 (2026-07-10) — Frontend rebuild from the design-system prototype,
phased execution.** The HTML/CSS prototype
(`Job-Hunt Agent design system/Job-Hunt Agent Prototype.dc.html`) specified 23
screen-states versus 9 already built — roughly 14 net-new screens, many with no
backend support yet. Scoped into 4 checkpointed phases:
- **Phase 1**: email/password auth (zero backend change), migration `005`
  (target roles/min salary), rewritten `AuthGate` state machine + onboarding
  flow, re-skinned Home/Jobs/Matches bodies.
- **Phase 2**: App Detail screen, per-bullet tailoring accept/reject (`PATCH
  /tailor/{id}/approve` now takes `accepted: list[bool]`), Add Job via URL
  scrape + LLM extraction.
- **Phase 3**: Cost Stats and Activity Log. Migration `006` adds `profile_id`
  to `llm_calls` (previously a global unattributed stream — would have leaked
  cross-user spend). Caught and fixed the cost-percentage rounding bug
  mentioned in [03-llm-and-prompts.md](03-llm-and-prompts.md).
- **Phase 4**: real follow-up sending via Resend (migration `007`,
  `services/email.py`), Skill Growth (real frequency math, not a fabricated
  LLM percentage), Settings (migration `008`, only 2 real toggles shipped —
  an "auto-apply" toggle was explicitly rejected as conflicting with the
  project's "no auto-submitting" rule).
- Process note: the team adopted a "Playwright-over-static-build" screenshot
  verification pattern after `flutter run -d web-server`'s debug compiler
  proved unreliable for visual verification.

**ADR-010 — Render deployment + first working APK build.** Two blockers: (1)
`ApiClient._baseUrl` pointed at `localhost`/`10.0.2.2`, unreachable from a real
phone; (2) Bricks 4–9's entire server implementation had never been
committed/pushed to GitHub, so Render had nothing to deploy. Decision:
committed/pushed 42 backend files in one large batch commit (after explicit
user confirmation); added `server/Dockerfile` (needed `poppler-utils` for
`pdf2image`, unavailable on Render's native Python buildpack); created the
Render web service (`jobhunt-agent-server`, free plan, Singapore region) and
copied env vars via Render's HTTP API (all except `FCM_SERVICE_ACCOUNT_PATH`,
which degrades gracefully without it). `ApiClient._baseUrl` now defaults to
`https://jobhunt-agent-server.onrender.com`. Release APK still uses the debug
keystore (fine for sideloading; a real upload keystore is deferred to Brick
10/Play Store launch). Rejected LAN IP/ngrok tunnels in favor of a permanent
Render URL. Verified only via curl against the live server (`/health` → 200,
`/jobs` → 401 correctly) — the on-device login/upload/matching flow has never
been verified (no Android SDK/emulator available).

## Cross-cutting pattern worth noting

Several ADRs (007, 008, 009, 010) end with the same caveat: **verified via
server-side checks (curl, Supabase queries, `flutter analyze`/`build`) but
never verified on a physical Android device**, because no Android SDK/emulator
has been available in the development environment so far. This is the single
biggest "known unknown" heading into Brick 10 — see
[09-status-and-roadmap.md](09-status-and-roadmap.md).
