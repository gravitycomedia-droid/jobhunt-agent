import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../models/resume_profile.dart';
import '../services/api_client.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_icon.dart';
import 'academics_screen.dart';
import 'experience_screen.dart';
import 'matching_loading_screen.dart';
import 'profile_review_screen.dart';
import 'resume_upload_screen.dart';
import 'student_info_screen.dart';
import 'target_locations_screen.dart';
import 'target_roles_screen.dart';
import 'welcome_screen.dart';

/// The onboarding steps as an explicit enum (Phase 3B) — mirrors the
/// server's `profiles.onboarding_step` values, plus the client-only
/// `matching` transition screen at the end.
///
/// Phase 6 (§4.1) adds the fork's branch-detail steps. `studentInfo` is the
/// fork itself; from there a student goes to `academics` and a professional to
/// `experience` (mutually exclusive), then both converge on `locations` →
/// `roles`. The enum order matches the server's `ONBOARDING_STEPS` so
/// resumption from a stored step is a direct lookup.
enum OnboardingStep { welcome, resume, review, studentInfo, academics, experience, locations, roles, matching }

/// Phase 3B rework: onboarding as an explicit step state machine instead
/// of chained Navigator.pushes. Why: with pushes, resuming at an arbitrary
/// step (kill app at ProfileReview → reopen) meant re-building the whole
/// push chain; with a step-keyed builder, [AuthGate] just hands us the
/// step the server recorded and we render exactly that screen.
///
/// Skip contract (Phase 3B):
/// - Welcome: skippable → resume upload (same target as Continue).
/// - ResumeUpload: NOT skippable — the whole product needs a profile.
/// - ProfileReview: skippable — accepts parsed data as-is, step → 'roles'.
/// - TargetRoles: skippable — server falls back to config defaults,
///   step → 'done' (Profile tab nudges later via the roles count).
/// Every skip advances `onboarding_step` server-side, so resumption and
/// skipping compose.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({
    super.key,
    required this.userName,
    required this.onComplete,
    this.initialStep = OnboardingStep.welcome,
    this.initialProfile,
  });

  final String userName;
  final VoidCallback onComplete;

  /// Where to resume (from the server's `onboarding_step` via [AuthGate]).
  final OnboardingStep initialStep;

  /// The already-parsed profile when resuming at review or later — saves
  /// re-fetching what AuthGate just loaded.
  final ResumeProfile? initialProfile;

  /// Maps the server's step string to the flow's enum. Unknown/'done'
  /// values fall back to welcome — AuthGate never routes 'done' here.
  static OnboardingStep stepFromServer(String step) => switch (step) {
        'resume' => OnboardingStep.resume,
        'review' => OnboardingStep.review,
        'student_info' => OnboardingStep.studentInfo,
        'academics' => OnboardingStep.academics,
        'experience' => OnboardingStep.experience,
        'locations' => OnboardingStep.locations,
        'roles' => OnboardingStep.roles,
        _ => OnboardingStep.welcome,
      };

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  final ApiClient _apiClient = ApiClient();

  late OnboardingStep _step = widget.initialStep;
  late ResumeProfile? _profile = widget.initialProfile;

  // Steps the user counts: welcome(1) resume(2) review(3) studentInfo(4)
  // branch-detail(5) locations(6) roles(7). `academics` and `experience` are
  // the same numbered step — a profile only ever sees one. `matching` is a
  // transition, not a numbered step.
  int get _stepNumber => switch (_step) {
        OnboardingStep.welcome => 1,
        OnboardingStep.resume => 2,
        OnboardingStep.review => 3,
        OnboardingStep.studentInfo => 4,
        OnboardingStep.academics => 5,
        OnboardingStep.experience => 5,
        OnboardingStep.locations => 6,
        OnboardingStep.roles => 7,
        OnboardingStep.matching => 7,
      };

  static const _totalSteps = 7;

  void _goTo(OnboardingStep step) => setState(() => _step = step);

  /// Review skip: accept the parsed profile as-is. Best-effort server
  /// advance (forward-only), then move on locally either way — a flaky
  /// network shouldn't trap the user on a screen they chose to skip.
  void _skipReview() {
    unawaited(_apiClient.updateOnboardingStep('student_info').catchError((_) {}));
    _goTo(OnboardingStep.studentInfo);
  }

  /// Fork skip (§4.1): jump past the whole fork — employment_type and the
  /// branch details stay unset (no downstream feature requires them) and the
  /// server advances straight to 'locations'.
  void _skipStudentInfo() {
    unawaited(_apiClient.updateOnboardingStep('locations').catchError((_) {}));
    _goTo(OnboardingStep.locations);
  }

  /// Branch-detail skip (academics/experience): the fork choice is already
  /// recorded; skip only the detail form and advance to 'locations'.
  void _skipBranchDetail() {
    unawaited(_apiClient.updateOnboardingStep('locations').catchError((_) {}));
    _goTo(OnboardingStep.locations);
  }

  /// Locations skip: no city preference; server advances to 'roles'.
  void _skipLocations() {
    unawaited(_apiClient.updateOnboardingStep('roles').catchError((_) {}));
    _goTo(OnboardingStep.roles);
  }

  /// Roles skip: server falls back to its config-default roles; prefs stay
  /// unset so the Profile tab's "Target roles · 0" row nudges later.
  void _skipRoles() {
    unawaited(_apiClient.updateOnboardingStep('done').catchError((_) {}));
    _goTo(OnboardingStep.matching);
  }

  /// The branch-detail step for the current fork choice — where studentInfo
  /// leads and where 'locations' walks back to. Falls back to the fork itself
  /// when no choice was recorded (e.g. the fork was skipped).
  OnboardingStep get _branchStep => switch (_profile?.employmentType) {
        'student' => OnboardingStep.academics,
        'experienced' => OnboardingStep.experience,
        _ => OnboardingStep.studentInfo,
      };

  OnboardingStep? get _backTarget => switch (_step) {
        OnboardingStep.welcome => null,
        OnboardingStep.resume => OnboardingStep.welcome,
        // Back from review = re-upload a different PDF; back from a later step
        // = re-check an earlier one. Forward server state is untouched —
        // walking backward to fix a typo never regresses onboarding_step.
        OnboardingStep.review => OnboardingStep.resume,
        OnboardingStep.studentInfo => _profile == null ? null : OnboardingStep.review,
        OnboardingStep.academics => OnboardingStep.studentInfo,
        OnboardingStep.experience => OnboardingStep.studentInfo,
        OnboardingStep.locations => _profile == null ? null : _branchStep,
        OnboardingStep.roles => _profile == null ? null : OnboardingStep.locations,
        OnboardingStep.matching => null,
      };

  VoidCallback? get _skipAction => switch (_step) {
        OnboardingStep.welcome => () => _goTo(OnboardingStep.resume),
        OnboardingStep.resume => null, // NOT skippable — profile is required
        OnboardingStep.review => _skipReview,
        OnboardingStep.studentInfo => _skipStudentInfo,
        OnboardingStep.academics => _skipBranchDetail,
        OnboardingStep.experience => _skipBranchDetail,
        OnboardingStep.locations => _skipLocations,
        OnboardingStep.roles => _skipRoles,
        OnboardingStep.matching => null,
      };

  @override
  Widget build(BuildContext context) {
    // Matching is full-bleed (its own centered layout) — no progress chrome.
    if (_step == OnboardingStep.matching) {
      return MatchingLoadingScreen(onDone: widget.onComplete);
    }

    return Scaffold(
      backgroundColor: context.c.paper,
      body: SafeArea(
        child: Column(
          children: [
            _progressHeader(),
            // KeyedSubtree so switching steps rebuilds the subtree instead
            // of reusing the previous step's State.
            Expanded(child: KeyedSubtree(key: ValueKey(_step), child: _buildStep())),
          ],
        ),
      ),
    );
  }

  Widget _progressHeader() {
    final back = _backTarget;
    final skip = _skipAction;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.space4, AppSpacing.space3, AppSpacing.space4, 0),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: back == null
                ? null
                : IconButton(
                    tooltip: 'Back',
                    onPressed: () => _goTo(back),
                    icon: AppIcon(AppIconName.chevronLeft, size: 20, color: context.c.inkSoft),
                  ),
          ),
          Expanded(
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 1; i <= _totalSteps; i++) ...[
                      if (i > 1) const SizedBox(width: 6),
                      Container(
                        width: 28,
                        height: 4,
                        decoration: BoxDecoration(
                          color: i <= _stepNumber ? context.c.accent : context.c.border,
                          borderRadius: AppRadius.pillRadius,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text('Step $_stepNumber of $_totalSteps', style: AppTypography.label.copyWith(color: context.c.inkFaint)),
              ],
            ),
          ),
          SizedBox(
            width: 56,
            child: skip == null
                ? null
                : TextButton(
                    onPressed: skip,
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    child: const Text('Skip'),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case OnboardingStep.welcome:
        return WelcomeScreen(
          name: widget.userName,
          embedded: true,
          onContinue: () => _goTo(OnboardingStep.resume),
        );
      case OnboardingStep.resume:
        return ResumeUploadScreen(
          embedded: true,
          onParsed: (profile) {
            // Server set onboarding_step='review' during the parse.
            setState(() {
              _profile = profile;
              _step = OnboardingStep.review;
            });
          },
        );
      case OnboardingStep.review:
        final profile = _profile;
        if (profile == null) {
          // Resumed at review but the profile fetch didn't come along
          // (shouldn't happen — AuthGate passes it). Fall back to upload.
          WidgetsBinding.instance.addPostFrameCallback((_) => _goTo(OnboardingStep.resume));
          return const SizedBox.shrink();
        }
        return ProfileReviewScreen(
          profile: profile,
          embedded: true,
          // PATCH /resume/profile advanced onboarding_step to 'student_info'.
          onSaved: () => _goTo(OnboardingStep.studentInfo),
        );
      case OnboardingStep.studentInfo:
        final profile = _profile;
        if (profile == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _goTo(OnboardingStep.resume));
          return const SizedBox.shrink();
        }
        return StudentInfoScreen(
          profile: profile,
          // The fork advanced onboarding_step to 'academics' or 'experience'
          // server-side; route locally to whichever branch the choice implies.
          onDone: (updated) => setState(() {
            _profile = updated;
            _step = updated.employmentType == 'student' ? OnboardingStep.academics : OnboardingStep.experience;
          }),
        );
      case OnboardingStep.academics:
        final profile = _profile;
        if (profile == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _goTo(OnboardingStep.resume));
          return const SizedBox.shrink();
        }
        return AcademicsScreen(
          profile: profile,
          // PATCH /resume/profile/academics advanced onboarding_step to 'locations'.
          onDone: (updated) => setState(() {
            _profile = updated;
            _step = OnboardingStep.locations;
          }),
        );
      case OnboardingStep.experience:
        final profile = _profile;
        if (profile == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _goTo(OnboardingStep.resume));
          return const SizedBox.shrink();
        }
        return ExperienceScreen(
          profile: profile,
          // PATCH /resume/profile/experience advanced onboarding_step to 'locations'.
          onDone: (updated) => setState(() {
            _profile = updated;
            _step = OnboardingStep.locations;
          }),
        );
      case OnboardingStep.locations:
        final profile = _profile;
        if (profile == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _goTo(OnboardingStep.resume));
          return const SizedBox.shrink();
        }
        return TargetLocationsScreen(
          profile: profile,
          // PATCH /resume/profile/target-locations advanced onboarding_step to 'roles'.
          onDone: (updated) => setState(() {
            _profile = updated;
            _step = OnboardingStep.roles;
          }),
        );
      case OnboardingStep.roles:
        return TargetRolesScreen(
          // PATCH target-roles advanced onboarding_step to 'done'.
          onDone: (_) => _goTo(OnboardingStep.matching),
        );
      case OnboardingStep.matching:
        return MatchingLoadingScreen(onDone: widget.onComplete); // unreachable (handled in build)
    }
  }
}
