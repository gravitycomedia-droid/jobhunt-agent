import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_form_field.dart';
import '../widgets/chip_input.dart';

/// Onboarding step 4 (frontend rebuild Phase 1, prototype `ui.isRoles`):
/// "What are you looking for?" — target roles feed matching (though not
/// yet wired into server/jobs/daily_pipeline.py's fetch step, which still
/// reads the global TARGET_ROLES env var; see DECISIONS.md). [onDone]
/// distinguishes onboarding (chain into MatchingLoadingScreen) from a
/// later revisit from the Profile tab (just pop back).
class TargetRolesScreen extends StatefulWidget {
  const TargetRolesScreen({
    super.key,
    this.initialRoles = const [],
    this.initialMinSalary,
    required this.onDone,
  });

  final List<String> initialRoles;
  final double? initialMinSalary;
  final ValueChanged<List<String>> onDone;

  @override
  State<TargetRolesScreen> createState() => _TargetRolesScreenState();
}

class _TargetRolesScreenState extends State<TargetRolesScreen> {
  final ApiClient _apiClient = ApiClient();
  late List<String> _roles = List.of(widget.initialRoles);
  late final _salaryController = TextEditingController(
    text: widget.initialMinSalary == null ? '' : widget.initialMinSalary!.round().toString(),
  );

  bool _isSaving = false;
  String? _errorMessage;

  static const _suggestions = ['Flutter Developer', 'Python Developer', 'Mobile Developer'];

  @override
  void dispose() {
    _salaryController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    final minSalary = double.tryParse(_salaryController.text.trim());
    try {
      await _apiClient.updateTargetRoles(_roles, minSalary);
      if (!mounted) return;
      widget.onDone(_roles);
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
              Text('What are you looking for?', style: AppTypography.headingSm),
              const SizedBox(height: 6),
              Text(
                'Add target roles. The agent matches new postings against these.',
                style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.space5),
              ChipInput(
                label: 'Target roles',
                value: _roles,
                onChange: (next) => setState(() => _roles = next),
                placeholder: 'Add a role…',
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final s in _suggestions)
                    if (!_roles.contains(s))
                      OutlinedButton.icon(
                        onPressed: () => setState(() => _roles = [..._roles, s]),
                        icon: const Icon(Icons.add, size: 14),
                        label: Text(s),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          side: const BorderSide(color: AppColors.borderStrong),
                          shape: const StadiumBorder(),
                        ),
                      ),
                ],
              ),
              const SizedBox(height: AppSpacing.space5),
              AppFormField(
                label: 'Minimum salary (optional)',
                controller: _salaryController,
                placeholder: '150000',
                keyboardType: TextInputType.number,
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: AppSpacing.space3),
                Text(_errorMessage!, style: AppTypography.bodySm.copyWith(color: AppColors.criticalText)),
              ],
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isSaving ? null : _submit,
                  child: Text(_isSaving ? 'Saving…' : 'Find matching jobs'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
