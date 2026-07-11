# Roadmap Proposals — post-stabilization phases

Written after the Phase 0–7 stabilization/UX overhaul (see DECISIONS.md
ADR-011…013). Each proposal: rationale + rough effort (S ≈ half a day,
M ≈ 1–2 days, L ≈ 3–5 days). Ordered roughly by value-for-effort.

## 1. CI via GitHub Actions — **S**
`pytest server/tests` + `flutter analyze` + `flutter test` on every push.
The whole overhaul leaned on these three commands as the definition of
"didn't break anything"; running them automatically catches the class of
bug that bit Brick 10 (working tree drifting from what's on GitHub/Render).
Cheapest insurance on this list — do it first.

## 2. `render.yaml` for reproducible deployment — **S**
The Render service was created by hand through the API (ADR-010). A
committed blueprint makes the web service + cron job + env-var list
reviewable and re-creatable, and documents the deploy in the repo instead
of in one person's dashboard. Pairs naturally with #1.

## 3. Cover-letter generation — **M**
Highest-leverage reuse in the codebase: the tailor → guardrail → human
approval → ReportLab PDF chain already exists end-to-end. A cover letter is
the same pipeline with a different prompt and a one-page PDF template.
Every claim still traces to the resume via the existing `partial_ratio`
guardrail, so the anti-fabrication story stays intact.

## 4. Interview-prep question packs per match — **M**
The `matches` table already stores per-job `gaps` and `strengths`. A
`generate_interview_pack(job, match, profile)` LLM task ("questions this JD
will probably ask, focused on your gaps, with suggested answers grounded in
your real experience") turns data the app already computes into a feature
users would open the night before an interview. One new screen off the
match card.

## 5. Application deadline reminders — **S/M**
The pipeline + FCM plumbing exists (Brick 8). Add `deadline date` to
`applications`, a field on AppDetail, and one query in
`daily_pipeline._process_profile` that pushes "X closes in 2 days". No new
infrastructure, one migration.

## 6. Weekly progress email digest (Resend) — **M**
`services/email.py` (Resend) and `services/activity.py` (the event feed)
both exist; a digest is a template + a weekly cron branch. Email closes the
loop for users who ignore push notifications, and the "your week: 14 jobs
scored, 3 applied, 1 interview" framing is strong retention material.

## 7. Job alerts by saved search — **M**
Users already set target roles; the pipeline already fetches daily. Let a
user save a query (role + location + min salary in their currency — Phase
1D's `salary_currency` makes that finally correct) and push when a new
posting matches it. Mostly a filter over `refresh_job_pool`'s inserts.

## 8. Salary insights & negotiation ranges — **M**
Adzuna salary data (min/max/currency) is already ingested. Percentile
bands per role/location computed in SQL — no LLM, no new source — shown on
the match card and a small "what to ask for" panel. Golden Rule 2 applies:
this is a `percentile_cont` query, not a model call.

## 9. Multi-resume profiles (per role family) — **L**
One base resume per role family (e.g. Flutter vs. Python roles) with
matching/tailoring scoped to the selected profile. Real schema work
(`profiles` 1→N `resumes`, embedding per resume, matching joins change) —
worth it once a real user actually hunts across two role families, not
before.

## 10. Referral finder (no scraping) — **S**
For each match, deep-link a pre-built LinkedIn *search* URL
(`site:linkedin.com/in "<company>" "<role keyword>"` or LinkedIn's own
search params) so the user can find warm intros. Pure URL construction —
ToS-safe because the user does the browsing in their own session.

## 11. Form autofill v2: WebView JS-injection fill — **L**
Phase 6 deliberately shipped prefill-URL-only (ADR-013). V2 opens
sign-in-gated forms in an in-app WebView and injects the reviewed answers
into the DOM — the human still taps Submit. Fragile (selector churn),
dual-use-sensitive, ship behind a flag with the same review-first UI.

## 12. Flutter Web client — **M/L**
The backend is already client-agnostic (Bearer-token REST + CORS enabled)
and most screens are plain Material. Work concentrates in the handful of
platform-touching spots: file_picker/share_plus/path_provider fallbacks,
FCM (skip on web), and OAuth redirect handling. Good demo surface for the
Play Store listing and recruiters.

## 13. Dark theme — **S/M**
The token system (`app_tokens.dart`) was built for exactly this — define a
dark `AppColors` set and switch on `ThemeMode`. Cheap because Phase 3A/4C
removed the last hardcoded-color stragglers into token-driven widgets.

## 14. Riverpod migration — **defer**
TaskCenter/MatchFeed/CacheService (plain singletons + ValueNotifiers) now
cover the state-sharing pain that would have justified it. Migrate only if
cross-screen state grows past ~3 more services; a mechanical rewrite today
buys learning value but no user value.

## 15. iOS support (APNs + second Firebase app) — **L, distinct milestone**
Needs an Apple developer account, APNs keys, a Mac build pipeline, and
push re-verification. Everything else in the app is already
platform-neutral. Treat as its own brick after Play Store launch proves
demand.
