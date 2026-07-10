import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../models/match_item.dart';
import '../services/api_client.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_banner.dart';
import '../widgets/app_icon.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_skeleton.dart';
import '../widgets/match_card.dart';
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
  bool _isReranking = false;
  String? _errorMessage;
  String? _rerankError;
  List<MatchItem> _items = [];

  @override
  void initState() {
    super.initState();
    _loadCached();
  }

  Future<void> _loadCached() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final items = await _apiClient.fetchMatches(limit: 50);
      setState(() {
        _items = items;
        _isLoading = false;
      });
      // Fire-and-forget: the UI already has something to show, so the
      // re-rank runs underneath rather than blocking the first paint.
      unawaited(_rerankThenReload());
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _rerankThenReload() async {
    setState(() {
      _isReranking = true;
      _rerankError = null;
    });
    try {
      await _apiClient.rerankShortlist(limit: 20);
      final items = await _apiClient.fetchMatches(limit: 50);
      if (!mounted) return;
      setState(() {
        _items = items;
        _isReranking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isReranking = false;
        _rerankError = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: 4,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.space3),
        itemBuilder: (_, _) => const LoadingSkeleton(variant: SkeletonVariant.card),
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
        onDismiss: () => setState(() => _rerankError = null),
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
