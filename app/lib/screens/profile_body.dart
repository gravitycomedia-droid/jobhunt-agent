import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import '../models/resume_profile.dart';
import '../services/api_client.dart';
import '../services/cache_service.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/empty_state.dart';
import '../widgets/page_header.dart';
import '../widgets/page_skeletons.dart';
import '../widgets/stale_banner.dart';
import 'profile_review_screen.dart';
import 'settings_screen.dart';
import 'target_roles_screen.dart';

/// The Profile tab's content (Brick 9 polish) — the account-level home
/// that was previously missing entirely: shows who's signed in, lets the
/// user revisit/edit their resume profile at any time (not just right
/// after upload, which was [ProfileReviewScreen]'s only entry point
/// before this existed), and signs out.
class ProfileBody extends StatefulWidget {
  const ProfileBody({super.key});

  @override
  State<ProfileBody> createState() => _ProfileBodyState();
}

class _ProfileBodyState extends State<ProfileBody> {
  final ApiClient _apiClient = ApiClient();

  bool _isLoading = true;
  String? _errorMessage;
  DateTime? _staleSince; // Phase 5: non-null = painting cached data
  ResumeProfile? _profile;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<bool> _paintFromCache() async {
    if (_profile != null) return true;
    final entry = await CacheService.instance.read<ResumeProfile>(
      CacheService.keyProfile,
      (json) => ResumeProfile.fromJson((json as Map).cast<String, dynamic>()),
    );
    if (entry == null || !mounted) return false;
    setState(() {
      _profile = entry.data;
      _staleSince = entry.cachedAt;
      _isLoading = false;
    });
    return true;
  }

  Future<void> _load() async {
    setState(() => _errorMessage = null);
    final painted = await _paintFromCache();
    if (!painted && mounted) setState(() => _isLoading = true);
    try {
      final profile = await _apiClient.fetchCurrentProfile();
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _staleSince = null;
        _isLoading = false;
      });
      if (profile != null) {
        await CacheService.instance.write(CacheService.keyProfile, profile.raw);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = painted ? null : e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _editProfile() async {
    final profile = _profile;
    if (profile == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ProfileReviewScreen(profile: profile)),
    );
    // ProfileReviewScreen pops after a successful save — refresh so the
    // account card reflects any edits (name/headline) immediately.
    if (mounted) unawaited(_load());
  }

