import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/application_item.dart';
import '../models/job.dart';
import '../router/route_args.dart';
import '../services/api_client.dart';
import '../services/cache_service.dart';
import '../services/job_filter.dart';
import '../services/refresh_throttle.dart';
import '../services/task_center.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_loader.dart';
import '../widgets/empty_state.dart';
import '../widgets/job_card.dart';
import '../widgets/job_filter_sheet.dart';
import '../widgets/page_header.dart';
import '../widgets/stale_banner.dart';
import 'shortlist_screen.dart';

/// The Jobs tab's content (frontend rebuild Phase 1, prototype `ui.isJobs`)
/// — chrome comes from [MainTabScreen]/[AppShell]. Adds a bookmark toggle
/// (reuses Brick 7's `applications` 'saved' state — no new backend), a
/// source filter row, and a "Shortlist · N" pill. `RefreshIndicator` is
/// Flutter's pull-to-refresh — wrap a scrollable, give it an `onRefresh`
/// callback that returns a Future, and it shows the spinner until that
/// Future completes.
class JobsListBody extends ConsumerStatefulWidget {
  const JobsListBody({super.key});

  @override
  ConsumerState<JobsListBody> createState() => _JobsListBodyState();
}

class _JobsListBodyState extends ConsumerState<JobsListBody> {
  final ApiClient _apiClient = ApiClient();
  final RefreshThrottle _throttle = RefreshThrottle();

  bool _isLoading = true;
  bool _isRefreshing = false;
  String? _errorMessage;
  DateTime? _staleSince; // Phase 5: non-null = painting cached data
  DateTime? _lastUpdated; // ADR-028: for the "updated Xm ago" indicator
  List<Job> _jobs = [];
  List<ApplicationItem> _applications = [];

  @override
  void initState() {
    super.initState();
    _loadJobs();
  }

  /// Phase 5 stale-while-revalidate: cached first page paints instantly
  /// (no skeleton), fresh fetch updates underneath; on fetch failure the
  /// cached paint stays with a stale banner.
  Future<bool> _paintFromCache() async {
    if (_jobs.isNotEmpty) return true;
    final entry = await CacheService.instance.read<List<Job>>(
      CacheService.keyJobs,
      (json) => (json as List).map((j) => Job.fromJson((j as Map).cast<String, dynamic>())).toList(),
    );
    if (entry == null || !mounted) return false;
    setState(() {
      _jobs = entry.data;
      _staleSince = entry.cachedAt;
      _isLoading = false;
    });
    return true;
  }

