import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/activity_item.dart';
import '../models/application_item.dart';
import '../models/match_item.dart';
import 'dart:async' show unawaited;

import '../router/route_args.dart';
import '../services/api_client.dart';
import '../services/cache_service.dart';
import '../services/match_feed.dart';
import '../services/refresh_throttle.dart';
import '../services/task_center.dart';
import '../theme/app_tokens.dart';
import '../widgets/activity_style.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_loader.dart';
import '../widgets/background_task_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/fit_gauge.dart';
import '../widgets/score_ring.dart';
import '../widgets/stale_banner.dart';
import '../widgets/status_pill.dart';

/// The Home tab's content (frontend rebuild Phases 1 & 3, prototype
/// `ui.isHome`) — chrome comes from [MainTabScreen]/[AppShell]. A
/// greeting with a bell shortcut to the activity log, a "new matches"
/// banner, the top match as a hero card, a 3-stat grid, the next couple
/// of matches, and a "Recent activity" teaser (Phase 3, backed by
/// GET /stats/activity). Still no "Grow your match rate" section — that
/// depends on Skill Growth data, which is Phase 4.
class HomeBody extends ConsumerStatefulWidget {
  const HomeBody({super.key, this.onNavigateToTab});

  /// Switches [MainTabScreen]'s active tab — Home has a few prototype
  /// shortcuts ("New matches ready", "Also matched · See all") that jump
  /// to the Matches tab rather than pushing a new route.
  final ValueChanged<String>? onNavigateToTab;

  @override
  ConsumerState<HomeBody> createState() => _HomeBodyState();
}

class _HomeBodyState extends ConsumerState<HomeBody> {
  final ApiClient _apiClient = ApiClient();
  final RefreshThrottle _throttle = RefreshThrottle();

  bool _isLoading = true;
  String? _errorMessage;
  bool _hasProfile = true;
  DateTime? _staleSince; // Phase 5: non-null = painting cached data
  DateTime? _lastUpdated; // ADR-028: for the "updated Xm ago" indicator
  List<ApplicationItem> _applications = [];
  List<ActivityItem> _activity = [];

  // Phase 5 (rebuild v2, §4.2): the fit-gauge delta chip + bell badge. Both
  // are ENHANCEMENTS fetched best-effort (see _loadEnhancements) — a failure
  // never blanks the dashboard. `_scoreDelta == 0` hides the chip (no prior
  // snapshot yet, or a genuine no-change) — never a fabricated reading.
  int _scoreDelta = 0;
  int _unreadCount = 0;

  // Phase 1C: Home's match count is literally the `.length` of the same
  // MatchFeed list the Matches tab renders — one source of truth, so the
  // "10 on Home, 2 on Matches" drift can't happen. The listener repaints
  // this (IndexedStack-kept-alive) body whenever a rerank lands.
  // Phase 2c: reactivity via ref.watch in build (see the watches at the top of
  // build()), replacing the old MatchFeed/TaskCenter ValueNotifier listeners.
  List<MatchItem> get _matches => ref.read(matchFeedProvider).matches ?? const [];

  // Phase 3A: the run-agent-now trigger moved here from the deleted branded
  // title bar — Home's greeting row is its new permanent home.
  TrackedTask? get _pipelineTask =>
      ref.read(trackedTaskProvider((kind: TaskKind.pipeline, id: null)));
  bool get _isRunningPipeline => _pipelineTask?.isActive ?? false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _runPipeline() async {
    unawaited(showBackgroundTaskDialog(
      context,
      'Agent run started',
      'Fetching fresh jobs and scoring them against your profile. This runs '
          'in the background and usually takes 2–3 minutes — keep using the '
          "app, we'll notify you when it's done.",
    ));
    await ref.read(taskCenterProvider.notifier).start(TaskKind.pipeline, () => _apiClient.runPipeline());
  }

