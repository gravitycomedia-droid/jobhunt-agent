import 'package:flutter/material.dart';

import '../models/resume_profile.dart';
import '../services/api_client.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_form_field.dart';

/// Professional branch of the onboarding fork (§4.1): current employer, total
/// years of experience, and notice period. All optional; the flow's Skip
/// advances the step regardless.
class ExperienceScreen extends StatefulWidget {
  const ExperienceScreen({super.key, required this.profile, required this.onDone});

  final ResumeProfile profile;
  final ValueChanged<ResumeProfile> onDone;

  @override
  State<ExperienceScreen> createState() => _ExperienceScreenState();
}

class _ExperienceScreenState extends State<ExperienceScreen> {
  final ApiClient _apiClient = ApiClient();
  late final _companyController = TextEditingController(text: widget.profile.company ?? '');
  late final _yearsController =
      TextEditingController(text: widget.profile.experienceYears?.toString() ?? '');
  late final _noticeController =
      TextEditingController(text: widget.profile.noticePeriodDays?.toString() ?? '');

  bool _isSaving = false;
  String? _errorMessage;

  @override
  void dispose() {
    _companyController.dispose();
    _yearsController.dispose();
    _noticeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      final profile = await _apiClient.updateExperience(
        company: _companyController.text.trim().isEmpty ? null : _companyController.text.trim(),
        experienceYears: double.tryParse(_yearsController.text.trim()),
        noticePeriodDays: int.tryParse(_noticeController.text.trim()),
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
                    Text('Your work', style: AppTypography.headingSm),
                    const SizedBox(height: 6),
                    Text(
                      'Helps the agent weigh seniority and time-to-join against each role.',
                      style: AppTypography.bodySm.copyWith(color: context.c.inkSoft),
                    ),
                    const SizedBox(height: AppSpacing.space5),
                    AppFormField(label: 'Current company', placeholder: 'e.g. Infosys', controller: _companyController),
                    const SizedBox(height: AppSpacing.space3),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: AppFormField(
                            label: 'Years of experience',
                            placeholder: 'e.g. 3',
                            controller: _yearsController,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.space3),
                        Expanded(
                          child: AppFormField(
                            label: 'Notice period (days)',
                            placeholder: 'e.g. 30',
                            controller: _noticeController,
                            keyboardType: TextInputType.number,
                          ),
                        ),
                      ],
                    ),
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
