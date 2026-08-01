import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/activity_item.dart';
import '../models/application_item.dart';
import '../models/job.dart';
import '../models/match_item.dart';
import 'dart:async' show unawaited;

import '../router/route_args.dart';
import '../services/api_client.dart';
import '../services/cache_service.dart';
import '../services/match_feed.dart';
import '../services/refresh_throttle.dart';
import '../services/task_center.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/activity_style.dart';
import '../widgets/agent_scene.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_loader.dart';
import '../widgets/background_task_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/fit_gauge.dart';
import '../widgets/source_chip.dart';
import '../widgets/stale_banner.dart';

/// The Home tab's content — the "Home (redesigned)" screen from the
/// `design_handoff_jobhunt_agent` prototype. Chrome (bottom nav, chat FAB)
/// comes from [MainTabScreen]/[AppShell].
///
/// Layout, top → bottom (prototype `isHome`, populated state):
///  1. Greeting ("Good morning, {name}" + "Today's top match") + a bell
///     button that carries an unread dot and opens the notification feed.
///  2. The CRED-style **fit gauge** for the top match's score, a dark
///     "Refresh now" pill (runs the agent pipeline), and a mono
///     "LAST UPDATED …" footer.
///  3. A **hero card** for the top match: role, company · location, a
///     freshness badge, salary + source chips, and an accent
///     "Tailor résumé & apply" action bar.
///  4. "New jobs today" — the remaining matches as compact job rows.
///  5. "Agent activity" — the recent-activity feed (GET /stats/activity).
///
/// The stat grid and info "new matches" banner from the pre-redesign Home
/// are intentionally gone: the score now lives in the gauge and the cards
/// are job-centric (salary/source/freshness), matching the handoff.
class HomeBody extends ConsumerStatefulWidget {
  const HomeBody({super.key, this.onNavigateToTab});

  /// Switches [MainTabScreen]'s active tab — Home's "See all" / "Browse jobs"
  /// shortcuts jump to the Jobs/Matches tabs rather than pushing a route.
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
  List<ApplicationItem> _applications = [];
  List<ActivityItem> _activity = [];

  // Phase 5 (rebuild v2, §4.2): the fit-gauge delta chip + bell badge. Both
  // are ENHANCEMENTS fetched best-effort (see _loadEnhancements) — a failure
  // never blanks the dashboard. `_scoreDelta == 0` hides the chip (no prior
  // snapshot yet, or a genuine no-change) — never a fabricated reading.
  int _scoreDelta = 0;
  int _unreadCount = 0;

  // Bumped every time Home is re-entered, and folded into the FitGauge's key so
  // the gauge REMOUNTS and replays its count-up reveal. Home lives in a
  // StatefulShellRoute branch (kept alive across tab switches) and sub-screens
  // push above the shell, so without this the gauge animates exactly once per
  // app launch and every later visit shows a dead, already-settled number.
  int _gaugeGen = 0;
  GoRouter? _router;
  bool _wasOnHome = true;

  // Phase 1C: Home's match count is literally the `.length` of the same
  // MatchFeed list the Matches tab renders — one source of truth, so the
  // "10 on Home, 2 on Matches" drift can't happen. The listener repaints
  // this (IndexedStack-kept-alive) body whenever a rerank lands.
  // Phase 2c: reactivity via ref.watch in build (see the watches at the top of
  // build()), replacing the old MatchFeed/TaskCenter ValueNotifier listeners.
  List<MatchItem> get _matches => ref.read(matchFeedProvider).matches ?? const [];

  // Phase 3A: the run-agent-now trigger. In the redesign it lives on the dark
  // "Refresh now" pill under the gauge — its "Refreshing…" label mirrors this.
  TrackedTask? get _pipelineTask =>
      ref.read(trackedTaskProvider((kind: TaskKind.pipeline, id: null)));
  bool get _isRunningPipeline => _pipelineTask?.isActive ?? false;