  /// [force] separates a PASSIVE load (initState) from one triggered by an
  /// explicit action or a mutation (pull-to-refresh, bookmarking). ADR-028: a
  /// passive load serves cache younger than 5 minutes and skips the GET calls;
  /// force always refetches. `_refresh` (the POST /jobs/refresh pull) forces
  /// this afterward, because a refresh that ignored its own new rows would be
  /// pointless.
  Future<void> _loadJobs({bool force = false}) async {
    setState(() => _errorMessage = null);
    final categories = ref.read(jobFilterProvider).categories;
    // The disk cache holds ONE list under a single key, so it can only ever be
    // trusted for one category selection. Serving it for another would paint
    // engineering roles at someone who just asked for Sales. Only the default
    // selection is cache-eligible; anything else always fetches.
    final cacheable = setEquals(categories, kDefaultJobCategories);

    final painted = cacheable && await _paintFromCache();
    _lastUpdated = await CacheService.instance.cachedAtFor(CacheService.keyJobs);

    if (!force && painted && await CacheService.instance.isFresh(CacheService.keyJobs)) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    if (!painted && mounted) setState(() => _isLoading = true);
    try {
      // fetchAllJobs (not fetchJobs(limit: 50)): the Jobs tab shows the entire
      // pool, whatever the target role. The old 50-cap silently hid everything
      // past the newest 50 postings.
      //
      // `categories` narrows SERVER-side (ADR-003 v3). Without it the broad pool
      // would push 1,400+ postings down a mobile connection to show the ~200 in
      // the user's disciplines — and silently lose the tail past fetchAllJobs's
      // page ceiling.
      final results = await Future.wait([
        _apiClient.fetchAllJobs(categories: categories),
        _apiClient.fetchApplications(),
      ]);
      if (!mounted) return;
      setState(() {
        _jobs = results[0] as List<Job>;
        _applications = results[1] as List<ApplicationItem>;
        _staleSince = null;
        _isLoading = false;
        _lastUpdated = DateTime.now();
      });
      if (cacheable) {
        await CacheService.instance.write(CacheService.keyJobs, [for (final j in _jobs) j.raw]);
      }
      await CacheService.instance.write(CacheService.keyApplications, [for (final a in _applications) a.raw]);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = painted ? null : e.toString(); // stale banner covers the cached case
        _isLoading = false;
      });
    }
  }

  Future<void> _refresh() async {
    // Pull-to-refresh keeps its own indicator; TaskCenter's own completion
    // toast (success or failure, with Retry) confirms the outcome even if
    // the user has tabbed away by the time the background task finishes
    // (Phase 2 / ADR-011 — refreshes can take well over a minute across four
    // sources). ADR-028: debounced so a rapid triple-pull fires the
    // (rate-limited) server refresh once.
    if (!_throttle.shouldRun()) return;
    setState(() => _isRefreshing = true);
    await ref.read(taskCenterProvider.notifier).start(TaskKind.jobsRefresh, _apiClient.refreshJobs);
    await _awaitJobsRefresh();
    if (mounted) setState(() => _isRefreshing = false);
    await _loadJobs(force: true);
  }

  /// Polls TaskCenter until the jobs-refresh task settles. Bounded locally —
  /// not TaskCenter's 10-minute give-up — so pull-to-refresh's spinner can't
  /// hang indefinitely; the task keeps running and TaskCenter keeps
  /// following it (and will still toast on completion) either way.
  Future<void> _awaitJobsRefresh() async {
    final tasks = ref.read(taskCenterProvider.notifier);
    final startedAt = DateTime.now();
    while (mounted) {
      final task = tasks.taskFor(TaskKind.jobsRefresh);
      if (task == null || !task.isActive) return;
      if (DateTime.now().difference(startedAt) > const Duration(minutes: 2)) return;
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
  }

  bool _isTracked(String jobId) => _applications.any((a) => a.jobId == jobId);

  Future<void> _toggleBookmark(Job job) async {
    if (_isTracked(job.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Already in your tracker — manage it from Track')),
      );
      return;
    }
    try {
      await _apiClient.saveToTracker(job.id);
      await _loadJobs(force: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // ADR-003 v3: category is the one axis the SERVER applies, so a change to it
    // has to refetch — the rest of the filter still narrows in memory. `ref.listen`
    // (not a watch + compare) because this is a side effect, and running a fetch
    // inside build() would refire on every rebuild.
    ref.listen(jobFilterProvider.select((f) => f.categories), (previous, next) {
      if (previous != null && !setEquals(previous, next)) unawaited(_loadJobs(force: true));
    });

    // Phase 6 (§4.4): the one shared filter narrows the in-memory pool — the
    // list, the sheet's "Show N", and the header dot all read this same state,
    // so they can't disagree. Toggling never fetches (except category, above).
    final filter = ref.watch(jobFilterProvider);
    final filteredJobs = _jobs.where(filter.matches).toList();

    // Phase 3A: the header stays up in every state (loading, error,
    // loaded) — only the content region below it changes.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageHeader(
          embedded: true,
          title: 'Jobs',
          subtitle: _isLoading ? null : '${filteredJobs.length} posting${filteredJobs.length == 1 ? '' : 's'}',
          actions: [
            HeaderActionButton(
              icon: AppIconName.sliders,
              tooltip: 'Filter jobs',
              showDot: filter.isActive,
              onPressed: _jobs.isEmpty ? null : () => showJobFilterSheet(context, pool: _jobs),
            ),
            HeaderActionButton(
              icon: AppIconName.autoAwesome,
              tooltip: 'Customize resume for a JD',
              onPressed: () => context.push('/jd-resume'),
            ),
            HeaderActionButton(
              icon: AppIconName.fileText,
              tooltip: 'Fill an application form',
              onPressed: () => context.push('/form-fill'),
            ),
            HeaderActionButton(
              icon: AppIconName.plus,
              tooltip: 'Add a job manually',
              onPressed: () async {
                await context.push('/add-job');
                if (mounted) unawaited(_loadJobs(force: true));
              },
            ),
            HeaderActionButton(
              icon: AppIconName.refresh,
              tooltip: 'Refresh jobs',
              busy: _isRefreshing,
              onPressed: _refresh,
            ),
          ],
        ),
        Expanded(child: _buildContent(filteredJobs)),
      ],
    );
  }

  Widget _buildContent(List<Job> filteredJobs) {
    if (_isLoading) {
      // Phase 5 (§Phase 5 acceptance): no skeleton — cold load shows the brand
      // loader; a warm load paints the cached list instantly instead.
      return const Center(child: AppLoader());
    }

    if (_errorMessage != null) {
      return Center(
        child: EmptyState(
          icon: AppIconName.alertTriangle,
          title: 'Could not load jobs',
          message: _errorMessage,
          actionLabel: 'Retry',
          onAction: () => _loadJobs(force: true),
        ),
      );
    }

    final shortlistCount = _applications.where((a) => a.state == 'saved').length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_staleSince != null) ...[
          StaleBanner(cachedAt: _staleSince!, onRetry: () => _loadJobs(force: true)),
          const SizedBox(height: AppSpacing.space3),
        ],
        Row(
          children: [
            // ADR-028: keep the passive 5-minute freshness window visible.
            if (_staleSince == null && lastUpdatedLabel(_lastUpdated) != null)
              Text(
                lastUpdatedLabel(_lastUpdated)!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.c.inkFaint),
              ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ShortlistScreen(applications: _applications)),
              ),
              icon: AppIcon(AppIconName.bookmark, size: 15, color: context.c.accent),
              label: Text('Shortlist · $shortlistCount'),
              style: TextButton.styleFrom(
                backgroundColor: context.c.accentSoft,
                foregroundColor: context.c.accent,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                shape: const StadiumBorder(),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.space3),
        Expanded(child: _jobList(filteredJobs)),
      ],
    );
  }

  Widget _jobList(List<Job> jobs) {
    if (jobs.isEmpty) {
      // Distinguish "no postings at all" from "your filter hid them all" — the
      // fix for the latter is Clear filters, not pull-to-refresh.
      final filter = ref.read(jobFilterProvider);
      if (_jobs.isNotEmpty && filter.isActive) {
        return ListView(
          children: [
            EmptyState(
              icon: AppIconName.sliders,
              title: 'No jobs match your filters',
              message: 'Widen or clear your filters to see more of the pool.',
              actionLabel: 'Clear filters',
              onAction: () => ref.read(jobFilterProvider.notifier).clearAll(),
            ),
          ],
        );
      }
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          children: const [
            EmptyState(
              icon: AppIconName.briefcase,
              title: 'No jobs yet',
              message: 'Pull down to fetch today\'s postings.',
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: jobs.length,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.space3),
        itemBuilder: (context, index) => _jobCard(jobs[index]),
      ),
    );
  }

  Widget _jobCard(Job job) {
    return JobCard(
      title: job.title,
      company: job.company ?? 'Unknown company',
      location: job.location,
      source: job.source,
      sourceUrl: job.redirectUrl,
      salary: job.salaryLabel,
      postedAt: job.postedAtLabel,
      bookmarked: _isTracked(job.id),
      onBookmark: () => _toggleBookmark(job),
      onPress: () => context.push('/job', extra: JobArgs(job: job)),
      legitimacyTier: job.legitimacyTier,
    );
  }
}
