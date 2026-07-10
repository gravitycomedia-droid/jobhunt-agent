import 'package:flutter/material.dart';

import 'matching_loading_screen.dart';
import 'resume_upload_screen.dart';
import 'target_roles_screen.dart';
import 'welcome_screen.dart';

/// Frontend rebuild Phase 1: the linear onboarding chain shown once, right
/// after first sign-in, when the caller's profile doesn't exist yet —
/// Welcome → Upload Resume → Profile Review → Target Roles → Matching
/// (loading) → [onComplete], which [AuthGate] wires to swap this whole
/// subtree out for [MainTabScreen]. Each step's "done" callback pushes the
/// next step onto the SAME Navigator (so the back button walks backward
/// through onboarding, which is useful for fixing a typo) rather than each
/// step owning its own routing decision — keeps the sequence in one place
/// instead of scattered across screens that shouldn't need to know what
/// comes after them.
class OnboardingFlow extends StatelessWidget {
  const OnboardingFlow({super.key, required this.userName, required this.onComplete});

  final String userName;
  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) {
    return WelcomeScreen(
      name: userName,
      onContinue: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (uploadContext) => ResumeUploadScreen(
            onSkip: onComplete,
            onProfileReviewDone: () => Navigator.of(uploadContext).push(
              MaterialPageRoute(
                builder: (rolesContext) => TargetRolesScreen(
                  onDone: (_) => Navigator.of(rolesContext).push(
                    MaterialPageRoute(builder: (_) => MatchingLoadingScreen(onDone: onComplete)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