  /// Phase 5: paint the last-known dashboard instantly from cache, then
  /// revalidate. A cached profile also answers "has a profile?" offline —
  /// airplane-mode open lands on the dashboard, not the upload nudge.
  Future<bool> _paintFromCache() async {
    if (_applications.isNotEmpty || _activity.isNotEmpty || _matches.isNotEmpty) return true;
    final results = await Future.wait([
      ref.read(matchFeedProvider.notifier).loadFromCache(),
      CacheService.instance.read<List<ApplicationItem>>(
        CacheService.keyApplications,
        (json) => (json as List).map((a) => ApplicationItem.fromJson((a as Map).cast<String, dynamic>())).toList(),
      ),
      CacheService.instance.read<List<ActivityItem>>(
        CacheService.keyActivity,
        (json) => (json as List).map((a) => ActivityItem.fromJson((a as Map).cast<String, dynamic>())).toList(),
      ),
    ]);
    final apps = results[1] as CacheEntry<List<ApplicationItem>>?;
    final activity = results[2] as CacheEntry<List<ActivityItem>>?;
    final paintedFeed = results[0] as bool;
    if (!mounted || (apps == null && activity == null && !paintedFeed)) return false;
    setState(() {
      _hasProfile = true;
      _applications = apps?.data ?? _applications;
      _activity = activity?.data ?? _activity;
      _staleSince = apps?.cachedAt ?? activity?.cachedAt;
      _isLoading = false;
    });
    return true;
  }

