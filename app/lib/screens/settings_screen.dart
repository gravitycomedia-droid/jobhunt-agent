import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/haptic_service.dart';
import '../services/theme_controller.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_icon.dart';
import '../widgets/page_header.dart';
import 'resume_upload_screen.dart';

/// Phase 4 (prototype `ui.isSettings`, "Notifications" group only — the
/// prototype's "Agent" group is dropped: autoApply conflicts with
/// CLAUDE.md's "no auto-submitting anywhere" rule, and autoTailor has no
/// pipeline behavior behind it to gate). Both toggles here PATCH
/// immediately on tap (no separate Save button, matching the prototype's
/// `act.toggle` behavior) and gate calls jobs/daily_pipeline.py already
/// makes unconditionally — see server/routers/resume.py's
/// notification-prefs endpoint.
///
/// A "RESUME" group (re-upload) was added on top of the prototype — the
/// prototype only put resume re-upload under Profile → Parsed profile →
/// "Re-upload resume". Settings is a second, equally-discoverable entry
/// point into the same [ResumeUploadScreen] flow, not a separate feature.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.initialAlerts, required this.initialFollowupNudge});

  final bool initialAlerts;
  final bool initialFollowupNudge;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final ApiClient _apiClient = ApiClient();

  late bool _alerts = widget.initialAlerts;
  late bool _followupNudge = widget.initialFollowupNudge;
  bool _isSavingAlerts = false;
  bool _isSavingFollowupNudge = false;
  // Local mirror of the persisted haptics preference; there was no UI for it
  // before, so the on/off switch in HapticService could never be toggled.
  bool _haptics = HapticService.instance.enabled;

  void _setHaptics(bool value) {
    setState(() => _haptics = value);
    HapticService.instance.setEnabled(value);
    // Fire once so enabling it gives immediate tactile confirmation.
    if (value) HapticService.instance.selection();
  }

  Future<void> _setAlerts(bool value) async {
    final previous = _alerts;
    setState(() {
      _alerts = value;
      _isSavingAlerts = true;
    });
    try {
      await _apiClient.updateNotificationPrefs(alerts: value, followupNudge: _followupNudge);
    } catch (e) {
      if (!mounted) return;
      setState(() => _alerts = previous);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
    } finally {
      if (mounted) setState(() => _isSavingAlerts = false);
    }
  }

  Future<void> _setFollowupNudge(bool value) async {
    final previous = _followupNudge;
    setState(() {
      _followupNudge = value;
      _isSavingFollowupNudge = true;
    });
    try {
      await _apiClient.updateNotificationPrefs(alerts: _alerts, followupNudge: value);
    } catch (e) {
      if (!mounted) return;
      setState(() => _followupNudge = previous);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
    } finally {
      if (mounted) setState(() => _isSavingFollowupNudge = false);
    }
  }

  Future<void> _updateResume() async {
    HapticService.instance.selection();
    final navigator = Navigator.of(context);
    await navigator.push(
      MaterialPageRoute(
        builder: (_) => ResumeUploadScreen(
          // ResumeUploadScreen -> ProfileReviewScreen is a two-deep push;
          // ProfileReviewScreen only pops itself when onSaved is null (see
          // its _confirm), so with onSaved set here it's on us to pop both
          // routes and land back on Settings ourselves.
          onProfileReviewDone: () => navigator
            ..pop()
            ..pop(),
        ),
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Resume updated.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const PageHeader(title: 'Settings', showBack: true),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadX),
        children: [
          Text('RESUME', style: AppTypography.label.copyWith(color: context.c.inkFaint)),
          const SizedBox(height: AppSpacing.space2),
          Container(
            decoration: BoxDecoration(
              color: context.c.surface,
              border: Border.all(color: context.c.border),
              borderRadius: AppRadius.lgRadius,
              boxShadow: AppElevation.e1,
            ),
            child: InkWell(
              onTap: _updateResume,
              borderRadius: AppRadius.lgRadius,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space4, vertical: AppSpacing.space3),
                child: Row(
                  children: [
                    AppIcon(AppIconName.upload, size: 20, color: context.c.accent),
                    const SizedBox(width: AppSpacing.space3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Update resume', style: AppTypography.title.copyWith(fontSize: 15, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(
                            'Upload a new PDF to replace your current profile — we\'ll re-parse it',
                            style: AppTypography.bodySm.copyWith(color: context.c.inkFaint),
                          ),
                        ],
                      ),
                    ),
                    AppIcon(AppIconName.chevronRight, size: 18, color: context.c.inkFaint),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.space2),
          // Migration 026 — the contact header on every compiled résumé PDF.
          Container(
            decoration: BoxDecoration(
              color: context.c.surface,
              border: Border.all(color: context.c.border),
              borderRadius: AppRadius.lgRadius,
              boxShadow: AppElevation.e1,
            ),
            child: InkWell(
              onTap: () => context.push('/contact-details'),
              borderRadius: AppRadius.lgRadius,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space4, vertical: AppSpacing.space3),
                child: Row(
                  children: [
                    AppIcon(AppIconName.user, size: 20, color: context.c.accent),
                    const SizedBox(width: AppSpacing.space3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Contact details',
                              style: AppTypography.title.copyWith(fontSize: 15, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(
                            'Phone, email, LinkedIn, GitHub and website — printed at the top of your résumé',
                            style: AppTypography.bodySm.copyWith(color: context.c.inkFaint),
                          ),
                        ],
                      ),
                    ),
                    AppIcon(AppIconName.chevronRight, size: 18, color: context.c.inkFaint),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.space4),
          Text('APPEARANCE', style: AppTypography.label.copyWith(color: context.c.inkFaint)),
          const SizedBox(height: AppSpacing.space2),
          Container(
            decoration: BoxDecoration(
              color: context.c.surface,
              border: Border.all(color: context.c.border),
              borderRadius: AppRadius.lgRadius,
              boxShadow: AppElevation.e1,
            ),
            child: ValueListenableBuilder<ThemeMode>(
              valueListenable: ThemeController.instance.mode,
              builder: (context, mode, _) {
                final isDark = mode == ThemeMode.dark ||
                    (mode == ThemeMode.system &&
                        MediaQuery.platformBrightnessOf(context) == Brightness.dark);
                return Column(
                  children: [
                    _switchRow(
                      label: 'Dark mode',
                      desc: 'Follows your system setting until you choose here',
                      value: isDark,
                      onChanged: (v) {
                        HapticService.instance.selection();
                        ThemeController.instance.set(v ? ThemeMode.dark : ThemeMode.light);
                      },
                      showDivider: true,
                    ),
                    _switchRow(
                      label: 'Haptic feedback',
                      desc: 'Subtle taps on buttons and actions',
                      value: _haptics,
                      onChanged: _setHaptics,
                      showDivider: false,
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: AppSpacing.space4),
          Text('NOTIFICATIONS', style: AppTypography.label.copyWith(color: context.c.inkFaint)),
          const SizedBox(height: AppSpacing.space2),
          Container(
            decoration: BoxDecoration(
              color: context.c.surface,
              border: Border.all(color: context.c.border),
              borderRadius: AppRadius.lgRadius,
              boxShadow: AppElevation.e1,
            ),
            child: Column(
              children: [
                _toggleRow(
                  label: 'New-match alerts',
                  desc: 'Push when new matches arrive',
                  value: _alerts,
                  isSaving: _isSavingAlerts,
                  onChanged: _setAlerts,
                  showDivider: true,
                ),
                _toggleRow(
                  label: 'Follow-up nudges',
                  desc: 'Draft follow-ups for stale applications',
                  value: _followupNudge,
                  isSaving: _isSavingFollowupNudge,
                  onChanged: _setFollowupNudge,
                  showDivider: false,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Notification rows disable their switch while a PATCH is in flight; the
  // shared row (below) handles the common layout. A subtle tick fires on every
  // toggle for tactile confirmation.
  Widget _toggleRow({
    required String label,
    required String desc,
    required bool value,
    required bool isSaving,
    required ValueChanged<bool> onChanged,
    required bool showDivider,
  }) {
    return _switchRow(
      label: label,
      desc: desc,
      value: value,
      showDivider: showDivider,
      onChanged: isSaving
          ? null
          : (v) {
              HapticService.instance.selection();
              onChanged(v);
            },
    );
  }

  Widget _switchRow({
    required String label,
    required String desc,
    required bool value,
    required ValueChanged<bool>? onChanged,
    required bool showDivider,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space4, vertical: AppSpacing.space3),
      decoration: BoxDecoration(border: showDivider ? Border(bottom: BorderSide(color: context.c.border)) : null),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTypography.title.copyWith(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(desc, style: AppTypography.bodySm.copyWith(color: context.c.inkFaint)),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.space2),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: context.c.accent,
          ),
        ],
      ),
    );
  }
}
