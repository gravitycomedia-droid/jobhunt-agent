import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import '../widgets/app_icon.dart';

class _WelcomeStep {
  const _WelcomeStep(this.n, this.title, this.desc);
  final int n;
  final String title;
  final String desc;
}

const _steps = [
  _WelcomeStep(1, 'Upload your resume', 'We parse it into a structured profile in seconds.'),
  _WelcomeStep(2, 'We find and score matches', 'Every posting gets a fit score with real reasoning.'),
  _WelcomeStep(3, 'Tailor and track', 'Tailor bullets per job, then track the pipeline to offer.'),
];

/// Onboarding step 2 (frontend rebuild Phase 1, prototype `ui.isWelcome`):
/// shown once right after first sign-in, before the resume upload step.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key, required this.name, required this.onContinue});

  final String name;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space6, vertical: AppSpacing.space6),
          child: Column(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 76,
                      height: 76,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(color: AppColors.brandSoft, shape: BoxShape.circle),
                      child: const AppIcon(AppIconName.check, size: 36, color: AppColors.brand600),
                    ),
                    const SizedBox(height: AppSpacing.space3),
                    Text("You're all set, $name", style: AppTypography.headingSm, textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    Text(
                      "Here's how the agent works. Three steps and you'll have tailored applications going out.",
                      textAlign: TextAlign.center,
                      style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: AppSpacing.space5),
                    Column(
                      children: [
                        for (final step in _steps) ...[
                          _StepRow(step: step),
                          if (step != _steps.last) const SizedBox(height: AppSpacing.space2),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(onPressed: onContinue, child: const Text('Upload your resume')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step});
  final _WelcomeStep step;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.space3),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: AppRadius.lgRadius,
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: AppColors.brandSoft, shape: BoxShape.circle),
            child: Text(
              '${step.n}',
              style: TextStyle(fontFamily: AppTypography.monoData.fontFamily, fontWeight: FontWeight.w700, fontSize: 15, color: AppColors.brand700),
            ),
          ),
          const SizedBox(width: AppSpacing.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(step.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                Text(step.desc, style: AppTypography.caption.copyWith(color: AppColors.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
