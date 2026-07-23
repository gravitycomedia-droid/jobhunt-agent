import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/activity_log_screen.dart';
import '../screens/add_job_screen.dart';
import '../screens/applications_body.dart';
import '../screens/auth_screen.dart';
import '../screens/cost_stats_screen.dart';
import '../screens/form_fill_screen.dart';
import '../screens/home_body.dart';
import '../screens/jd_resume_screen.dart';
import '../screens/jobs_list_body.dart';
import '../screens/matches_body.dart';
import '../screens/onboarding_flow.dart';
import '../screens/profile_body.dart';
import '../screens/resume_diff_screen.dart';
import '../screens/resume_preview_screen.dart';
import '../screens/resume_upload_screen.dart';
import '../screens/skill_growth_screen.dart';
import '../screens/splash_screen.dart';
import '../services/haptic_service.dart';
import '../widgets/app_loader.dart';
import '../widgets/app_shell.dart';
import 'app_router_notifier.dart';
import 'route_args.dart';

/// Tab order — must match [kDefaultDestinations] in app_shell.dart.
const List<String> _tabKeys = ['home', 'jobs', 'matches', 'applications', 'profile'];
const Map<String, String> _tabPaths = {
  'home': '/home',
  'jobs': '/jobs',
  'matches': '/matches',
  'applications': '/track',
  'profile': '/profile',
};

final _rootNavigatorKey = GlobalKey<NavigatorState>();

/// Phase 2b: the app's single [GoRouter]. Replaces the old imperative
/// `AuthGate` + `MainTabScreen` (IndexedStack). Auth/onboarding routing is
/// driven by [AppRouterNotifier] through `redirect` + `refreshListenable`; the
/// five bottom-nav tabs live in a [StatefulShellRoute] so their state survives
/// switching; sub-screens are pushed above the shell on the root navigator.
final AppRouterNotifier appRouterNotifier = AppRouterNotifier();

final GoRouter appRouter = GoRouter(
  navigatorKey: _rootNavigatorKey,
  initialLocation: '/splash',
  refreshListenable: appRouterNotifier,
  redirect: (context, state) {
    final n = appRouterNotifier;
    final loc = state.matchedLocation;
    final preAuth = loc == '/splash' || loc == '/auth' || loc == '/signup';

    if (!n.isSignedIn) {
      return preAuth ? null : '/splash';
    }
    if (!n.profileChecked) {
      return loc == '/loading' ? null : '/loading';
    }
    if (n.needsOnboarding) {
      return loc == '/onboarding' ? null : '/onboarding';
    }
    if (preAuth || loc == '/loading' || loc == '/onboarding') {
      return '/home';
    }
    return null;
  },
  // Any stray/unknown location (including an OAuth callback that leaks through
  // to go_router instead of being consumed by supabase_flutter) resolves via
  // the redirect above rather than showing a 404.
  errorBuilder: (context, state) =>
      const Scaffold(body: Center(child: AppLoader())),
  routes: [
    GoRoute(path: '/splash', builder: (context, state) => SplashScreen(
          onGetStarted: () => context.go('/signup'),
          onSignIn: () => context.go('/auth'),
        )),
    GoRoute(path: '/auth', builder: (context, state) => AuthScreen(
          onBack: () => context.go('/splash'),
        )),
    GoRoute(path: '/signup', builder: (context, state) => AuthScreen(
          startInSignUp: true,
          onBack: () => context.go('/splash'),
        )),
    GoRoute(
      path: '/loading',
      builder: (context, state) => const Scaffold(body: Center(child: AppLoader())),
    ),
    GoRoute(
      path: '/onboarding',
      builder: (context, state) => OnboardingFlow(
        userName: appRouterNotifier.onboardingUserName,
        initialProfile: appRouterNotifier.profile,
        initialStep: appRouterNotifier.profile == null
            ? OnboardingStep.welcome
            : OnboardingFlow.stepFromServer(appRouterNotifier.profile!.onboardingStep),
        onComplete: appRouterNotifier.markOnboardingComplete,
      ),
    ),

    // --- the five bottom-nav tabs (state survives switching) ------------
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) => _TabShell(shell: navigationShell),
      branches: [
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/home',
            builder: (context, state) => HomeBody(
              onNavigateToTab: (key) => context.go(_tabPaths[key] ?? '/home'),
            ),
          ),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/jobs', builder: (context, state) => const JobsListBody()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/matches', builder: (context, state) => const MatchesBody()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/track', builder: (context, state) => const ApplicationsBody()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/profile', builder: (context, state) => const ProfileBody()),
        ]),
      ],
    ),

    // --- sub-screens pushed above the shell (root navigator) ------------
    GoRoute(
      parentNavigatorKey: _rootNavigatorKey,
      path: '/cost',
      builder: (context, state) => const CostStatsScreen(),
    ),
    GoRoute(
      parentNavigatorKey: _rootNavigatorKey,
      path: '/skill-growth',
      builder: (context, state) => const SkillGrowthScreen(),
    ),
    GoRoute(
      parentNavigatorKey: _rootNavigatorKey,
      path: '/activity',
      builder: (context, state) => const ActivityLogScreen(),
    ),
    GoRoute(
      parentNavigatorKey: _rootNavigatorKey,
      path: '/jd-resume',
      builder: (context, state) => const JdResumeScreen(),
    ),
    GoRoute(
      parentNavigatorKey: _rootNavigatorKey,
      path: '/form-fill',
      builder: (context, state) => const FormFillScreen(),
    ),
    GoRoute(
      parentNavigatorKey: _rootNavigatorKey,
      path: '/add-job',
      builder: (context, state) => const AddJobScreen(),
    ),
    GoRoute(
      parentNavigatorKey: _rootNavigatorKey,
      path: '/resume-upload',
      builder: (context, state) => const ResumeUploadScreen(),
    ),
    GoRoute(
      parentNavigatorKey: _rootNavigatorKey,
      path: '/tailor',
      builder: (context, state) {
        final args = state.extra as TailorArgs;
        return ResumeDiffScreen(jobId: args.jobId, jobTitle: args.jobTitle);
      },
    ),
    GoRoute(
      parentNavigatorKey: _rootNavigatorKey,
      path: '/tailor/preview',
      builder: (context, state) {
        final args = state.extra as TailorArgs;
        return ResumePreviewScreen(jobId: args.jobId, jobTitle: args.jobTitle);
      },
    ),
  ],
);

/// The signed-in frame: [AppShell]'s bottom nav wrapping the active tab branch.
/// `goBranch` switches tabs while preserving each branch's navigation state.
class _TabShell extends StatelessWidget {
  const _TabShell({required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) {
    return AppShell(
      active: _tabKeys[shell.currentIndex],
      showHeader: false,
      onNavigate: (key) {
        final index = _tabKeys.indexOf(key);
        if (index >= 0) {
          HapticService.instance.selection();
          // goBranch to the current branch again pops it to its root — matches
          // the usual "tap the active tab to reset" expectation.
          shell.goBranch(index, initialLocation: index == shell.currentIndex);
        }
      },
      child: shell,
    );
  }
}
