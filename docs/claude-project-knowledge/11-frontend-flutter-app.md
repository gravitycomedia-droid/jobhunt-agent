# Frontend (Flutter App)

## App entry (`lib/main.dart`)

`main()` is `async`: `WidgetsFlutterBinding.ensureInitialized()` →
`Supabase.initialize(url, anonKey)` (awaited, blocking — auth state must be
known before first paint) → `runApp(JobHuntAgentApp())`. Firebase is **not**
initialized here — it's initialized lazily by `PushService.initAndRegister()`
after sign-in (see [07-applications-and-agent-loop.md](07-applications-and-agent-loop.md)).

`JobHuntAgentApp` wraps a single `MaterialApp`: `theme: AppTheme.light` (no
dark theme yet), `home: AuthGate()`. **No named routes, no `go_router`** — all
navigation is imperative `Navigator.push`/`pop` plus local `setState`-driven
view swapping. **No `ProviderScope`, no Riverpod/Provider/Bloc anywhere** —
state management is plain `StatefulWidget` + `setState` across the board
(confirmed by grep; CLAUDE.md scopes Riverpod for "Brick 5+" but it was never
actually introduced).

## Navigation shape

```
AuthGate (root, listens to Supabase auth state)
 ├─ no session → SplashScreen → AuthScreen (email/pw + Google OAuth)
 ├─ session, no profile → OnboardingFlow
 │    Welcome → ResumeUpload → ProfileReview → TargetRoles → MatchingLoading
 └─ session + profile → MainTabScreen
      (AppShell bottom nav, IndexedStack keeps all 5 tabs alive)
      ├─ Home tab   → home_body.dart      (+ "Run agent now" button)
      ├─ Jobs tab   → jobs_list_body.dart → AddJobScreen, ShortlistScreen
      ├─ Matches tab→ matches_body.dart   → (tailoring flow, see below)
      ├─ Track tab  → applications_body.dart (Kanban) → AppDetailScreen
      └─ Profile tab→ profile_body.dart → ProfileReview, TargetRoles,
                        CostStats, SkillGrowth, Settings, sign-out
```

Tailoring sub-flow (reached from a match card): `ResumeDiffScreen` →
`ResumeGeneratingScreen` (fake pause, no server call, self-replacing so
back-nav skips it) → `ResumePreviewScreen` ("Submit application").

## Every screen (`lib/screens/`, 25 files)

| File | Purpose |
|---|---|
| `auth_gate.dart` | Root routing widget; listens to Supabase auth state; fires `PushService.initAndRegister()` post sign-in. |
| `splash_screen.dart` | Pre-session brand cover, "Get Started"/"Sign In" CTAs. |
| `auth_screen.dart` | Email/password + Google OAuth sign-in/up. |
| `welcome_screen.dart` | Onboarding step: 3-step "how it works" explainer. |
| `resume_upload_screen.dart` | PDF upload (`file_picker`) → `POST /resume/parse`. |
| `profile_review_screen.dart` | Editable review of the parsed profile; saves via `PATCH /resume/profile`. |
| `target_roles_screen.dart` | Onboarding: target roles (chip input) + min salary. |
| `matching_loading_screen.dart` | Transitional screen; fires refresh/rerank in background, then hands off to `MainTabScreen`. |
| `onboarding_flow.dart` | Orchestrates Welcome → Upload → Review → TargetRoles → Matching. |
| `main_tab_screen.dart` | Signed-in shell: 5-tab bottom nav via `AppShell` + `IndexedStack`. |
| `home_body.dart` | Greeting, activity bell, new-matches banner, hero top match, stat grid, recent activity teaser. |
| `jobs_list_body.dart` | Job list, bookmark toggle, source filter, shortlist pill, pull-to-refresh, add-job FAB. |
| `add_job_screen.dart` | Paste URL → LLM extraction → review/edit → create. |
| `shortlist_screen.dart` | Filters applications to `state == 'saved'`. |
| `matches_body.dart` | Renders cached matches instantly, kicks off background re-rank. |
| `applications_body.dart` | Kanban board (`KanbanColumn` per stage). |
| `app_detail_screen.dart` | Notes, stage moves, follow-up draft/send, contact email. |
| `resume_diff_screen.dart` | Bullet-by-bullet tailored diff, guardrail flags, per-bullet accept/reject. |
| `resume_generating_screen.dart` | Fake transitional pause (no server call). |
| `resume_preview_screen.dart` | Compiled preview; "Submit application" saves to tracker. |
| `profile_body.dart` | Account info, links to sub-screens, sign-out. |
| `cost_stats_screen.dart` | Monthly LLM cost/usage breakdown. |
| `activity_log_screen.dart` | Full agent activity feed. |
| `skill_growth_screen.dart` | Skills-to-learn from real match gaps. |
| `settings_screen.dart` | Two notification toggles (alerts, follow-up nudge) — deliberately no "auto-apply" toggle. |

