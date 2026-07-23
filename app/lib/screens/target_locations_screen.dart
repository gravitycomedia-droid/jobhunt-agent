import 'package:flutter/material.dart';

import '../models/resume_profile.dart';
import '../services/api_client.dart';
import '../services/job_filter.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_icon.dart';

/// Target-locations step of onboarding (§4.1). Multi-select landmark chips over
/// the same [kFilterLocations] set the jobs filter uses, so the cities a user
/// picks here line up exactly with the ones they can later filter on. Optional
/// — an empty selection is a valid "no preference" and still advances.
class TargetLocationsScreen extends StatefulWidget {
  const TargetLocationsScreen({super.key, required this.profile, required this.onDone});

  final ResumeProfile profile;
  final ValueChanged<ResumeProfile> onDone;

  @override
  State<TargetLocationsScreen> createState() => _TargetLocationsScreenState();
}

class _TargetLocationsScreenState extends State<TargetLocationsScreen> {
  final ApiClient _apiClient = ApiClient();
  late final Set<String> _selected = {...widget.profile.targetLocations};

  bool _isSaving = false;
  String? _errorMessage;

  Future<void> _submit() async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      final profile = await _apiClient.updateTargetLocations(_selected.toList());
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
          padding: const EdgeInsets.fromLTRB(AppSpacing.space5, AppSpacing.space5, AppSpacing.space5, AppSpacing.space5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Where do you want to work?', style: AppTypography.headingSm),
              const SizedBox(height: 6),
              Text(
                'Pick any that fit — you can change these anytime from the jobs filter.',
                style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.space5),
              Wrap(
                spacing: AppSpacing.space3,
                runSpacing: AppSpacing.space3,
                children: [
                  for (final opt in kFilterLocations)
                    _locationChip(
                      label: opt.label,
                      icon: opt.isRemote ? AppIconName.home : AppIconName.mapPin,
                      selected: _selected.contains(opt.label),
                      onTap: () => setState(() {
                        _selected.contains(opt.label) ? _selected.remove(opt.label) : _selected.add(opt.label);
                      }),
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
                  onPressed: _isSaving ? null : _submit,
                  child: Text(_isSaving ? 'Saving…' : 'Continue'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _locationChip({
    required String label,
    required AppIconName icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.pillRadius,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space4, vertical: AppSpacing.space3),
        decoration: BoxDecoration(
          color: selected ? AppColors.brandSoft : AppColors.surface,
          border: Border.all(color: selected ? AppColors.brand500 : AppColors.border, width: selected ? 1.5 : 1),
          borderRadius: AppRadius.pillRadius,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(icon, size: 16, color: selected ? AppColors.brand600 : AppColors.textSecondary),
            const SizedBox(width: 6),
            Text(
              label,
              style: AppTypography.body.copyWith(
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
