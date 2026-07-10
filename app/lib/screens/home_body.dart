import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;
import 'package:flutter/material.dart';

import '../models/activity_item.dart';
import '../models/application_item.dart';
import '../models/match_item.dart';
import '../services/api_client.dart';
import '../services/match_feed.dart';
import '../theme/app_tokens.dart';
import '../widgets/activity_style.dart';
import '../widgets/app_icon.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_skeleton.dart';
import '../widgets/score_ring.dart';
import '../widgets/status_pill.dart';
import 'activity_log_screen.dart';
import 'resume_diff_screen.dart';
import 'resume_upload_screen.dart';

/// The Home tab's content (frontend rebuild Phases 1 & 3, prototype
/// `ui.isHome`) — chrome comes from [MainTabScreen]/[AppShell]. A
/// greeting with a bell shortcut to the activity log, a "new matches"
/// banner, the top match as a hero card, a 3-stat grid, the next couple
/// of matches, and a "Recent activity" teaser (Phase 3, backed by
/// GET /stats/activity). Still no "Grow your match rate" section — that
/// depends on Skill Growth data, which is Phase 4.
class HomeBody extends StatefulWidget {
  const HomeBody({super.key, this.onNavigateToTab});

  /// Switches [MainTabScreen]'s active tab — Home has a few prototype
  /// shortcuts ("New matches ready", "Also matched · See all") that jump
  /// to the Matches tab rather than pushing a new route.
  final ValueChanged<String>? onNavigateToTab;

  @override
  State<HomeBody> createState() => _HomeBodyState();
}

class _HomeBodyState extends State<HomeBody> {
  final ApiClient _apiClient = ApiClient();

  bool _isLoading = true;
  String? _errorMessage;
  bool _hasProfile = true;
  List<ApplicationItem> _applications = [];
  List<ActivityItem> _activity = [];

  // Phase 1C: Home's match count is literally the `.length` of the same
  // MatchFeed list the Matches tab renders — one source of truth, so the
  // "10 on Home, 2 on Matches" drift can't happen. The listener repaints
  // this (IndexedStack-kept-alive) body whenever a rerank lands.
  List<MatchItem> get _matches => MatchFeed.instance.matches.value ?? const [];

  @override
  void initState() {
    super.initState();
    MatchFeed.instance.matches.addListener(_repaint);
    _load();
  }