  Future<void> _editTargetRoles() async {
    final profile = _profile;
    if (profile == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (rolesContext) => TargetRolesScreen(
          initialRoles: profile.targetRoles,
          initialMinSalary: profile.minSalary,
          // Revisiting from Profile (not onboarding) — TargetRolesScreen
          // has already saved via PATCH by the time onDone fires, so this
          // just needs to pop back rather than chain into matching.
          onDone: (_) => Navigator.of(rolesContext).pop(),
        ),
      ),
    );
    if (mounted) unawaited(_load());
  }

  Future<void> _openSettings() async {
    final profile = _profile;
    if (profile == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          initialAlerts: profile.notifyAlerts,
          initialFollowupNudge: profile.notifyFollowupNudge,
        ),
      ),
    );
    // Settings now also hosts "Update resume" — refresh in case the user
    // re-uploaded from there, same as _editProfile/_editTargetRoles do.
    if (mounted) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final email = Supabase.instance.client.auth.currentUser?.email;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageHeader(
          embedded: true,
          title: 'Profile',
          actions: [
            HeaderActionButton(
              icon: AppIconName.settings,
              tooltip: 'Settings',
              // Settings needs the loaded profile's notification prefs —
              // disabled until the profile fetch lands (same data the nav
              // row below relies on).
              onPressed: _profile == null ? null : _openSettings,
            ),
          ],
        ),
        Expanded(child: _buildContent(email)),
      ],
    );
  }

  Widget _buildContent(String? email) {
    return ListView(
      children: [
        if (_staleSince != null) ...[
          StaleBanner(cachedAt: _staleSince!, onRetry: _load),
          const SizedBox(height: AppSpacing.space3),
        ],
        _accountCard(email),
        const SizedBox(height: AppSpacing.space4),
        _resumeSection(),
        if (_profile != null) ...[
          const SizedBox(height: AppSpacing.space4),
          _navRows(),
        ],
      ],
    );
  }

  Widget _navRows() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: AppRadius.lgRadius,
        boxShadow: AppElevation.e1,
      ),
      child: Column(
        children: [
          _navRow(
            icon: AppIconName.target,
            label: 'Target roles',
            trailing: '${_profile!.targetRoles.length}',
            onTap: _editTargetRoles,
            showDivider: true,
          ),
          _navRow(
            icon: AppIconName.dollarSign,
            label: 'LLM cost & usage',
            onTap: () => context.push('/cost'),
            showDivider: true,
          ),
          _navRow(
            icon: AppIconName.trendingUp,
            label: 'Skill growth',
            onTap: () => context.push('/skill-growth'),
            showDivider: true,
          ),
          _navRow(
            icon: AppIconName.settings,
            label: 'Settings',
            onTap: _openSettings,
            showDivider: false,
          ),
        ],
      ),
    );
  }

  Widget _navRow({
    required AppIconName icon,
    required String label,
    String? trailing,
    required VoidCallback onTap,
    required bool showDivider,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space4, vertical: AppSpacing.space3 + 3),
        decoration: BoxDecoration(border: showDivider ? const Border(bottom: BorderSide(color: AppColors.border)) : null),
        child: Row(
          children: [
            AppIcon(icon, size: 20, color: AppColors.brand600),
            const SizedBox(width: AppSpacing.space3),
            Expanded(
              child: Row(
                children: [
                  Text(label, style: AppTypography.title.copyWith(fontSize: 15, fontWeight: FontWeight.w600)),
                  if (trailing != null) ...[
                    const SizedBox(width: 4),
                    Text('· $trailing', style: AppTypography.bodySm.copyWith(color: AppColors.textTertiary)),
                  ],
                ],
              ),
            ),
            const AppIcon(AppIconName.chevronRight, size: 18, color: AppColors.textTertiary),
          ],
        ),
      ),
    );
  }

  Widget _accountCard(String? email) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.space4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: AppRadius.lgRadius,
        boxShadow: AppElevation.e1,
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: AppColors.brandSoft, shape: BoxShape.circle),
            child: const AppIcon(AppIconName.user, size: 22, color: AppColors.brand600),
          ),
          const SizedBox(width: AppSpacing.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Signed in', style: AppTypography.caption.copyWith(color: AppColors.textTertiary)),
                Text(email ?? 'Unknown account', style: AppTypography.title, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          TextButton(
            onPressed: () => Supabase.instance.client.auth.signOut(),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
  }

  Widget _resumeSection() {
    if (_isLoading) {
      // Phase 4C: profile shape — avatar circle + field rows.
      return const SizedBox(height: 320, child: ProfileSkeleton());
    }

    if (_errorMessage != null) {
      return EmptyState(
        icon: AppIconName.alertTriangle,
        title: 'Could not load your profile',
        message: _errorMessage,
        actionLabel: 'Retry',
        onAction: _load,
      );
    }

    final profile = _profile;
    if (profile == null) {
      return EmptyState(
        icon: AppIconName.fileText,
        title: 'No resume uploaded yet',
        message: 'Upload a resume to start matching and tailoring against jobs.',
        actionLabel: 'Upload Resume',
        onAction: () => context.push('/resume-upload'),
      );
    }

    return Container(
      padding: const EdgeInsets.all(AppSpacing.space4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: AppRadius.lgRadius,
        boxShadow: AppElevation.e1,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(profile.name, style: AppTypography.title, overflow: TextOverflow.ellipsis),
                if (profile.headline != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    profile.headline!,
                    style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.space3),
          // A bare OutlinedButton as a non-flex Row child hits a Flutter
          // layout bug on this SDK (freshly-inserted ListView item ->
          // "BoxConstraints forces an infinite width" inside
          // _RenderInputPadding, button_style_button.dart) that corrupts
          // the whole list's layout. Forcing a tight SizedBox around it
          // sidesteps the bug regardless of root cause.
          SizedBox(width: 84, height: 40, child: OutlinedButton(onPressed: _editProfile, child: const Text('Edit'))),
        ],
      ),
    );
  }
}
