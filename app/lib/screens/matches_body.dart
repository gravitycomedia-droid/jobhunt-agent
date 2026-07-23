import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/match_item.dart';
import '../router/route_args.dart';
import '../services/api_client.dart';
import '../services/cache_service.dart';
import '../services/match_feed.dart';
import '../services/refresh_throttle.dart';
import '../services/task_center.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_banner.dart';
import '../widgets/app_icon.dart';
import '../widgets/empty_state.dart';
import '../widgets/background_task_dialog.dart';
import '../widgets/match_card.dart';
import '../widgets/page_header.dart';
import '../widgets/page_skeletons.dart';
import '../widgets/stale_banner.dart';

/// The Matches tab's content (Brick 9 polish: chrome comes from
/// [MainTabScreen] / [AppShell], this is just the body). Two-stage RAG
/// match (ADR-001): jobs ranked by pgvector cosine similarity (stage 1,
/// Brick 4) then LLM-scored for fit (stage 2, Brick 5). Reads the server's
/// cached `matches` table via GET /matches for an instant first paint,
/// then kicks off POST /matches/rerank in the background to score any
/// newly-shortlisted jobs — re-ranking is one sequential Gemini call per
/// job (~20-25s each), so blocking the initial load on it (the first cut
/// of this screen did) meant a cold rerank of the default 20-job batch
/// could take 7+ minutes and trip the client's timeout well before the
/// server-side work actually finished. Showing cached results first and
/// re-ranking underneath avoids that false failure.
class MatchesBody extends ConsumerStatefulWidget {
  const MatchesBody({super.key});

  @override
  ConsumerState<MatchesBody> createState() => _MatchesBodyState();
}

class _MatchesBodyState extends ConsumerState<MatchesBody> {
  final ApiClient _apiClient = ApiClient();
  final RefreshThrottle _throttle = RefreshThrottle();

  bool _isLoading = true;
  String? _errorMessage;
  DateTime? _lastUpdated;

  // Phase 1C/2c: the list itself lives in matchFeedProvider — the same state
  // Home's stat counts — so the two surfaces can never disagree. This State
  // only owns loading/error presentation. Reactivity comes from ref.watch in
  // build (see the watches at the top of build()).
  List<MatchItem> get _items => ref.read(matchFeedProvider).matches ?? const [];

  // ADR-011: the rerank runs server-side as a background task; TaskCenter owns
  // the cross-tab polling loop. MatchFeed refetches on completion.
  TrackedTask? get _rerankTask =>
      ref.read(trackedTaskProvider((kind: TaskKind.rerank, id: null)));

  @override
  void initState() {
    super.initState();
    _loadCached();
  }

  /// Passive load (initState / retry). ADR-028: this is a passive trigger, so
  /// it honors the 5-minute freshness window — if the cached matches are still
  /// fresh, paint them and skip BOTH the GET /matches call and the expensive
  /// auto-rerank. Only the explicit pull-to-refresh ([_rerankThenReload])
  /// ignores the window.
  Future<void> _loadCached() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    // Phase 5 stale-while-revalidate: paint the cached list instantly (no
    // skeleton), then fetch fresh underneath.
    final painted = await ref.read(matchFeedProvider.notifier).loadFromCache();
    _lastUpdated = await CacheService.instance.cachedAtFor(CacheService.keyMatches);
    if (mounted && painted) setState(() => _isLoading = false);