  /// True while the agent is actively producing matches (a rerank kicked off by
  /// onboarding, or an agent run). With no matches yet, that's a *working*
  /// state — not the "no matches yet, go browse jobs" dead end the empty state
  /// otherwise shows.
  bool get _isScoring =>
      _isRunningPipeline ||
      (ref.read(trackedTaskProvider((kind: TaskKind.rerank, id: null)))?.isActive ?? false);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Watch the router rather than this widget's own lifecycle: switching tabs
    // and popping a pushed sub-screen both change the location but neither
    // rebuilds/remounts HomeBody, so route changes are the only signal that
    // reliably fires for "the user is looking at Home again".
    final router = GoRouter.of(context);
    if (identical(router, _router)) return;
    _router?.routerDelegate.removeListener(_onRouteChanged);
    _router = router;
    router.routerDelegate.addListener(_onRouteChanged);
  }

  @override
  void dispose() {
    _router?.routerDelegate.removeListener(_onRouteChanged);
    super.dispose();
  }

  /// Replays the fit-gauge reveal on every *transition into* Home. Gated on the
  /// edge (`!_wasOnHome`) so an in-place notification while already on Home —
  /// e.g. a `push` that redirects straight back — doesn't restart the count-up
  /// mid-animation.
  void _onRouteChanged() {
    if (!mounted) return;
    final onHome = _router?.routerDelegate.currentConfiguration.uri.path == '/home';
    if (onHome && !_wasOnHome) setState(() => _gaugeGen++);
    _wasOnHome = onHome;
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
      /* leave the bell dot hidden */
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
    // changes (replaces the old ValueNotifier listeners). The rerank watch keeps
    // the "agent is scoring" state below live too.
    ref.watch(matchFeedProvider);
    ref.watch(trackedTaskProvider((kind: TaskKind.pipeline, id: null)));
    ref.watch(trackedTaskProvider((kind: TaskKind.rerank, id: null)));
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
              icon: AppIcon(AppIconName.upload, color: context.onAccent),
              label: const Text('Upload Resume'),
            ),
          ),
        ],
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: ListView(
        // Horizontal gutter comes from AppShell (screenPadX); adding our own
        // here double-padded Home and made it narrower than the other tabs.
        padding: EdgeInsets.zero,
        children: [
          if (_staleSince != null) ...[
            StaleBanner(cachedAt: _staleSince!, onRetry: () => _load(force: true)),
            const SizedBox(height: AppSpacing.space3),
          ],
          _greetingRow(),
          const SizedBox(height: AppSpacing.space5),
          if (_matches.isEmpty)
            _noMatches()
          else ...[
            _gaugeBlock(),
            const SizedBox(height: AppSpacing.space3),
            _heroCard(_matches.first),
            if (_matches.length > 1) ...[
              const SizedBox(height: AppSpacing.space5),
              _newJobsSection(),
            ],
            if (_activity.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.space5),
              _agentActivitySection(),
            ],
          ],
        ],
      ),
    );
  }

  // ── 1. Greeting + bell ────────────────────────────────────────────────
  Widget _greetingRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$_greeting, $_firstName',
                style: AppTypography.bodySm.copyWith(color: context.c.inkSoft),
              ),
              const SizedBox(height: 1),
              Text(
                _matches.isEmpty ? 'Your dashboard' : "Today's top match",
                style: AppTypography.headingSm.copyWith(fontSize: 20),
              ),
            ],
          ),
        ),
        _bellButton(),
      ],
    );
  }

  Widget _bellButton() {
    return GestureDetector(
      onTap: () => context.push('/notifications'),
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: context.c.surface,
          border: Border.all(color: context.c.border),
          borderRadius: AppRadius.mdRadius,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AppIcon(AppIconName.bell, size: 19, color: context.c.ink),
            // §4.2: the prototype's simple unread dot (real count from GET
            // /notifications; 0 or a failed fetch shows nothing).
            if (_unreadCount > 0)
              Positioned(
                top: -3,
                right: -3,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: context.c.critical,
                    shape: BoxShape.circle,
                    border: Border.all(color: context.c.surface, width: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── 2. Fit gauge + refresh pill + last-updated ────────────────────────
  Widget _gaugeBlock() {
    return Column(
      children: [
        // Keyed on the score so a rerank that changes the top match remounts
        // the gauge and re-runs its count-up (it's a one-shot animator); a
        // later delta-chip arrival at the SAME score just rebuilds in place.
        // `_gaugeGen` adds the same remount on every re-entry into Home, so the
        // reveal plays again even when the score itself hasn't moved.
        FitGauge(
          key: ValueKey('${_matches.first.fitScore}-$_gaugeGen'),
          target: _matches.first.fitScore,
          delta: _scoreDelta,
        ),
        const SizedBox(height: AppSpacing.space2),
        _refreshPill(),
      ],
    );
  }

  Widget _refreshPill() {
    return GestureDetector(
      onTap: _isRunningPipeline ? null : _runPipeline,
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 26),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: context.c.ink,
          borderRadius: BorderRadius.circular(23),
          boxShadow: const [BoxShadow(color: Color(0x33000000), offset: Offset(0, 8), blurRadius: 20)],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isRunningPipeline) ...[
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: context.c.paper),
              ),
              const SizedBox(width: AppSpacing.space2),
            ],
            Text(
              _isRunningPipeline ? 'Refreshing…' : 'Refresh now',
              style: AppTypography.bodySm.copyWith(color: context.c.paper, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  // ── 3. Hero card (top match) ──────────────────────────────────────────
  Widget _heroCard(MatchItem m) {
    final job = m.job;
    final locBits = [job.company, job.location].where((s) => s != null && s.isNotEmpty).cast<String>();
    return Material(
      color: context.c.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => context.push('/match', extra: MatchArgs(match: m)),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: context.c.border),
            borderRadius: BorderRadius.circular(18),
          ),
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          job.title,
                          style: AppTypography.headingSm,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          locBits.join(' · '),
                          style: AppTypography.bodySm.copyWith(color: context.c.inkSoft),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.space3),
                  _freshBadge(m),
                ],
              ),
              const SizedBox(height: AppSpacing.space3),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (job.salaryLabel != null) _salaryChip(job),
                  _sourceChip(job.source),
                ],
              ),
              const SizedBox(height: 14),
              // "Tailor résumé & apply" action bar — the one consequential CTA
              // on Home. Tapping it enters the tailor flow (the card tap opens
              // match detail).
              GestureDetector(
                onTap: () => context.push('/tailor', extra: TailorArgs(jobId: job.id, jobTitle: job.title)),
                child: Container(
                  height: 46,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  decoration: BoxDecoration(
                    color: context.c.accent,
                    borderRadius: AppRadius.mdRadius,
                  ),
                  child: Row(
                    children: [
                      Text(
                        'Tailor résumé & apply',
                        style: AppTypography.bodySm.copyWith(color: context.onAccent, fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      Icon(Icons.arrow_forward_rounded, size: 18, color: context.onAccent),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 4. New jobs today (remaining matches) ─────────────────────────────
  Widget _newJobsSection() {
    final rest = _matches.skip(1).take(4).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('New jobs today', style: AppTypography.title),
            const Spacer(),
            GestureDetector(
              onTap: () => widget.onNavigateToTab?.call('jobs'),
              child: Text(
                'See all',
                style: AppTypography.caption.copyWith(color: context.c.accent, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.space3),
        for (var i = 0; i < rest.length; i++) ...[
          if (i > 0) const SizedBox(height: 9),
          _jobRow(rest[i]),
        ],
      ],
    );
  }

  Widget _jobRow(MatchItem m) {
    final job = m.job;
    final salary = job.salaryLabel;
    final sub = [job.company, salary].where((s) => s != null && s.isNotEmpty).join(' · ');
    return Material(
      color: context.c.surface,
      borderRadius: AppRadius.lgRadius,
      child: InkWell(
        borderRadius: AppRadius.lgRadius,
        onTap: () => context.push('/match', extra: MatchArgs(match: m)),
        child: Container(
          decoration: BoxDecoration(border: Border.all(color: context.c.border), borderRadius: AppRadius.lgRadius),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              SourceChip(source: job.source, size: 30),
              const SizedBox(width: AppSpacing.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.title,
                      style: AppTypography.bodySm.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      sub,
                      style: AppTypography.caption.copyWith(color: context.c.inkSoft),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.space2),
              _freshBadge(m),
            ],
          ),
        ),
      ),
    );
  }

  // ── 5. Agent activity ─────────────────────────────────────────────────
  Widget _agentActivitySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('Agent activity', style: AppTypography.title),
            const Spacer(),
            GestureDetector(
              onTap: () => context.push('/activity'),
              child: Text(
                'View all',
                style: AppTypography.caption.copyWith(color: context.c.accent, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.space1),
        for (final item in _activity) _activityRow(item),
      ],
    );
  }

  Widget _activityRow(ActivityItem item) {
    final glyph = activityGlyphFor(context, item);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.c.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(color: glyph.fg, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: AppSpacing.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title, style: AppTypography.bodySm.copyWith(fontWeight: FontWeight.w500)),
                const SizedBox(height: 1),
                Text(item.detail, style: AppTypography.caption.copyWith(color: context.c.inkSoft)),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.space2),
          Text(
            _relativeTime(item.timestamp),
            style: AppTypography.monoData.copyWith(fontSize: 11, color: context.c.inkFaint),
          ),
        ],
      ),
    );
  }

  // ── Shared small pieces ───────────────────────────────────────────────

  /// A fresh match (ranked/posted recently) gets an accent "NEW" badge;
  /// otherwise the posting's relative date in the neutral chip.
  Widget _freshBadge(MatchItem m) {
    if (m.isNew) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: context.c.accentSoft, borderRadius: AppRadius.smRadius),
        child: Text(
          'NEW',
          style: AppTypography.label.copyWith(color: context.c.accent, letterSpacing: 0.6),
        ),
      );
    }
    final label = m.job.postedAtLabel;
    if (label == null) return const SizedBox.shrink();
    return Text(
      label,
      style: AppTypography.monoData.copyWith(fontSize: 11, color: context.c.inkFaint),
    );
  }

  Widget _salaryChip(Job job) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: context.c.surface2,
        border: Border.all(color: context.c.border),
        borderRadius: AppRadius.smRadius,
      ),
      child: Text(
        job.salaryLabel!,
        style: AppTypography.monoData.copyWith(fontSize: 12, color: context.c.ink, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _sourceChip(String source) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 4, 10, 4),
      decoration: BoxDecoration(
        color: context.c.surface2,
        border: Border.all(color: context.c.border),
        borderRadius: AppRadius.smRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SourceChip(source: source, size: 16),
          const SizedBox(width: 6),
          Text(
            _sourceLabel(source),
            style: AppTypography.caption.copyWith(color: context.c.inkSoft, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  // ── 0. No-matches empty state (prototype homeEmpty) ───────────────────
  Widget _noMatches() {
    // Scoring in flight → the agent scene, not the dead-end empty state. This
    // is what a first-run user sees if they land here before the rerank that
    // MatchingLoadingScreen started has finished.
    if (_isScoring) {
      return Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(
          children: [
            const AgentScene(kind: AgentSceneKind.matching, size: 200),
            const SizedBox(height: AppSpacing.space4),
            Text('Scoring your matches…', style: AppTypography.title, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(
              'The agent is reading job descriptions and ranking your fit. '
              'They appear here as soon as it finishes.',
              style: AppTypography.bodySm.copyWith(color: context.c.inkSoft),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 40),
      child: Column(
        children: [
          EmptyState(
            icon: AppIconName.target,
            title: 'No matches yet',
            message: 'Your agent is still learning what you want. Browse jobs and '
                'bookmark a few — it will rank your fit.',
          ),
          const SizedBox(height: AppSpacing.space4),
          ElevatedButton(
            onPressed: () => widget.onNavigateToTab?.call('jobs'),
            child: const Text('Browse jobs'),
          ),
        ],
      ),
    );
  }

  String _sourceLabel(String source) {
    final key = source.trim();
    if (key.isEmpty) return 'Source';
    // Title-case the raw source token (e.g. "google_form" → "Google Form").
    return key
        .split(RegExp(r'[_\s]+'))
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }

  String _relativeTime(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }
}
