import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme/app_tokens.dart';

/// Phase 4 (prototype `ui.isSettings`, "Notifications" group only — the
/// prototype's "Agent" group is dropped: autoApply conflicts with
/// CLAUDE.md's "no auto-submitting anywhere" rule, and autoTailor has no
/// pipeline behavior behind it to gate). Both toggles here PATCH
/// immediately on tap (no separate Save button, matching the prototype's
/// `act.toggle` behavior) and gate calls jobs/daily_pipeline.py already
/// makes unconditionally — see server/routers/resume.py's
/// notification-prefs endpoint.
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadX),
        children: [
          Text('NOTIFICATIONS', style: AppTypography.label.copyWith(color: AppColors.textTertiary)),
          const SizedBox(height: AppSpacing.space2),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.border),
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

  Widget _toggleRow({
    required String label,
    required String desc,
    required bool value,
    required bool isSaving,
    required ValueChanged<bool> onChanged,
    required bool showDivider,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space4, vertical: AppSpacing.space3),
      decoration: BoxDecoration(border: showDivider ? const Border(bottom: BorderSide(color: AppColors.border)) : null),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTypography.title.copyWith(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(desc, style: AppTypography.bodySm.copyWith(color: AppColors.textTertiary)),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.space2),
          Switch(
            value: value,
            onChanged: isSaving ? null : onChanged,
            activeThumbColor: AppColors.brand600,
          ),
        ],
      ),
    );
  }
}