  @override
  void dispose() {
    MatchFeed.instance.matches.removeListener(_repaint);
    super.dispose();
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final profile = await _apiClient.fetchCurrentProfile();
      if (profile == null) {
        setState(() {
          _hasProfile = false;
          _isLoading = false;
        });
        return;
      }
      final results = await Future.wait([
        MatchFeed.instance.refresh(),
        _apiClient.fetchApplications(),
        _apiClient.fetchActivity(limit: 3),
      ]);
      setState(() {
        _hasProfile = true;
        _applications = results[1] as List<ApplicationItem>;
        _activity = results[2] as List<ActivityItem>;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  String get _firstName {
    final email = Supabase.instance.client.auth.currentUser?.email;
    if (email == null || !email.contains('@')) return 'there';
    return email.split('@').first;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: 3,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.space3),
        itemBuilder: (_, _) => const LoadingSkeleton(variant: SkeletonVariant.card),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: EmptyState(
          icon: AppIconName.alertTriangle,
          title: 'Could not load your dashboard',
          message: _errorMessage,
          actionLabel: 'Retry',
          onAction: _load,
        ),
      );
    }

    if (!_hasProfile) {
      return Column(
        children: [
          Expanded(
            child: Center(
              child: EmptyState(
                icon: AppIconName.fileText,
                title: 'Upload your resume to get started',
                message: 'Once you upload a resume, matches show up here.',
              ),
            ),
          ),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ResumeUploadScreen()),
              ),
              icon: const AppIcon(AppIconName.upload, color: AppColors.textOnBrand),
              label: const Text('Upload Resume'),
            ),
          ),
        ],
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$_greeting, $_firstName', style: AppTypography.headingSm),
                    const SizedBox(height: 2),
                    Text(
                      _matches.isEmpty ? 'No matches yet' : '${_matches.length} match${_matches.length == 1 ? '' : 'es'} ranked for you',
                      style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              _activityBellButton(),
            ],
          ),
          const SizedBox(height: AppSpacing.space4),
          if (_matches.isNotEmpty) ...[
            _newMatchesBanner(),
            const SizedBox(height: AppSpacing.space3),
          ],
          if (_matches.isNotEmpty) ...[
            _heroMatchCard(_matches.first),
            const SizedBox(height: AppSpacing.space4),
          ],
          _statGrid(),
          if (_matches.length > 1) ...[
            const SizedBox(height: AppSpacing.space5),
            Row(
              children: [
                Text('Also matched', style: AppTypography.title),
                const Spacer(),
                GestureDetector(
                  onTap: () => widget.onNavigateToTab?.call('matches'),
                  child: Text('See all', style: AppTypography.caption.copyWith(color: AppColors.brand600, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.space3),
            for (final m in _matches.skip(1).take(2)) ...[
              _matchRow(m),
              if (m != _matches.skip(1).take(2).last) const SizedBox(height: AppSpacing.space2),
            ],
          ],
          if (_activity.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.space5),
            _recentActivitySection(),
          ],
        ],
      ),
    );
  }

  Widget _activityBellButton() {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ActivityLogScreen()),
      ),
      child: Container(
        width: 42,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: AppColors.surface, border: Border.all(color: AppColors.border), shape: BoxShape.circle),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            const AppIcon(AppIconName.bell, size: 20, color: AppColors.textSecondary),
            if (_activity.isNotEmpty)
              Positioned(
                top: -1,
                right: -1,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: AppColors.criticalFill, shape: BoxShape.circle, border: Border.all(color: AppColors.surface, width: 2)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _newMatchesBanner() {
    return Material(
      color: AppColors.infoSoft,
      borderRadius: AppRadius.mdRadius,
      child: InkWell(
        borderRadius: AppRadius.mdRadius,
        onTap: () => widget.onNavigateToTab?.call('matches'),
        child: Container(
          decoration: BoxDecoration(borderRadius: AppRadius.mdRadius, border: Border.all(color: AppColors.infoBorder)),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space3 + 2, vertical: AppSpacing.space3),
          child: Row(
            children: [
              const AppIcon(AppIconName.info, size: 18, color: AppColors.infoText),
              const SizedBox(width: AppSpacing.space2 + 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('New matches ready', style: AppTypography.bodySm.copyWith(color: AppColors.infoText, fontWeight: FontWeight.w700)),
                    Text(
                      '${_matches.length} job${_matches.length == 1 ? '' : 's'} matched your profile.',
                      style: AppTypography.label.copyWith(color: AppColors.infoText),
                    ),
                  ],
                ),
              ),
              AppIcon(AppIconName.chevronRight, size: 18, color: AppColors.infoText),
            ],
          ),
        ),
      ),
    );
  }

  Widget _recentActivitySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Recent activity', style: AppTypography.title),
            const Spacer(),
            GestureDetector(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ActivityLogScreen()),
              ),
              child: Text('View all', style: AppTypography.caption.copyWith(color: AppColors.brand600, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.space3),
        Container(
          padding: const EdgeInsets.all(AppSpacing.space4),
          decoration: BoxDecoration(color: AppColors.surface, border: Border.all(color: AppColors.border), borderRadius: AppRadius.lgRadius),
          child: Column(
            children: [
              for (var i = 0; i < _activity.length; i++) ...[
                _activityRow(_activity[i]),
                if (i != _activity.length - 1) const SizedBox(height: AppSpacing.space3),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _activityRow(ActivityItem item) {
    final glyph = activityGlyphFor(item);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: glyph.bg, shape: BoxShape.circle),
          child: AppIcon(glyph.icon, size: 13, color: glyph.fg),
        ),
        const SizedBox(width: AppSpacing.space2 + 2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.title, style: AppTypography.bodySm.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 1),
              Text(item.detail, style: AppTypography.label.copyWith(color: AppColors.textTertiary)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _heroMatchCard(MatchItem m) {
    return Material(
      color: AppColors.surface,
      borderRadius: AppRadius.lgRadius,
      child: InkWell(
        borderRadius: AppRadius.lgRadius,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ResumeDiffScreen(jobId: m.job.id, jobTitle: m.job.title)),
        ),
        child: Container(
          decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: AppRadius.lgRadius, boxShadow: AppElevation.e1),
          padding: const EdgeInsets.all(AppSpacing.space4),
          child: Row(
            children: [
              ScoreRing(score: m.fitScore, size: 84),
              const SizedBox(width: AppSpacing.space4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('BEST MATCH', style: AppTypography.label.copyWith(color: AppColors.textTertiary)),
                    const SizedBox(height: 2),
                    Text(m.job.title, style: AppTypography.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(m.job.company ?? '', style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary)),
                    const SizedBox(height: AppSpacing.space2),
                    StatusPill(context: PillContext.verdict, value: m.verdict, size: PillSize.sm),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statGrid() {
    final applied = _applications.where((a) => a.state != 'saved').length;
    final saved = _applications.where((a) => a.state == 'saved').length;
    final stats = [
      ('${_matches.length}', 'Matches', AppColors.brand600),
      ('$applied', 'Applied', AppColors.infoText),
      ('$saved', 'Saved', AppColors.successText),
    ];
    return Row(
      children: [
        for (var i = 0; i < stats.length; i++) ...[
          if (i > 0) const SizedBox(width: AppSpacing.space2),
          Expanded(child: _StatTile(value: stats[i].$1, label: stats[i].$2, color: stats[i].$3)),
        ],
      ],
    );
  }

  Widget _matchRow(MatchItem m) {
    return Material(
      color: AppColors.surface,
      borderRadius: AppRadius.lgRadius,
      child: InkWell(
        borderRadius: AppRadius.lgRadius,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ResumeDiffScreen(jobId: m.job.id, jobTitle: m.job.title)),
        ),
        child: Container(
          decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: AppRadius.lgRadius, boxShadow: AppElevation.e1),
          padding: const EdgeInsets.all(AppSpacing.space3),
          child: Row(
            children: [
              ScoreRing(score: m.fitScore, size: 44),
              const SizedBox(width: AppSpacing.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.job.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(m.job.company ?? '', style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary)),
                  ],
                ),
              ),
              StatusPill(context: PillContext.verdict, value: m.verdict, size: PillSize.sm),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.value, required this.label, required this.color});

  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: AppColors.surface, border: Border.all(color: AppColors.border), borderRadius: AppRadius.mdRadius),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.space3, horizontal: 4),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(fontFamily: AppTypography.monoData.fontFamily, fontSize: 22, fontWeight: FontWeight.w700, color: color, letterSpacing: -0.4),
          ),
          const SizedBox(height: 2),
          Text(
            label.toUpperCase(),
            style: AppTypography.label.copyWith(color: AppColors.textTertiary),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
