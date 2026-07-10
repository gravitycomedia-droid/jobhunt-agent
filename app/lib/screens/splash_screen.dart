import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import '../widgets/app_icon.dart';

/// Onboarding step 1 (frontend rebuild Phase 1, prototype `ui.isSplash`):
/// the brand cover shown before a session exists. [onGetStarted] and
/// [onSignIn] both lead to the same [AuthScreen] — the prototype
/// distinguishes them only to pre-select the sign-up vs sign-in tab.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key, required this.onGetStarted, required this.onSignIn});

  final VoidCallback onGetStarted;
  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.brand600,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.space6, AppSpacing.space8, AppSpacing.space6, AppSpacing.space6),
          child: Column(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 92,
                      height: 92,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), borderRadius: AppRadius.xlRadius),
                      child: const AppIcon(AppIconName.target, size: 46, color: Colors.white),
                    ),
                    const SizedBox(height: AppSpacing.space5),
                    RichText(
                      textAlign: TextAlign.center,
                      text: TextSpan(
                        style: const TextStyle(fontSize: 33, fontWeight: FontWeight.w800, letterSpacing: -0.4, color: Colors.white),
                        children: [
                          const TextSpan(text: 'JobHunt '),
                          TextSpan(text: 'Agent', style: TextStyle(fontWeight: FontWeight.w400, color: Colors.white.withValues(alpha: 0.82))),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Your AI job-search partner — from resume to signed offer.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 15, height: 1.45, color: Colors.white.withValues(alpha: 0.86)),
                    ),
                  ],
                ),
              ),
              Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: onGetStarted,
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: AppColors.brand700),
                      child: const Text('Get started'),
                    ),
                  ),
                  const SizedBox(height: 11),
                  TextButton(
                    onPressed: onSignIn,
                    style: TextButton.styleFrom(foregroundColor: Colors.white.withValues(alpha: 0.92)),
                    child: const Text('I already have an account'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
