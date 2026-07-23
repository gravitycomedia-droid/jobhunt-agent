import 'dart:async' show StreamSubscription, unawaited;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthState, Session, Supabase;

import '../models/resume_profile.dart';
import '../services/api_client.dart';
import '../services/app_container.dart';
import '../services/cache_service.dart';
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
    _session = data.session;
    if (data.event == AuthChangeEvent.signedIn) {
      _profileChecked = false;
      _profile = null;
      _onboardingComplete = false;
      // FCM registration needs an authenticated ApiClient call, so it only
      // makes sense once a session exists (best-effort beyond that point).
      unawaited(PushService.initAndRegister());
      unawaited(_checkProfile());
    }
    if (data.event == AuthChangeEvent.signedOut) {
      appContainer.read(taskCenterProvider.notifier).reset();
      appContainer.read(matchFeedProvider.notifier).reset();
      final previousUserId = _lastUserId;
      if (previousUserId != null) {
        unawaited(CacheService.instance.clearForUser(previousUserId));
      }
    }
    _lastUserId = data.session?.user.id ?? _lastUserId;
    notifyListeners();
  }

  Future<void> _checkProfile() async {
    // The cached profile (which mirrors onboarding_step) answers the routing
    // question instantly; the network fetch then confirms/corrects it.
    final cached = await CacheService.instance.read<ResumeProfile>(
      CacheService.keyProfile,
      (json) => ResumeProfile.fromJson((json as Map).cast<String, dynamic>()),
    );
    if (cached != null && !_profileChecked) {
      _profile = cached.data;
      _profileChecked = true;
      notifyListeners();
    }
    try {
      final profile = await _apiClient.fetchCurrentProfile();
      _profile = profile;
      _profileChecked = true;
      if (profile != null) {
        await CacheService.instance.write(CacheService.keyProfile, profile.raw);
      }
      notifyListeners();
    } catch (_) {
      // With no cache, treat a failed check as "no profile" rather than
      // getting stuck on a spinner forever — onboarding is re-triggerable.
      if (_profileChecked) return;
      _profile = null;
      _profileChecked = true;
      notifyListeners();
    }
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
