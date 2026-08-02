import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
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

  // Static fallback if the suggestions fetch fails (offline, cold start) —
  // never leave the chip row empty just because one GET didn't land.
  List<String> _dbSuggestions = const [];
  List<String> _otherSuggestions = const ['Flutter Developer', 'Python Developer', 'Mobile Developer'];

  @override
  void initState() {
    super.initState();
    _loadSuggestions();
  }

  /// Roles the job pool actually has postings for (busiest first), then a
  /// curated list of common roles the pool doesn't specifically label —
  /// see api_client.dart's getRoleSuggestions(). Best-effort: a failed fetch
  /// just keeps the static fallback list rather than blocking this screen.
  Future<void> _loadSuggestions() async {
    try {
      final result = await _apiClient.getRoleSuggestions();
      if (!mounted) return;
      setState(() {
        _dbSuggestions = result.dbRoles;
        _otherSuggestions = result.otherRoles;
      });
    } catch (_) {
      // Keep the static fallback — this is a suggestion list, not core data.
    }
  }

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
        child: Column(
          children: [
            // ADR-054: DB-backed suggestions can run to ~19 chips (vs the old
            // hardcoded 3), which routinely overflows a fixed-height Column —
            // that overflow was pushing "Find matching jobs" off-screen and
            // unreachable. Scrollable content + a footer pinned outside the
            // scroll (same pattern as resume_diff_screen.dart) fixes it for
            // any suggestion-list length, not just today's.
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.space5,
                  AppSpacing.space5,
                  AppSpacing.space5,
                  AppSpacing.space3,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('What are you looking for?', style: AppTypography.headingSm),
                    const SizedBox(height: 6),
                    Text(
                      'Add target roles. The agent matches new postings against these.',
                      style: AppTypography.bodySm.copyWith(color: context.c.inkSoft),
                    ),
                    const SizedBox(height: AppSpacing.space5),
                    ChipInput(
                      label: 'Target roles',
                      value: _roles,
                      onChange: (next) => setState(() => _roles = next),
                      placeholder: 'Add a role…',
                    ),
                    const SizedBox(height: 4),
                    // Roles the job pool actually has postings for right now,
                    // so picking one isn't a shot in the dark — then a
                    // curated list of other common roles the pool doesn't
                    // specifically label.
                    if (_dbSuggestions.any((s) => !_roles.contains(s))) ...[
                      _suggestionGroup(_dbSuggestions),
                      if (_otherSuggestions.any((s) => !_roles.contains(s))) ...[
                        const SizedBox(height: 6),
                        Text('More roles', style: AppTypography.caption.copyWith(color: context.c.inkSoft)),
                        const SizedBox(height: 4),
                      ],
                    ],
                    _suggestionGroup(_otherSuggestions),
                    const SizedBox(height: AppSpacing.space5),
                    AppFormField(
                      label: 'Minimum salary (optional)',
                      controller: _salaryController,
                      placeholder: '150000',
                      keyboardType: TextInputType.number,
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.space5, 0, AppSpacing.space5, AppSpacing.space5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_errorMessage != null) ...[
                    Text(_errorMessage!, style: AppTypography.bodySm.copyWith(color: context.c.critical)),
                    const SizedBox(height: AppSpacing.space3),
                  ],
                  ElevatedButton(
                    onPressed: _isSaving ? null : _submit,
                    child: Text(_isSaving ? 'Saving…' : 'Find matching jobs'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _suggestionGroup(List<String> suggestions) {
    return Wrap(
      spacing: 7,
      runSpacing: 7,
      children: [
        for (final s in suggestions)
          if (!_roles.contains(s))
            OutlinedButton.icon(
              onPressed: () => setState(() => _roles = [..._roles, s]),
              icon: const Icon(Icons.add, size: 14),
              label: Text(s),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                side: BorderSide(color: context.c.border),
                shape: const StadiumBorder(),
              ),
            ),
      ],
    );
  }
}