  /// [force] separates a PASSIVE load (initState) from an explicit refresh
  /// (pull-to-refresh, Retry). ADR-028: a passive load serves the cached
  /// dashboard and skips ALL four network calls (profile + matches + apps +
  /// activity) when the cache is under 5 minutes old — the whole "switching
  /// back to Home shouldn't refetch everything" win. Force always refetches,
  /// debounced against rapid pulls.
  Future<void> _load({bool force = false}) async {
    if (force && !_throttle.shouldRun()) return;
    setState(() => _errorMessage = null);
    final painted = await _paintFromCache();
    _lastUpdated = await CacheService.instance.cachedAtFor(CacheService.keyActivity);

    if (!force && painted && await CacheService.instance.isFresh(CacheService.keyActivity)) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    if (!painted && mounted) setState(() => _isLoading = true);
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
        ref.read(matchFeedProvider.notifier).refresh(),
        _apiClient.fetchApplications(),
        _apiClient.fetchActivity(limit: 3),
      ]);
      if (!mounted) return;
      setState(() {
        _hasProfile = true;
        _applications = results[1] as List<ApplicationItem>;
        _activity = results[2] as List<ActivityItem>;
        _staleSince = null;
        _isLoading = false;
        _lastUpdated = DateTime.now();
      });
      await CacheService.instance.write(CacheService.keyApplications, [for (final a in _applications) a.raw]);
      await CacheService.instance.write(CacheService.keyActivity, [for (final a in _activity) a.raw]);
      unawaited(_loadEnhancements());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = painted ? null : e.toString();
        _isLoading = false;
      });
    }
  }

  /// Phase 5 (§4.2): the gauge delta chip + bell unread badge. Deliberately
  /// OUTSIDE [_load]'s success path and each other's — these back-end
  /// endpoints (score-history, notifications) ship with the Phase-4
  /// migrations/deploy that may not be live yet, and even once live they're
  /// secondary. A failure leaves the chip/badge hidden; the dashboard itself
  /// (matches, stats, activity) must always render.
  Future<void> _loadEnhancements() async {
    try {
      final history = await _apiClient.fetchScoreHistory();
      // null delta → no ≥24h-older snapshot yet → 0 keeps the chip hidden.
      if (mounted) setState(() => _scoreDelta = history.delta?.topFit ?? 0);
    } catch (_) {
      /* leave the delta chip hidden */
    }
    try {
      // The unread count is a separate COUNT query server-side, independent of
      // limit — so limit:1 is the cheapest way to read just the badge number.
      final feed = await _apiClient.fetchNotifications(limit: 1);
      if (mounted) setState(() => _unreadCount = feed.unreadCount);
    } catch (_) {
      /* leave the bell badge hidden */
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
    // Phase 2c: rebuild when the shared matches list or the pipeline task state
    // changes (replaces the old ValueNotifier listeners).
    ref.watch(matchFeedProvider);
    ref.watch(trackedTaskProvider((kind: TaskKind.pipeline, id: null)));
    if (_isLoading) {
      // Phase 5 (§Phase 5 acceptance): no skeleton — cold load shows the brand
      // loader; a warm load paints the cached dashboard instantly instead.
      return const Center(child: AppLoader());
    }

    if (_errorMessage != null) {
      return Center(
        child: EmptyState(
          icon: AppIconName.alertTriangle,
          title: 'Could not load your dashboard',
          message: _errorMessage,
          actionLabel: 'Retry',
          onAction: () => _load(force: true),
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
              onPressed: () => context.push('/resume-upload'),
              icon: const AppIcon(AppIconName.upload, color: AppColors.textOnBrand),
              label: const Text('Upload Resume'),
            ),
          ),
        ],
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          if (_staleSince != null) ...[
            StaleBanner(cachedAt: _staleSince!, onRetry: () => _load(force: true)),
            const SizedBox(height: AppSpacing.space3),
          ] else if (lastUpdatedLabel(_lastUpdated) != null) ...[
            // ADR-028: keep the passive 5-minute freshness window visible.
            Text(
              lastUpdatedLabel(_lastUpdated)!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textTertiary),
            ),
            const SizedBox(height: AppSpacing.space3),
          ],
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
              _runAgentButton(),
              const SizedBox(width: AppSpacing.space2),
              _activityBellButton(),
            ],
          ),
          const SizedBox(height: AppSpacing.space4),
          if (_matches.isNotEmpty) ...[
            // §4.2 fit gauge — the top match's fit as the hero score, with the
            // real day-over-day delta chip (hidden until two snapshots exist).
            // Keyed on the score so a rerank that changes the top match remounts
            // the gauge and re-runs its count-up (it's a one-shot animator); a
            // later delta-chip arrival at the SAME score just rebuilds in place.
            Center(
              child: FitGauge(
                key: ValueKey(_matches.first.fitScore),
                target: _matches.first.fitScore,
                delta: _scoreDelta,
              ),
            ),
            const SizedBox(height: AppSpacing.space3),
            _newMatchesBanner(),
            const SizedBox(height: AppSpacing.space3),
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

  Widget _runAgentButton() {
    return GestureDetector(
      onTap: _isRunningPipeline ? null : _runPipeline,
      child: Container(
        width: 42,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: AppColors.surface, border: Border.all(color: AppColors.border), shape: BoxShape.circle),
        child: _isRunningPipeline
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brand))
            : const AppIcon(AppIconName.bot, size: 20, color: AppColors.textSecondary),
      ),
    );
  }

  Widget _activityBellButton() {
    return GestureDetector(
      onTap: () => context.push('/activity'),
      child: Container(
        width: 42,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: AppColors.surface, border: Border.all(color: AppColors.border), shape: BoxShape.circle),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            const AppIcon(AppIconName.bell, size: 20, color: AppColors.textSecondary),
            // §4.2: real unread count from GET /notifications (best-effort —
            // 0 or a failed fetch shows no badge). 9+ caps the pill width.
            if (_unreadCount > 0)
              Positioned(
                top: -6,
                right: -6,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 16),
                  height: 16,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.criticalFill,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.surface, width: 2),
                  ),
                  child: Text(
                    _unreadCount > 9 ? '9+' : '$_unreadCount',
                    style: const TextStyle(color: AppColors.textOnBrand, fontSize: 9, fontWeight: FontWeight.w700, height: 1),
                  ),
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
              onTap: () => context.push('/activity'),
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
        onTap: () => context.push('/tailor', extra: TailorArgs(jobId: m.job.id, jobTitle: m.job.title)),
        child: Container(
          decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: AppRadius.lgRadius, boxShadow: AppElevation.e1),
          padding: const EdgeInsets.all(AppSpacing.space4),
          child: Row(
            children: [
              // No ScoreRing here — the fit gauge above owns the score, so the
              // best-match card is the detail card (§4.2), not a second gauge.
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
        onTap: () => context.push('/tailor', extra: TailorArgs(jobId: m.job.id, jobTitle: m.job.title)),
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
