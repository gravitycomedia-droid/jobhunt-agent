import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/api_client.dart';
import '../services/cache_service.dart';
import '../services/match_feed.dart';
import '../services/task_center.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../theme/app_theme.dart';
import '../widgets/agent_scene.dart';
import '../widgets/app_icon.dart';

/// The three things this screen actually waits on, in order. The caption and
/// the progress segments are both derived from this — one source of truth for
/// "where are we", instead of a timer pretending to be progress.
enum _Phase { sourcing, scoring, finishing, failed }

/// Onboarding step 5 (prototype `ui.isMatching`): the first-run screen between
/// finishing onboarding and landing on Home.
///
/// **It waits for the real work now.** The previous version fired refresh +
/// rerank and handed off after a fixed 1.6s, which broke first-run Home two
/// ways: (a) the user landed on "No matches yet" while scoring was still
/// running, and (b) — the actual bug — `_kickOff` called `ref.read(...)` *after*
/// an `await`, by which time this widget had been disposed, so the rerank was
/// never even started. Home then stayed empty until the user hit "Re-match" on
/// the Matches tab by hand.
///
/// So: the notifiers are captured up front (never touched through `ref` after
/// an await), the rerank is awaited through [TaskCenter], the match feed is
/// refreshed *before* handing off, and the agent scene plays throughout. The
/// user is never trapped — after [_escapeHatchAfter] a "Continue to home"
/// button appears (the task keeps running in the background and TaskCenter
/// keeps polling it), and [_giveUpAfter] hands off automatically.
class MatchingLoadingScreen extends ConsumerStatefulWidget {
  const MatchingLoadingScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  ConsumerState<MatchingLoadingScreen> createState() => _MatchingLoadingScreenState();
}

class _MatchingLoadingScreenState extends ConsumerState<MatchingLoadingScreen> {
  final ApiClient _apiClient = ApiClient();

  /// Captured EAGERLY in [initState], before any `await` — a [ConsumerState]'s
  /// `ref` must not be used once the widget is disposed, but the notifier
  /// objects themselves live in the root ProviderScope and stay valid.
  ///
  /// Dart note: these are plain `late` (assigned in [initState]), NOT
  /// `late final … = ref.read(…)`. A `late` *initializer* runs on first access,
  /// which here would be after an await — exactly the disposed-ref trap this
  /// screen exists to avoid.
  late final TaskCenter _tasks;
  late final MatchFeed _matchFeed;

  _Phase _phase = _Phase.sourcing;
  String? _error;
  bool _canSkip = false;
  bool _handedOff = false;
  Timer? _escapeTimer;

  /// How long before the user is offered a way out of the wait.
  static const _escapeHatchAfter = Duration(seconds: 40);

  /// Hard cap — a cold rerank of 20 jobs is minutes, not hours. Past this we
  /// hand off regardless; TaskCenter keeps following the task and Matches/Home
  /// repaint themselves when it lands.
  static const _giveUpAfter = Duration(minutes: 6);

  @override
  void initState() {
    super.initState();
    _tasks = ref.read(taskCenterProvider.notifier);
    _matchFeed = ref.read(matchFeedProvider.notifier);
    _escapeTimer = Timer(_escapeHatchAfter, () {
      if (mounted) setState(() => _canSkip = true);
    });
    unawaited(_run());
  }

