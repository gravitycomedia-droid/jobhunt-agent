import 'package:flutter/material.dart';

import '../models/resume_profile.dart';
import '../services/api_client.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_form_field.dart';

/// Student branch of the onboarding fork (§4.1): the academic facts the résumé
/// parse doesn't reliably capture — branch/major, graduation year, CGPA, and
/// (only when the parser found neither) college name + USN. Everything is
/// optional; the flow's Skip advances the step regardless.
class AcademicsScreen extends StatefulWidget {
  const AcademicsScreen({super.key, required this.profile, required this.onDone});

  final ResumeProfile profile;
  final ValueChanged<ResumeProfile> onDone;

  @override
  State<AcademicsScreen> createState() => _AcademicsScreenState();
}

class _AcademicsScreenState extends State<AcademicsScreen> {
  final ApiClient _apiClient = ApiClient();
  late final _branchController = TextEditingController(text: widget.profile.branch ?? '');
  late final _gradYearController =
      TextEditingController(text: widget.profile.gradYear?.toString() ?? '');
  late final _cgpaController = TextEditingController(text: widget.profile.cgpa?.toString() ?? '');
  late final _usnController = TextEditingController();
  late final _collegeController = TextEditingController();

  bool _isSaving = false;
  String? _errorMessage;

  bool get _hasUsn => (widget.profile.usn ?? '').trim().isNotEmpty;
  bool get _hasInstitution =>
      widget.profile.education.isNotEmpty && widget.profile.education.first.institution.trim().isNotEmpty;

  @override
  void dispose() {
    _branchController.dispose();
    _gradYearController.dispose();
    _cgpaController.dispose();
    _usnController.dispose();
    _collegeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    String? trimmed(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    try {
      final profile = await _apiClient.updateAcademics(
        branch: trimmed(_branchController),
        // tryParse tolerates a stray non-numeric entry by sending null rather
        // than a 422 — the field is optional and best-effort.
        gradYear: int.tryParse(_gradYearController.text.trim()),
        cgpa: double.tryParse(_cgpaController.text.trim()),
        usn: _hasUsn ? null : trimmed(_usnController),
        collegeName: _hasInstitution ? null : trimmed(_collegeController),
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
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(AppSpacing.space5, AppSpacing.space5, AppSpacing.space5, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Your studies', style: AppTypography.headingSm),
                    const SizedBox(height: 6),
                    Text(
                      'A few academic details help match internships and fresher roles.',
                      style: AppTypography.bodySm.copyWith(color: context.c.inkSoft),
                    ),
                    const SizedBox(height: AppSpacing.space5),
                    AppFormField(label: 'Branch / major', placeholder: 'e.g. Computer Science', controller: _branchController),
                    const SizedBox(height: AppSpacing.space3),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: AppFormField(
                            label: 'Graduation year',
                            placeholder: 'e.g. 2026',
                            controller: _gradYearController,
                            keyboardType: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.space3),
                        Expanded(
                          child: AppFormField(
                            label: 'CGPA',
                            placeholder: 'e.g. 8.4',
                            controller: _cgpaController,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          ),
                        ),
                      ],
                    ),
                    if (!_hasInstitution) ...[
                      const SizedBox(height: AppSpacing.space3),
                      AppFormField(label: 'College / university name', controller: _collegeController),
                    ],
                    if (!_hasUsn) ...[
                      const SizedBox(height: AppSpacing.space3),
                      AppFormField(
                        label: 'USN / roll number',
                        hint: 'Optional — not on your resume, so we can\'t verify it',
                        controller: _usnController,
                      ),
                    ],
                    if (_errorMessage != null) ...[
                      const SizedBox(height: AppSpacing.space3),
                      Text(_errorMessage!, style: AppTypography.bodySm.copyWith(color: context.c.critical)),
                    ],
                    const SizedBox(height: AppSpacing.space5),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.space5, 0, AppSpacing.space5, AppSpacing.space5),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isSaving ? null : _submit,
                  child: Text(_isSaving ? 'Saving…' : 'Continue'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
