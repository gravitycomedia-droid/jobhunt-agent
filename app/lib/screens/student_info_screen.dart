import 'package:flutter/material.dart';

import '../models/resume_profile.dart';
import '../services/api_client.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_icon.dart';

/// The onboarding fork (§4.1): student vs. experienced professional. One card
/// settles, the other recedes; the choice routes the flow to the matching
/// branch-detail step (academics for students, experience for professionals).
///
/// Phase 6 simplified this to the pure fork — the USN/college ask it used to
/// carry moved to [AcademicsScreen] (the student branch), so this screen makes
/// exactly one decision and nothing else.
class StudentInfoScreen extends StatefulWidget {
  const StudentInfoScreen({super.key, required this.profile, required this.onDone});

  final ResumeProfile profile;

  /// Fires with the server-updated profile — its `employmentType` tells the
  /// flow which branch screen to show next.
  final ValueChanged<ResumeProfile> onDone;

  @override
  State<StudentInfoScreen> createState() => _StudentInfoScreenState();
}

class _StudentInfoScreenState extends State<StudentInfoScreen> {
  final ApiClient _apiClient = ApiClient();

  String? _employmentType;
  bool _isSaving = false;
  String? _errorMessage;

  Future<void> _submit() async {
    final employmentType = _employmentType;
    if (employmentType == null) return;
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      final profile = await _apiClient.updateStudentInfo(employmentType: employmentType);
      if (!mounted) return;
      widget.onDone(profile);
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.space5, AppSpacing.space5, AppSpacing.space5, AppSpacing.space6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Where are you right now?', style: AppTypography.headingSm),
              const SizedBox(height: 6),
              Text(
                'This tailors what the agent asks next and how it frames your background.',
                style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.space5),
              Row(
                children: [
                  Expanded(
                    child: _typeCard(
                      icon: AppIconName.fileText,
                      label: 'Student',
                      caption: 'Still studying',
                      selected: _employmentType == 'student',
                      onTap: () => setState(() => _employmentType = 'student'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.space3),
                  Expanded(
                    child: _typeCard(
                      icon: AppIconName.trendingUp,
                      label: 'Experienced',
                      caption: 'Working now',
                      selected: _employmentType == 'experienced',
                      onTap: () => setState(() => _employmentType = 'experienced'),
                    ),
                  ),
                ],
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: AppSpacing.space3),
                Text(_errorMessage!, style: AppTypography.bodySm.copyWith(color: AppColors.criticalText)),
              ],
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isSaving || _employmentType == null ? null : _submit,
                  child: Text(_isSaving ? 'Saving…' : 'Continue'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _typeCard({
    required AppIconName icon,
    required String label,
    required String caption,
    required bool selected,
    required VoidCallback onTap,
  }) {
    // AnimatedScale gives the "one card settles, the other recedes" motion from
    // §4.1 — the picked card sits at full size, the unpicked one shrinks back.
    final anyPicked = _employmentType != null;
    return AnimatedScale(
      duration: const Duration(milliseconds: 180),
      scale: !anyPicked || selected ? 1.0 : 0.96,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.lgRadius,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.space5, horizontal: AppSpacing.space3),
          decoration: BoxDecoration(
            color: selected ? AppColors.brandSoft : AppColors.surface,
            border: Border.all(color: selected ? AppColors.brand500 : AppColors.border, width: selected ? 1.5 : 1),
            borderRadius: AppRadius.lgRadius,
          ),
          child: Column(
            children: [
              AppIcon(icon, size: 26, color: selected ? AppColors.brand600 : AppColors.textSecondary),
              const SizedBox(height: AppSpacing.space2),
              Text(
                label,
                style: AppTypography.title.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: selected ? AppColors.brand700 : AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(caption, style: AppTypography.caption.copyWith(color: AppColors.textTertiary)),
            ],
          ),
        ),
      ),
    );
  }
}
