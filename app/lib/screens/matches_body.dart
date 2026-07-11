import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../models/match_item.dart';
import '../services/api_client.dart';
import '../services/match_feed.dart';
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
import 'resume_diff_screen.dart';

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
class MatchesBody extends StatefulWidget {
  const MatchesBody({super.key});

  @override
  State<MatchesBody> createState() => _MatchesBodyState();
}

class _MatchesBodyState extends State<MatchesBody> {
  final ApiClient _apiClient = ApiClient();

  bool _isLoading = true;
  String? _errorMessage;

  // Phase 1C: the list itself lives in MatchFeed — the same object Home's
  // stat counts — so the two surfaces can never disagree. This State only
  // owns loading/error presentation.
  List<MatchItem> get _items => MatchFeed.instance.matches.value ?? const [];

  // ADR-011: the rerank runs server-side as a background task; TaskCenter
  // owns the polling loop (it survives tab switches — this State stays
  // alive in the IndexedStack but couldn't own a cross-tab poller).
  // MatchFeed refetches on completion; we just repaint on either signal.
  ValueNotifier<TrackedTask?> get _rerankTask => TaskCenter.instance.notifierFor(TaskKind.rerank);

  @override
  void initState() {
    super.initState();
    _rerankTask.addListener(_repaint);
    MatchFeed.instance.matches.addListener(_repaint);
    _loadCached();
  }

  @override
  void dispose() {
    _rerankTask.removeListener(_repaint);
    MatchFeed.instance.matches.removeListener(_repaint);
    super.dispose();
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  Future<void> _loadCached() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    // Phase 5 stale-while-revalidate: paint the cached list instantly (no
    // skeleton), then fetch fresh underneath.
    final painted = await MatchFeed.instance.loadFromCache();
    if (mounted && painted) setState(() => _isLoading = false);
    try {
      await MatchFeed.instance.refresh();
      if (!mounted) return;
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
    await TaskCenter.instance.start(TaskKind.rerank, () => _apiClient.rerankShortlist(limit: 20));
  }

  Future<void> _rerankThenReload() async {
    await _startRerank();
    try {
      await MatchFeed.instance.refresh();
    } catch (_) {
      // Keep showing what we have; the banner already covers task errors.
    }
  }

  bool get _isReranking => _rerankTask.value?.isActive ?? false;
  String? get _rerankError =>
      _rerankTask.value?.status == TrackedTaskStatus.failed ? _rerankTask.value?.error : null;

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
    final staleSince = MatchFeed.instance.staleSince.value;
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
        onDismiss: () => TaskCenter.instance.clearIfFinished(TaskKind.rerank),
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
      onTailor: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ResumeDiffScreen(jobId: job.id, jobTitle: job.title)),
      ),
    );
  }
}
