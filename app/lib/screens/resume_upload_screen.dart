import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/resume_profile.dart';
import '../services/api_client.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/page_header.dart';
import 'profile_review_screen.dart';

/// Roughly the FlutterFlow "Upload File" action + a button, hand-written.
///
/// Phase 3B: deliberately NOT skippable during onboarding — the whole
/// product depends on a parsed profile (the old "Skip for now" dropped the
/// user into an app full of empty states). The copy below sets that
/// expectation instead.
class ResumeUploadScreen extends StatefulWidget {
  const ResumeUploadScreen({super.key, this.onProfileReviewDone, this.onParsed, this.embedded = false});

  /// Standalone mode (Profile tab re-upload): forwarded as the pushed
  /// [ProfileReviewScreen]'s `onSaved`. Ignored when [onParsed] is set.
  final VoidCallback? onProfileReviewDone;

  /// Phase 3B onboarding mode: called with the parsed profile instead of
  /// this screen pushing review itself — [OnboardingFlow]'s step machine
  /// owns what comes next.
  final ValueChanged<ResumeProfile>? onParsed;

  /// True inside [OnboardingFlow] (progress chrome already provided, and
  /// there is no route to pop — hide our own header/back).
  final bool embedded;

  @override
  State<ResumeUploadScreen> createState() => _ResumeUploadScreenState();
}

class _ResumeUploadScreenState extends State<ResumeUploadScreen> {
  final ApiClient _apiClient = ApiClient();

  bool _isUploading = false;
  String? _errorMessage;

  Future<void> _pickAndUpload() async {
    // `withData: true` is required on web (there's no real filesystem path
    // to read from later), and it's simplest to just always ask for bytes.
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      withData: true,
    );

    // `result` is nullable (`FilePickerResult?`) because the user might
    // cancel the picker instead of choosing a file — that's a normal case,
    // not an error, so we just return quietly.
    if (result == null) return;

    final bytes = result.files.single.bytes;
    if (bytes == null) {
      setState(() => _errorMessage = 'Could not read the selected file.');
      return;
    }

    setState(() {
      _isUploading = true;
      _errorMessage = null;
    });

    try {
      final profile = await _apiClient.parseResume(bytes, result.files.single.name);
      if (!mounted) return;
      if (widget.onParsed != null) {
        widget.onParsed!(profile); // onboarding: the flow decides what's next
      } else {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ProfileReviewScreen(profile: profile, onSaved: widget.onProfileReviewDone)),
        );
      }
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embedded ? null : const PageHeader(title: 'Upload Resume', showBack: true),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: AppColors.brandSoft, shape: BoxShape.circle),
                child: const AppIcon(AppIconName.fileText, size: 32, color: AppColors.brand600),
              ),
              const SizedBox(height: AppSpacing.space4),
              Text(
                'Upload your resume as a PDF to get started.',
                textAlign: TextAlign.center,
                style: AppTypography.body.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.space6),
              if (_isUploading) ...[
                const CircularProgressIndicator(color: AppColors.brand),
                const SizedBox(height: AppSpacing.space3),
                // Phase 2 honest copy: parsing is a real vision-LLM call.
                Text(
                  'Reading your resume with AI — this usually takes 30–60 seconds. '
                  'Keep the app open.',
                  textAlign: TextAlign.center,
                  style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
                ),
              ] else
                ElevatedButton.icon(
                  onPressed: _pickAndUpload,
                  icon: const AppIcon(AppIconName.upload, size: 18, color: AppColors.textOnBrand),
                  label: const Text('Choose PDF'),
                ),
              if (_errorMessage != null) ...[
                const SizedBox(height: AppSpacing.space4),
                Text(
                  _errorMessage!,
                  style: AppTypography.bodySm.copyWith(color: AppColors.criticalText),
                  textAlign: TextAlign.center,
                ),
              ],
              if (widget.embedded && !_isUploading) ...[
                const SizedBox(height: AppSpacing.space4),
                // Phase 3B: honest no-skip copy — everything downstream
                // (matching, tailoring, tracking) needs a profile.
                Text(
                  'This step can\'t be skipped — the agent matches and tailors '
                  'against your real resume.',
                  textAlign: TextAlign.center,
                  style: AppTypography.caption.copyWith(color: AppColors.textTertiary),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