    if (painted && await CacheService.instance.isFresh(CacheService.keyMatches)) {
      // Fresh enough — the network call and rerank would just re-fetch what
      // we're already showing. Skip them (the whole point of ADR-028).
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    try {
      await ref.read(matchFeedProvider.notifier).refresh();
      if (!mounted) return;
      _lastUpdated = DateTime.now();
      setState(() => _isLoading = false);
      // Fire-and-forget: the UI already has something to show, so the
      // re-rank runs underneath rather than blocking the first paint.
      unawaited(_startRerank());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // With a cached paint the stale banner covers it; a full-screen
        // error would throw away perfectly readable data.
        _errorMessage = painted ? null : e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _startRerank() async {
    await ref.read(taskCenterProvider.notifier).start(TaskKind.rerank, () => _apiClient.rerankShortlist(limit: 20));
  }

  /// Explicit pull-to-refresh. ADR-028: always hits the network (a pull means
  /// "get me fresh data now"), but debounced so a rapid triple-pull fires once.
  Future<void> _rerankThenReload() async {
    if (!_throttle.shouldRun()) return;
    await _startRerank();
    try {
      await ref.read(matchFeedProvider.notifier).refresh();
      if (mounted) setState(() => _lastUpdated = DateTime.now());
    } catch (_) {
      // Keep showing what we have; the banner already covers task errors.
    }
  }

  bool get _isReranking => _rerankTask?.isActive ?? false;
  String? get _rerankError =>
      _rerankTask?.status == TrackedTaskStatus.failed ? _rerankTask?.error : null;

  /// Header re-rank trigger (Phase 3A) — the explicit, user-initiated
  /// variant, so it gets the Phase 2 start dialog (the automatic rerank on
  /// tab load stays silent apart from the banner).
  Future<void> _rerankFromHeader() async {
    unawaited(showBackgroundTaskDialog(
      context,
      'Re-ranking your matches',
      'Scoring shortlisted jobs against your profile. This runs in the '
          "background and usually takes 2–3 minutes — keep using the app, "
          "we'll notify you when it's done.",
    ));
    await _startRerank();
  }

  @override
  Widget build(BuildContext context) {
    // Phase 2c: register reactivity — rebuild when the matches list or the
    // rerank task state changes (replaces the old ValueNotifier listeners).
    ref.watch(matchFeedProvider);
    ref.watch(trackedTaskProvider((kind: TaskKind.rerank, id: null)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageHeader(
          embedded: true,
          title: 'Matches',
          subtitle: _isLoading ? null : '${_items.length} ranked for you',
          actions: [
            HeaderActionButton(
              icon: AppIconName.refresh,
              tooltip: 'Re-rank matches',
              busy: _isReranking,
              onPressed: _rerankFromHeader,
            ),
          ],
        ),
        Expanded(child: _buildContent()),
      ],
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      // Phase 4C: match-card shape (score-ring circle placeholder).
      return ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: 4,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.space3),
        itemBuilder: (_, _) => const MatchCardSkeleton(),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: EmptyState(
          icon: AppIconName.alertTriangle,
          title: 'Could not load matches',
          message: _errorMessage,
          actionLabel: 'Retry',
          onAction: _loadCached,
        ),
      );
    }

    if (_items.isEmpty) {
      if (_isReranking) {
        return Center(
          child: EmptyState(
            icon: AppIconName.target,
            title: 'Scoring matches…',
            message: 'Comparing your profile against shortlisted jobs — this can take a minute.',
          ),
        );
      }
      return Center(
        child: EmptyState(
          icon: AppIconName.target,
          title: 'No matches yet',
          message: 'Upload a resume and refresh jobs — matches show up here once both are embedded and scored.',
          actionLabel: 'Retry',
          onAction: _loadCached,
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _rerankThenReload,
      child: ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: _items.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.space3),
        itemBuilder: (context, index) => index == 0 ? _statusBanner() : _matchCard(_items[index - 1]),
      ),
    );
  }

  Widget _statusBanner() {
    final staleSince = ref.read(matchFeedProvider).staleSince;
    if (staleSince != null) {
      return StaleBanner(cachedAt: staleSince, onRetry: _loadCached);
    }
    if (_isReranking) {
      return const AppBanner(
        tone: BannerTone.info,
        title: 'Scoring new matches',
        message: 'Refreshing in the background — pull to check again shortly.',
      );
    }
    if (_rerankError != null) {
      return AppBanner(
        tone: BannerTone.warning,
        title: 'Could not refresh matches',
        message: _rerankError,
        actionLabel: 'Retry',
        onAction: _rerankThenReload,
        onDismiss: () => ref.read(taskCenterProvider.notifier).clearIfFinished(TaskKind.rerank),
      );
    }
    // ADR-028: keep the passive 5-minute freshness window visible, so "why
    // didn't switching back refetch?" has an on-screen answer.
    final label = lastUpdatedLabel(_lastUpdated);
    if (label != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.space2),
        child: Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textTertiary)),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _matchCard(MatchItem item) {
    final job = item.job;
    return MatchCard(
      title: job.title,
      company: job.company ?? 'Unknown company',
      location: job.location,
      source: job.source,
      sourceUrl: job.redirectUrl,
      salary: job.salaryLabel,
      postedAt: job.postedAtLabel,
      score: item.fitScore,
      verdict: item.verdict,
      strengths: item.strengths,
      gaps: item.gaps,
      // Frontend rebuild Phase 1: the prototype's Matches screen (unlike
      // Home's compact rows) always shows full chips + the Tailor action,
      // no collapse affordance — MatchCard already supported this via
      // defaultExpanded, just unused until now.
      defaultExpanded: true,
      onTailor: () => context.push('/tailor', extra: TailorArgs(jobId: job.id, jobTitle: job.title)),
    );
  }
}
