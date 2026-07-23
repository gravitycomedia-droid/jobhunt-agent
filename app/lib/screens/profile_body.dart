import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import '../models/application_item.dart';
import '../models/resume_profile.dart';
import '../models/subscription.dart';
import '../services/api_client.dart';
import '../services/cache_service.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_loader.dart';
import '../widgets/empty_state.dart';
import '../widgets/hatched_progress.dart';
import '../widgets/page_header.dart';
import '../widgets/stale_banner.dart';
import 'profile_review_screen.dart';
import 'settings_screen.dart';
import 'shortlist_screen.dart';
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

  // Phase 5 (§4.11): the 3-stat row (from applications) and the plan card
  // (from GET /subscription). Both load best-effort AFTER the profile paints —
  // neither is essential to the screen, so a failure just leaves stats at 0 /
  // the plan card hidden rather than blanking Profile.
  List<ApplicationItem> _applications = [];
  Subscription? _subscription;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<bool> _paintFromCache() async {
    if (_profile != null) return true;
    final results = await Future.wait([
      CacheService.instance.read<ResumeProfile>(
        CacheService.keyProfile,
        (json) => ResumeProfile.fromJson((json as Map).cast<String, dynamic>()),
      ),
      CacheService.instance.read<List<ApplicationItem>>(
        CacheService.keyApplications,
        (json) => (json as List).map((a) => ApplicationItem.fromJson((a as Map).cast<String, dynamic>())).toList(),
      ),
    ]);
    final entry = results[0] as CacheEntry<ResumeProfile>?;
    final apps = results[1] as CacheEntry<List<ApplicationItem>>?;
    if (entry == null || !mounted) return false;
    setState(() {
      _profile = entry.data;
      _applications = apps?.data ?? _applications;
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
        unawaited(_loadExtras());
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = painted ? null : e.toString();
        _isLoading = false;
      });
    }
  }

  /// Best-effort: the stat row's applications + the plan card's subscription.
  /// Kept out of [_load]'s success path so neither can blank Profile — the
  /// account card, completion bar and grouped list always render.
  Future<void> _loadExtras() async {
    try {
      final apps = await _apiClient.fetchApplications();
      if (mounted) setState(() => _applications = apps);
      await CacheService.instance.write(CacheService.keyApplications, [for (final a in apps) a.raw]);
    } catch (_) {
      /* stats fall back to whatever the cache painted (or 0) */
    }
    try {
      final sub = await _apiClient.fetchSubscription();
      if (mounted) setState(() => _subscription = sub);
    } catch (_) {
      /* plan card stays hidden */
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
    // No skeleton here (§Phase 5): a cold load with nothing cached shows the
    // real brand loader, not a placeholder shell.
    if (_isLoading && _profile == null) {
      return const Center(child: AppLoader());
    }
    if (_errorMessage != null && _profile == null) {
      return Center(
        child: EmptyState(
          icon: AppIconName.alertTriangle,
          title: 'Could not load your profile',
          message: _errorMessage,
          actionLabel: 'Retry',
          onAction: _load,
        ),
      );
    }

    final profile = _profile;
    return ListView(
      children: [
        if (_staleSince != null) ...[
          StaleBanner(cachedAt: _staleSince!, onRetry: _load),
          const SizedBox(height: AppSpacing.space3),
        ],
        _avatarCard(email, profile),
        if (profile == null) ...[
          const SizedBox(height: AppSpacing.space4),
          EmptyState(
            icon: AppIconName.fileText,
            title: 'No resume uploaded yet',
            message: 'Upload a resume to start matching and tailoring against jobs.',
            actionLabel: 'Upload Resume',
            onAction: () => context.push('/resume-upload'),
          ),
        ] else ...[
          if (_subscription != null) ...[
            const SizedBox(height: AppSpacing.space4),
            _planCard(_subscription!),
          ],
          const SizedBox(height: AppSpacing.space4),
          _statRow(),
          const SizedBox(height: AppSpacing.space4),
          _navRows(),
        ],
        const SizedBox(height: AppSpacing.space4),
        _signOutRow(),
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
            icon: AppIconName.fileText,
            label: 'My résumé',
            onTap: _editProfile,
            showDivider: true,
          ),
          _navRow(
            icon: AppIconName.target,
            label: 'Target roles',
            trailing: '${_profile!.targetRoles.length}',
            onTap: _editTargetRoles,
            showDivider: true,
          ),
          _navRow(
            icon: AppIconName.bookmark,
            label: 'Saved jobs',
            trailing: '${_applications.where((a) => a.state == 'saved').length}',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => ShortlistScreen(applications: _applications)),
            ),
            showDivider: true,
          ),
          _navRow(
            icon: AppIconName.fileText,
            label: 'Apply via form',
            onTap: () => context.push('/form-fill'),
            showDivider: true,
          ),
          _navRow(
            icon: AppIconName.dollarSign,
            label: 'Agent wallet',
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

  /// §4.11 avatar card: who's signed in + role, plus the résumé-completion
  /// bar (hatched remainder) and its %. [profile] is null pre-upload — the
  /// card then just shows the account, and _buildContent adds the nudge below.
  Widget _avatarCard(String? email, ResumeProfile? profile) {
    final title = profile?.name ?? 'Your account';
    final role = profile?.headline;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.space4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: AppRadius.lgRadius,
        boxShadow: AppElevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
                    Text(title, style: AppTypography.title, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      role ?? email ?? 'Signed in',
                      style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (role != null && email != null)
                      Text(email, style: AppTypography.label.copyWith(color: AppColors.textTertiary), overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ],
          ),
          if (profile != null) ...[
            const SizedBox(height: AppSpacing.space4),
            Row(
              children: [
                Text('Résumé completeness', style: AppTypography.caption.copyWith(color: AppColors.textTertiary)),
                const Spacer(),
                Text(
                  '${profile.completionPercent}%',
                  style: TextStyle(
                    fontFamily: AppTypography.monoData.fontFamily,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.brand600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.space2),
            HatchedProgress(value: profile.completionPercent / 100),
          ],
        ],
      ),
    );
  }

  /// §4.11 plan card. `subscription_tier` is the only field that actually
  /// gates anything (server entitlements) — this is a display of it. The full
  /// wallet/top-up UI (§4.12) is Phase 9; this stays a lean status card.
  Widget _planCard(Subscription sub) {
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
          const AppIcon(AppIconName.dollarSign, size: 20, color: AppColors.brand600),
          const SizedBox(width: AppSpacing.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${sub.isPro ? 'Pro' : 'Free'} plan', style: AppTypography.title.copyWith(fontSize: 15, fontWeight: FontWeight.w600)),
                Text(sub.status, style: AppTypography.label.copyWith(color: AppColors.textTertiary)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: sub.isPro ? AppColors.brandSoft : AppColors.surfaceSunken,
              borderRadius: AppRadius.smRadius,
            ),
            child: Text(
              sub.tier.toUpperCase(),
              style: AppTypography.label.copyWith(
                color: sub.isPro ? AppColors.brand700 : AppColors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// §4.11 3-stat row, counted from `applications` (code, never an LLM guess).
  /// Applied = anything moved beyond 'saved'.
  Widget _statRow() {
    final applied = _applications.where((a) => a.state != 'saved').length;
    final interviews = _applications.where((a) => a.state == 'interview').length;
    final offers = _applications.where((a) => a.state == 'offer').length;
    final stats = [
      ('$applied', 'Applied', AppColors.infoText),
      ('$interviews', 'Interviews', AppColors.brand600),
      ('$offers', 'Offers', AppColors.successText),
    ];
    return Row(
      children: [
        for (var i = 0; i < stats.length; i++) ...[
          if (i > 0) const SizedBox(width: AppSpacing.space2),
          Expanded(child: _statTile(stats[i].$1, stats[i].$2, stats[i].$3)),
        ],
      ],
    );
  }

  Widget _statTile(String value, String label, Color color) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: AppRadius.mdRadius,
      ),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.space3, horizontal: 4),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(fontFamily: AppTypography.monoData.fontFamily, fontSize: 22, fontWeight: FontWeight.w700, color: color, letterSpacing: -0.4),
          ),
          const SizedBox(height: 2),
          Text(label.toUpperCase(), style: AppTypography.label.copyWith(color: AppColors.textTertiary), textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _signOutRow() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: () => Supabase.instance.client.auth.signOut(),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textSecondary,
          side: const BorderSide(color: AppColors.border),
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
        child: const Text('Sign out'),
      ),
    );
  }
}