Two older screens, `home_screen.dart` and `jobs_list_screen.dart`, were
deleted from disk (replaced by the body-widget + `AppShell` pattern) but the
deletion isn't committed yet — see
[09-status-and-roadmap.md](09-status-and-roadmap.md).

## Models (`lib/models/`, 11 files)

Hand-written Dart classes mirroring server Pydantic schemas, each with a
`fromJson` factory (and `toJson` where the app PATCHes data): `job.dart`,
`resume_profile.dart` (+ `ExperienceItem`/`ProjectItem`/`EducationItem`),
`activity_item.dart`, `application_item.dart` (+ `kApplicationStates`),
`cost_stats.dart`, `health_status.dart`, `job_extraction.dart`,
`match_item.dart`, `shortlist_item.dart`, `skill_growth_item.dart`,
`tailored_resume.dart`. No code-gen (no `freezed`/`json_serializable`) — every
`fromJson`/`toJson` is hand-written.

## Services (`lib/services/`)

- **`api_client.dart`** (~525 lines) — the single point of contact with the
  FastAPI server. `_baseUrl` defaults to
  `https://jobhunt-agent-server.onrender.com`, overridable via
  `--dart-define=API_BASE_URL=...` for local dev. Reads
  `Supabase.instance.client.auth.currentSession?.accessToken` and attaches
  `Authorization: Bearer <token>` on every call. ~24 methods covering the
  entire API surface documented in
  [02-backend-api.md](02-backend-api.md). Long timeouts (up to 10 minutes) on
  LLM-heavy endpoints (`rerankShortlist`, `runPipeline`).
- **`push_service.dart`** — see
  [07-applications-and-agent-loop.md](07-applications-and-agent-loop.md).

## Config (`lib/config/`)

- **`supabase_config.dart`** — Supabase project URL, anon key, OAuth redirect
  scheme. See [10-auth-and-security.md](10-auth-and-security.md) for why the
  anon key is safe to hardcode here.

## Design system (`lib/theme/` + `lib/widgets/`)

A real, consistent token-driven system — not ad-hoc per-screen styling:
- **`app_tokens.dart`** (333 lines) — translated 1:1 from an external HTML/CSS
  prototype (`Job-Hunt Agent design system/tokens/*.css` at the repo root).
  `AppColors` (full 50–900 ramps: brand indigo-violet, success, warning,
  critical, info, neutral, plus semantic aliases for surfaces/text/status/
  verdict/guardrail/stage), `AppSpacing`, `AppRadius`, `AppElevation`,
  `AppTypography` (via `google_fonts`).
- **`app_theme.dart`** — assembles `AppTheme.light` (a `ThemeData`) from those
  tokens; code comments frame it as "the equivalent of FlutterFlow's Theme
  Settings panel" for the builder's benefit.
- **`lib/widgets/`** (16 files) — the matching component library:
  `app_shell.dart` (screen frame + bottom nav), `app_icon.dart`, `app_banner.dart`,
  `app_form_field.dart`, `job_card.dart`, `match_card.dart`,
  `application_card.dart`, `kanban_column.dart`, `status_pill.dart`,
  `score_ring.dart`, `similarity_bar.dart`, `diff_row.dart`, `empty_state.dart`,
  `loading_skeleton.dart` (shimmer), `chip_input.dart`, `activity_log_item.dart`,
  `activity_style.dart`. Convention (per doc comments): "widgets should read
  from the tokens, never hardcode a hex/px."

## Key dependencies (`pubspec.yaml`)

`http` (API calls), `file_picker` (resume upload), `http_parser` (multipart),
`google_fonts` (typography), `firebase_core` + `firebase_messaging` (push),
`supabase_flutter` (auth). Dev-only: `shared_preferences` (declared as a dev
dependency — appears possibly misplaced, not clearly used for persistent
client-side prefs in the reviewed code), `flutter_lints`. **No routing
package, no state-management package, no code-gen package.**

## Platform (Android)

`applicationId`/namespace: `com.jobhuntagent.jobhunt_agent`. Single
`MainActivity`, `launchMode="singleTop"`. OAuth callback intent-filter matches
`SupabaseConfig.redirectUrl`. Release build currently signs with the **debug**
keystore — `TODO: Add your own signing config for the release build` — a real
upload keystore is required before Play Store submission (Brick 10).
