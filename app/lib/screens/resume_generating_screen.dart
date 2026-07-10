import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'resume_preview_screen.dart';

/// Transitional screen between the tailoring diff and the compiled resume
/// preview (frontend rebuild Phase 2, prototype `ui.isResumeGenerating`).
/// There's no real server-side "compilation" step — the tailored resume
/// was already generated and approved on the previous screen; this is a
/// short, deliberate pause before [ResumePreviewScreen] so the "Generate"
/// action reads as consequential rather than instant. Replaces itself
/// with the preview (not a push) so the back button from the preview
/// returns to the diff screen, not this transitional one.
class ResumeGeneratingScreen extends StatefulWidget {
  const ResumeGeneratingScreen({super.key, required this.jobId, required this.jobTitle});

  final String jobId;
  final String jobTitle;

  @override
  State<ResumeGeneratingScreen> createState() => _ResumeGeneratingScreenState();
}

class _ResumeGeneratingScreenState extends State<ResumeGeneratingScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ResumePreviewScreen(jobId: widget.jobId, jobTitle: widget.jobTitle)),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 76,
                height: 76,
                child: CircularProgressIndicator(strokeWidth: 5, color: AppColors.brand600),
              ),
              const SizedBox(height: AppSpacing.space5),
              Text('Compiling your tailored resume', style: AppTypography.title),
              const SizedBox(height: 6),
              Text(
                'Applying your accepted edits for ${widget.jobTitle}.',
                style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
