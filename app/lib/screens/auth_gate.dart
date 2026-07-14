import 'dart:async' show StreamSubscription, unawaited;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthState, Session, Supabase;

import '../models/resume_profile.dart';
import '../services/api_client.dart';
import '../services/cache_service.dart';
import '../services/match_feed.dart';
import '../services/push_service.dart';
import '../services/task_center.dart';
import '../widgets/app_loader.dart';
import 'auth_screen.dart';
import 'main_tab_screen.dart';
import 'onboarding_flow.dart';
import 'splash_screen.dart';

enum _PreAuthScreen { splash, auth, authSignUp }

/// Frontend rebuild Phase 1: the root of the widget tree below
/// [JobHuntAgentApp]. Three top-level states:
/// - No session → [SplashScreen] / [AuthScreen] (toggled locally, not a
///   separate onboarding step — nothing server-side happens yet).
/// - Session, but GET /resume/profile came back null → [OnboardingFlow]
///   (Welcome → Upload → Review → Target Roles → Matching), landing on
///   [MainTabScreen] once it calls back.
/// - Session with an existing profile → straight to [MainTabScreen]; this
///   is also where a returning user lands, since the profile check only
///   needs to happen once per sign-in.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final ApiClient _apiClient = ApiClient();

  Session? _session = Supabase.instance.client.auth.currentSession;
  late final StreamSubscription<AuthState> _subscription;

  // Phase 5: the id to wipe cache entries for on sign-out — captured while
  // signed in, because the signedOut event's session is already null.
  String? _lastUserId = Supabase.instance.client.auth.currentUser?.id;

  _PreAuthScreen _preAuthScreen = _PreAuthScreen.splash;

  // Null until checked for the current session; re-armed on every sign-in
  // so a fresh session always gets a fresh profile check. Phase 3B: we
  // keep the whole profile (not just a bool) because its onboarding_step
  // decides WHERE onboarding resumes, and the review step needs the
  // already-parsed profile data.
  bool _profileChecked = false;
  ResumeProfile? _profile;
  bool _onboardingComplete = false;

  @override
  void initState() {
    super.initState();
    if (_session != null) unawaited(_checkProfile());
    _subscription = Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      setState(() {
        _session = data.session;
        if (data.event == AuthChangeEvent.signedIn) {
          _profileChecked = false;
          _profile = null;
          _onboardingComplete = false;
        }
      });
      // FCM token registration needs an authenticated ApiClient call
      // (GET /resume/profile), so it only makes sense to fire once a
      // session actually exists — see PushService's own doc comment for
      // why every step inside it is still best-effort beyond that.
      if (data.event == AuthChangeEvent.signedIn) {
        unawaited(PushService.initAndRegister());
        unawaited(_checkProfile());
      }
      // Sign-out hygiene: stop pollers and drop per-user state (in-memory
      // AND on-disk cache) so the next account never sees this user's data.
      if (data.event == AuthChangeEvent.signedOut) {
        TaskCenter.instance.reset();
        MatchFeed.instance.reset();
        final previousUserId = _lastUserId;
        if (previousUserId != null) {
          unawaited(CacheService.instance.clearForUser(previousUserId));
        }
      }
      _lastUserId = data.session?.user.id ?? _lastUserId;
    });
  }

  Future<void> _checkProfile() async {
    // Phase 5: the cached profile (which mirrors onboarding_step) answers
    // the routing question instantly — the network fetch then confirms or
    // corrects it in the background.
    final cached = await CacheService.instance.read<ResumeProfile>(
      CacheService.keyProfile,
      (json) => ResumeProfile.fromJson((json as Map).cast<String, dynamic>()),
    );
    if (mounted && cached != null && !_profileChecked) {
      setState(() {
        _profile = cached.data;
        _profileChecked = true;
      });
    }
    try {
      final profile = await _apiClient.fetchCurrentProfile();
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _profileChecked = true;
      });
      if (profile != null) {
        await CacheService.instance.write(CacheService.keyProfile, profile.raw);
      }
    } catch (_) {
      // With no cache, treat a failed check as "no profile" rather than
      // getting stuck on a spinner forever — onboarding is re-triggerable,
      // an infinite loading state isn't. With a cache, keep the cached
      // routing decision.
      if (!mounted || _profileChecked) return;
      setState(() {
        _profile = null;
        _profileChecked = true;
      });
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session == null) {
      return switch (_preAuthScreen) {
        _PreAuthScreen.splash => SplashScreen(
            onGetStarted: () => setState(() => _preAuthScreen = _PreAuthScreen.authSignUp),
            onSignIn: () => setState(() => _preAuthScreen = _PreAuthScreen.auth),
          ),
        _PreAuthScreen.auth => AuthScreen(
            onBack: () => setState(() => _preAuthScreen = _PreAuthScreen.splash),
          ),
        _PreAuthScreen.authSignUp => AuthScreen(
            startInSignUp: true,
            onBack: () => setState(() => _preAuthScreen = _PreAuthScreen.splash),
          ),
      };
    }

    if (!_profileChecked) {
      return const Scaffold(body: Center(child: AppLoader()));
    }

    // Phase 3B routing: no profile → onboarding from the top; profile with
    // an unfinished onboarding_step → resume at EXACTLY that step (kill the
    // app mid-flow, reopen, land where you left off); 'done' → main app.
    final profile = _profile;
    final needsOnboarding = profile == null || profile.onboardingStep != 'done';
    if (needsOnboarding && !_onboardingComplete) {
      final email = session.user.email ?? '';
      final name = email.contains('@') ? email.split('@').first : 'there';
      return OnboardingFlow(
        userName: name,
        initialStep: profile == null
            ? OnboardingStep.welcome
            : OnboardingFlow.stepFromServer(profile.onboardingStep),
        initialProfile: profile,
        onComplete: () => setState(() => _onboardingComplete = true),
      );
    }

    return const MainTabScreen();
  }
}
