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
| `matching_loading_screen.dart` | First-run gate: refresh pool → **awaits** the rerank → refreshes the match feed → hands off, playing `AgentScene` with a 3-step progress strip (ADR-048). Escape hatch at 40s, auto hand-off at 6min. |
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
| `activity_log_screen.dart` | Full agent activity feed; cache-first with an "Updated …" line + pull-to-refresh (ADR-049). |
| `skill_growth_screen.dart` | Skills-to-learn from real match gaps; cached for 12h because the endpoint is a ~50s LLM call (ADR-049). |
| `career_chat_screen.dart` | Grounded career chat; cached history, "Recent chats" under the greeting and in a pull-to-refresh sheet (ADR-050). |
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
  FastAPI server. `_baseUrl` defaults to the Cloud Run URL
  `https://jobhunt-agent-server-380742808186.asia-south1.run.app`, overridable
  via `--dart-define=API_BASE_URL=...` for local dev. Reads
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
  `app_shell.dart` (screen frame + the **floating pill** bottom nav, ADR-047),
  `agent_scene.dart` (the animated "agent at work" scene — mascot, inbound
  tokens, shuffling job cards), `app_icon.dart`, `app_banner.dart`,
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
`SupabaseConfig.redirectUrl`. Release build signs with a **real upload keystore**
via `android/key.properties` (ADR-030); R8 on; `build.gradle.kts` hard-fails if
`key.properties` is missing (no debug-cert fallback).

## Platform (iOS) — dev-testable via free-tier sideload

Added 2026-07-25 (ADR-011 / root `DECISIONS.md` ADR-042) so the app runs on a
personal iPhone via a free Apple ID (7-day signing, no TestFlight/App Store).
- **Bundle id**: `com.jobhuntagent.jobhuntAgent` (camelCase; the Flutter
  default) across Debug/Release/Profile in `Runner.xcodeproj`. It is
  deliberately NOT `jobhunt_agent` — the underscore breaks free-team auto
  signing (Apple rejects the auto-derived App ID *name*), and the iOS bundle id
  need not match Android's applicationId. See ADR-042.
- **Google OAuth is now dual-platform**: iOS registers the custom-scheme
  redirect via `CFBundleURLTypes` in `ios/Runner/Info.plist`, the direct mirror
  of Android's intent-filter. The scheme is **`com.jobhuntagent.firstrole`**
  (matches `SupabaseConfig.redirectUrl`), deliberately *not* the bundle id — a
  URI scheme can't contain an underscore. No custom `AppDelegate`/`SceneDelegate`
  open-URL override is needed: `supabase_flutter` handles the deep link through
  `app_links`, which supports the scene-based `FlutterSceneDelegate` in use.
- **Push is Android-only, now an explicit early return** (not a caught
  exception): `push_service.dart` guards on `TargetPlatform.iOS` and logs
  `"iOS push not yet configured — skipping FCM init"` before ever calling
  `Firebase.initializeApp()`. No Firebase iOS app / APNs key exists.
- **`ios/Podfile`** (newly created) pins `platform :ios, '13.0'` — the highest
  minimum among `firebase_core`/`firebase_messaging`/`supabase_flutter`.
- `file_picker` resume upload needs no iOS `Info.plist` keys (PDF via
  `UIDocumentPickerViewController`, no photo/camera permission).
- **Not release-ready**: no paid Apple account, so 7-day expiry, no TestFlight,
  no App Store. On-device verification pending (no Mac/device in the build env).
