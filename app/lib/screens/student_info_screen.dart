import 'package:flutter/material.dart';

import '../models/resume_profile.dart';
import '../services/api_client.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_form_field.dart';
import '../widgets/app_icon.dart';

/// Onboarding step between Review and Target Roles (server's
/// `student_info`, migration 014): "student or experienced professional?",
/// plus USN + college name for students — but only asked when the resume
/// parser (services/llm.py) didn't already find them, so most non-student
/// resumes skip both extra fields entirely.
class StudentInfoScreen extends StatefulWidget {
  const StudentInfoScreen({super.key, required this.profile, required this.onDone});

  final ResumeProfile profile;
  final ValueChanged<ResumeProfile> onDone;

  @override
  State<StudentInfoScreen> createState() => _StudentInfoScreenState();
}

class _StudentInfoScreenState extends State<StudentInfoScreen> {
  final ApiClient _apiClient = ApiClient();
  late final _usnController = TextEditingController();
  late final _collegeController = TextEditingController();

  String? _employmentType;
  bool _isSaving = false;
  String? _errorMessage;

  bool get _hasUsn => (widget.profile.usn ?? '').trim().isNotEmpty;
  bool get _hasInstitution =>
      widget.profile.education.isNotEmpty && widget.profile.education.first.institution.trim().isNotEmpty;

  @override
  void dispose() {
    _usnController.dispose();
    _collegeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final employmentType = _employmentType;
    if (employmentType == null) return;
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      final profile = await _apiClient.updateStudentInfo(
        employmentType: employmentType,
        usn: _usnController.text.trim().isEmpty ? null : _usnController.text.trim(),
        collegeName: _collegeController.text.trim().isEmpty ? null : _collegeController.text.trim(),
      );
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
    final showStudentFields = _employmentType == 'student' && (!_hasUsn || !_hasInstitution);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.space5, AppSpacing.space5, AppSpacing.space5, AppSpacing.space6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('A bit more about you', style: AppTypography.headingSm),
              const SizedBox(height: 6),
              Text(
                'Helps the agent tailor how it talks about your background.',
                style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.space5),
              Row(
                children: [
                  Expanded(
                    child: _typeCard(
                      icon: AppIconName.fileText,
                      label: 'Student',
                      selected: _employmentType == 'student',
                      onTap: () => setState(() => _employmentType = 'student'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.space3),
                  Expanded(
                    child: _typeCard(
                      icon: AppIconName.trendingUp,
                      label: 'Experienced',
                      selected: _employmentType == 'experienced',
                      onTap: () => setState(() => _employmentType = 'experienced'),
                    ),
                  ),
                ],
              ),
              if (showStudentFields) ...[
                const SizedBox(height: AppSpacing.space5),
                if (!_hasInstitution) ...[
                  AppFormField(label: 'College / university name', controller: _collegeController),
                  const SizedBox(height: AppSpacing.space3),
                ],
                if (!_hasUsn)
                  AppFormField(
                    label: 'USN / roll number',
                    hint: 'Optional — not on your resume, so we can\'t verify it',
                    controller: _usnController,
                  ),
              ],
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
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.lgRadius,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.space4),
        decoration: BoxDecoration(
          color: selected ? AppColors.brandSoft : AppColors.surface,
          border: Border.all(color: selected ? AppColors.brand500 : AppColors.border, width: selected ? 1.5 : 1),
          borderRadius: AppRadius.lgRadius,
        ),
        child: Column(
          children: [
            AppIcon(icon, size: 24, color: selected ? AppColors.brand600 : AppColors.textSecondary),
            const SizedBox(height: AppSpacing.space2),
            Text(
              label,
              style: AppTypography.title.copyWith(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: selected ? AppColors.brand700 : AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