  @override
  void dispose() {
    _escapeTimer?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    try {
      // 1. Sourcing. ADR-028: skip the shared, rate-limited pool refresh if it
      // ran in the last 5 minutes (e.g. the user just re-ran onboarding).
      // ADR-011-shaped: runs as a background task, so this awaits it through
      // TaskCenter rather than a single long-lived HTTP call. Best-effort —
      // scoring still works against the existing pool if this fails or times
      // out, same as the old `.catchError` swallow.
      if (!await CacheService.instance.isFresh(CacheService.keyJobs)) {
        try {
          await _tasks.start(TaskKind.jobsRefresh, _apiClient.refreshJobs);
          await _awaitJobsRefresh();
        } catch (_) {
          // move on regardless
        }
      }
      if (!mounted) return;

      // 2. Scoring — the long one. Started through TaskCenter so it survives
      // this screen (escape hatch / timeout) and reports through the usual
      // toast + banner plumbing.
      setState(() => _phase = _Phase.scoring);
      await _tasks.start(TaskKind.rerank, () => _apiClient.rerankShortlist(limit: 20));
      await _awaitRerank();
      if (!mounted) return;

      // 3. Load what was just scored, so Home paints matches on its FIRST
      // frame rather than the "No matches yet" empty state.
      setState(() => _phase = _Phase.finishing);
      try {
        await _matchFeed.refresh();
      } catch (_) {
        // Home paints from cache and retries on its own — never trap the user
        // here over the last, least important call.
      }
      _handOff();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = e.toString().replaceFirst('Exception: ', '');
        _canSkip = true;
      });
    }
  }

  /// Polls [TaskCenter]'s published state until the jobs-refresh task
  /// settles. Bounded well short of [_giveUpAfter] — sourcing is the
  /// best-effort first step, not worth trapping the user over; the task
  /// keeps running and TaskCenter keeps following it either way.
  Future<void> _awaitJobsRefresh() async {
    final startedAt = DateTime.now();
    while (mounted) {
      final task = _tasks.taskFor(TaskKind.jobsRefresh);
      if (task == null) return;
      if (task.status == TrackedTaskStatus.done) return;
      if (task.status == TrackedTaskStatus.failed) {
        throw Exception(task.error ?? 'Job refresh failed');
      }
      if (DateTime.now().difference(startedAt) > const Duration(seconds: 90)) return;
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
  }

  /// Polls [TaskCenter]'s published state until the rerank finishes. Reading
  /// the notifier (not `ref.watch`) keeps this a plain await in the same flow
  /// as the two calls around it.
  Future<void> _awaitRerank() async {
    final startedAt = DateTime.now();
    while (mounted) {
      final task = _tasks.taskFor(TaskKind.rerank);
      if (task == null) return; // never started (shouldn't happen) — move on
      if (task.status == TrackedTaskStatus.done) return;
      if (task.status == TrackedTaskStatus.failed) {
        throw Exception(task.error ?? 'Scoring failed');
      }
      if (DateTime.now().difference(startedAt) > _giveUpAfter) return;
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
  }

  /// Hands off to the tab shell exactly once.
  void _handOff() {
    if (_handedOff) return;
    _handedOff = true;
    widget.onDone();
  }

  // ── copy, derived from the phase ────────────────────────────────────────
  String get _title => switch (_phase) {
        _Phase.sourcing => 'Hunting fresh roles…',
        _Phase.scoring => 'Matching you to roles…',
        _Phase.finishing => 'Almost there…',
        _Phase.failed => "Couldn't finish matching",
      };

  String get _subtitle => switch (_phase) {
        _Phase.sourcing => 'Scanning your active job sources for new postings.',
        _Phase.scoring => 'Reading each job description and scoring your fit against it. '
            'This is the slow part — usually a couple of minutes.',
        _Phase.finishing => 'Putting your ranked matches in order.',
        _Phase.failed => _error ?? 'Something went wrong on the way to your matches.',
      };

  int get _step => switch (_phase) {
        _Phase.sourcing => 0,
        _Phase.scoring => 1,
        _ => 2,
      };

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final failed = _phase == _Phase.failed;
    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (failed)
                  AppIcon(AppIconName.alertTriangle, size: 48, color: c.critical)
                else
                  const AgentScene(kind: AgentSceneKind.matching, size: 220),
                const SizedBox(height: AppSpacing.space5),
                Text(_title, style: AppTypography.title, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(
                  _subtitle,
                  style: AppTypography.bodySm.copyWith(color: c.inkSoft, height: 1.5),
                  textAlign: TextAlign.center,
                ),
                if (!failed) ...[
                  const SizedBox(height: AppSpacing.space6),
                  _steps(),
                ],
                if (_canSkip) ...[
                  const SizedBox(height: AppSpacing.space6),
                  TextButton(
                    onPressed: _handOff,
                    child: Text(failed ? 'Go to home' : 'Continue to home'),
                  ),
                  if (!failed)
                    Text(
                      'Scoring keeps running in the background.',
                      style: AppTypography.caption.copyWith(color: c.inkFaint),
                      textAlign: TextAlign.center,
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Three segments — filled for done, accent for the phase in flight. Honest
  /// progress: it moves when a step actually completes, not on a timer.
  Widget _steps() {
    final c = context.c;
    const labels = ['Sourcing', 'Scoring', 'Ranking'];
    return Column(
      children: [
        Row(
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  height: 4,
                  decoration: BoxDecoration(
                    color: i <= _step ? c.accent : c.border,
                    borderRadius: AppRadius.pillRadius,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Text(
          labels[_step].toUpperCase(),
          style: mono(11, w: FontWeight.w600, color: c.inkFaint),
        ),
      ],
    );
  }
}
