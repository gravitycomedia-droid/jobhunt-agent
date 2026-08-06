import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_form_field.dart';
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
///
/// Plan 21: also hosts the optional invite-code field. It lives here rather
/// than in a new onboarding step on purpose — [OnboardingStep] is mirrored by
/// the server's `onboarding_step` column (migration 011), so a new step would
/// mean a migration and a resume-point change for a field that is entirely
/// skippable. Redeeming here still lands well before the first
/// MatchingLoadingScreen run, which is what the bonus needs to affect.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key, required this.name, required this.onContinue, this.embedded = false});

  final String name;
  final VoidCallback onContinue;

  /// Phase 3B: true when rendered inside [OnboardingFlow]'s step machine,
  /// which already provides the Scaffold + progress chrome.
  final bool embedded;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final ApiClient _apiClient = ApiClient();
  final TextEditingController _codeController = TextEditingController();

  bool _showCodeField = false;
  bool _isRedeeming = false;
  String? _codeError;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  /// Skippable by construction: an empty field just continues. A non-empty one
  /// must succeed before we move on — otherwise a typo'd code would be silently
  /// swallowed and the user would never learn their bonus didn't apply.
  Future<void> _continue() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      widget.onContinue();
      return;
    }

    setState(() {
      _isRedeeming = true;
      _codeError = null;
    });
    try {
      await _apiClient.redeemReferralCode(code);
      if (!mounted) return;
      setState(() => _isRedeeming = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invite applied — you both got 5 bonus matches')),
      );
      widget.onContinue();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isRedeeming = false;
        // The server's 400 detail is written to be shown as-is ("That invite
        // code isn't valid.", "You can't use your own invite code.").
        _codeError = _cleanError(e);
      });
    }
  }

  /// ApiClient wraps failures as `Exception: <detail>`; strip the prefix so the
  /// inline error reads as a sentence rather than a stack-trace fragment.
  String _cleanError(Object e) => e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');

  @override
  Widget build(BuildContext context) {
    final name = widget.name;
    final body = Padding(
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
                      decoration: BoxDecoration(color: context.c.accentSoft, shape: BoxShape.circle),
                      child: AppIcon(AppIconName.check, size: 36, color: context.c.accent),
                    ),
                    const SizedBox(height: AppSpacing.space3),
                    Text("You're all set, $name", style: AppTypography.headingSm, textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    Text(
                      "Here's how the agent works. Three steps and you'll have tailored applications going out.",
                      textAlign: TextAlign.center,
                      style: AppTypography.bodySm.copyWith(color: context.c.inkSoft),
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
                    const SizedBox(height: AppSpacing.space4),
                    _inviteCodeSection(context),
                  ],
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isRedeeming ? null : _continue,
                  child: _isRedeeming
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Upload your resume'),
                ),
              ),
            ],
          ),
    );

    if (widget.embedded) return body;
    return Scaffold(body: SafeArea(child: body));
  }

  /// Collapsed to a single link by default. Most users arrive without a code,
  /// and a permanently-visible empty field on the very first screen reads as
  /// something you're required to deal with.
  Widget _inviteCodeSection(BuildContext context) {
    if (!_showCodeField) {
      return TextButton(
        onPressed: () => setState(() => _showCodeField = true),
        child: const Text('Got an invite code?'),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppFormField(
          label: 'Invite code',
          controller: _codeController,
          placeholder: 'e.g. K7M2Q9X',
          hint: 'Optional — you and your friend both get 5 bonus matches.',
          error: _codeError,
          disabled: _isRedeeming,
          // No forced uppercasing here — normalize_code() on the server upper-
          // cases and strips spaces/hyphens, so "k7m2 q9x" resolves fine.
          onChanged: (_) {
            // Clear a stale error the moment they start fixing it.
            if (_codeError != null) setState(() => _codeError = null);
          },
        ),
      ],
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
        color: context.c.surface,
        border: Border.all(color: context.c.border),
        borderRadius: AppRadius.lgRadius,
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: context.c.accentSoft, shape: BoxShape.circle),
            child: Text(
              '${step.n}',
              style: TextStyle(fontFamily: AppTypography.monoData.fontFamily, fontWeight: FontWeight.w700, fontSize: 15, color: context.c.accent),
            ),
          ),
          const SizedBox(width: AppSpacing.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(step.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                Text(step.desc, style: AppTypography.caption.copyWith(color: context.c.inkSoft)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
