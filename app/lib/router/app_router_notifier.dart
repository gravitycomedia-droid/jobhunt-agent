import 'dart:async' show StreamSubscription, unawaited;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthState, Session, Supabase;

import '../models/resume_profile.dart';
import '../services/api_client.dart';
import '../services/app_container.dart';
import '../services/cache_service.dart';
import '../services/career_chat.dart';
import '../services/match_feed.dart';
import '../services/push_service.dart';
import '../services/task_center.dart';

/// Phase 2b: the single source of routing truth for [appRouter]'s `redirect`,
/// and its `refreshListenable`. This is the logic that used to live inside
/// `AuthGate` (now deleted) — session tracking, the one-shot profile check that
/// decides onboarding-vs-app, sign-out hygiene, and FCM registration — lifted
/// out of the widget tree so go_router can drive navigation from it.
///
/// Being a [ChangeNotifier] means go_router re-runs `redirect` every time this
/// notifies, so a sign-in, a completed profile check, or a sign-out each move
/// the user to the correct location automatically.
class AppRouterNotifier extends ChangeNotifier {
  AppRouterNotifier() {
    _session = Supabase.instance.client.auth.currentSession;
    _lastUserId = Supabase.instance.client.auth.currentUser?.id;
    if (_session != null) unawaited(_checkProfile());
    _sub = Supabase.instance.client.auth.onAuthStateChange.listen(_onAuthState);
  }

  final ApiClient _apiClient = ApiClient();
  late final StreamSubscription<AuthState> _sub;

  Session? _session;
  String? _lastUserId;

  bool _profileChecked = false;
  ResumeProfile? _profile;
  bool _onboardingComplete = false;

  // --- read surface used by the redirect --------------------------------

  bool get isSignedIn => _session != null;
  bool get profileChecked => _profileChecked;

  /// True while signed in and either onboarding hasn't reached `done` or this
  /// session hasn't yet completed the in-app onboarding flow.
  bool get needsOnboarding =>
      (_profile == null || _profile!.onboardingStep != 'done') &&
      !_onboardingComplete;

  /// Display name for the onboarding greeting, derived from the email.
  String get onboardingUserName {
    final email = _session?.user.email ?? '';
    return email.contains('@') ? email.split('@').first : 'there';
  }

  ResumeProfile? get profile => _profile;

  OnboardingStepEntry get onboardingEntry =>
      OnboardingStepEntry(profile: _profile);

  /// Called by the onboarding flow's `onComplete`.
  void markOnboardingComplete() {
    _onboardingComplete = true;
    notifyListeners();
  }

  // --- auth event handling ----------------------------------------------

  void _onAuthState(AuthState data) {
    final previousUser = _session?.user.id;
    _session = data.session;
    if (data.event == AuthChangeEvent.signedIn) {
      // A *different* user means everything downstream is stale. The SAME user
      // signing in again (session recovery on a cold start after a long idle,
      // a token refresh surfacing as signedIn) must NOT wipe the answer we
      // already have — clearing it stranded the app on the near-blank
      // `/loading` route while the re-check crawled over a waking radio.
      final isNewUser = previousUser != null && previousUser != data.session?.user.id;
      if (isNewUser || !_profileChecked) {
        _profileChecked = false;
        _profile = null;
        _onboardingComplete = false;
      }
      // FCM registration needs an authenticated ApiClient call, so it only
      // makes sense once a session exists (best-effort beyond that point).
      unawaited(PushService.initAndRegister());
      unawaited(_checkProfile());
    }
    // The session is only recovered from storage *after* `Supabase.initialize`
    // returns, so on a cold start the very first profile check can run with no
    // user at all (no cache namespace, no auth header). These events are when
    // the session actually lands — re-check if we concluded anything without one.
    if (data.event == AuthChangeEvent.initialSession ||
        data.event == AuthChangeEvent.tokenRefreshed) {
      if (data.session != null && _profile == null) unawaited(_checkProfile());
    }
    if (data.event == AuthChangeEvent.signedOut) {
      appContainer.read(taskCenterProvider.notifier).reset();
      appContainer.read(matchFeedProvider.notifier).reset();
      appContainer.read(chatControllerProvider.notifier).reset();
      final previousUserId = _lastUserId;
      if (previousUserId != null) {
        unawaited(CacheService.instance.clearForUser(previousUserId));
      }
    }
    _lastUserId = data.session?.user.id ?? _lastUserId;
    notifyListeners();
  }

  /// How long the routing decision may wait on the network before falling back
  /// to whatever it can answer locally. `GET /resume/profile` is on the
  /// critical path to first *useful* paint, and Cloud Run scale-to-zero plus a
  /// just-woken radio can make it take a minute — with no timeout at all (the
  /// old behaviour) the app sat on the near-blank `/loading` route the whole
  /// time, which reads as "the app went white".
  static const _routingCallBudget = Duration(seconds: 12);

  /// True once the routing decision has been made *and* the network confirmed
  /// it. A cache-only answer is good enough to route on, but [refreshOnResume]
  /// retries so a stale decision can't outlive the session it was made under.
  bool _confirmedByNetwork = false;

  bool _checkInFlight = false;

  Future<void> _checkProfile() async {
    if (_checkInFlight) return;
    _checkInFlight = true;
    try {
      // The cached profile (which mirrors onboarding_step) answers the routing
      // question instantly; the network fetch then confirms/corrects it.
      final cached = await CacheService.instance.read<ResumeProfile>(
        CacheService.keyProfile,
        (json) => ResumeProfile.fromJson((json as Map).cast<String, dynamic>()),
      );
      if (cached != null && _profile == null) {
        _profile = cached.data;
        _profileChecked = true;
        notifyListeners();
      }
      try {
        final profile =
            await _apiClient.fetchCurrentProfile().timeout(_routingCallBudget);
        _profile = profile;
        _profileChecked = true;
        _confirmedByNetwork = true;
        if (profile != null) {
          await CacheService.instance.write(CacheService.keyProfile, profile.raw);
        }
        notifyListeners();
      } catch (_) {
        // Never leave the router waiting: decide with what we have. A cached
        // profile keeps the user in the app (and `_confirmedByNetwork` stays
        // false so a resume retries); with nothing cached, treat it as "no
        // profile" — onboarding is re-triggerable, a blank screen is not.
        _profileChecked = true;
        notifyListeners();
      }
    } finally {
      _checkInFlight = false;
    }
  }

  /// Re-runs the routing check when the app comes back to the foreground, and
  /// when the user asks ("Retry" on the startup screen).
  ///
  /// Deliberately does NOT clear [_profile] first: a resume must never demote a
  /// working app to a loading screen. It only fills in an answer that was
  /// missing or was made without the network.
  Future<void> refreshOnResume() async {
    if (_session == null) return;
    if (_confirmedByNetwork && _profileChecked) return;
    await _checkProfile();
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

/// Small value holder so the router can construct the onboarding flow with the
/// right resume step without leaking the whole notifier into the route builder.
class OnboardingStepEntry {
  const OnboardingStepEntry({required this.profile});
  final ResumeProfile? profile;
}
