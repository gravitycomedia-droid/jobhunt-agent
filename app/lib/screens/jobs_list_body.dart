import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../models/application_item.dart';
import '../models/job.dart';
import '../services/api_client.dart';
import '../services/cache_service.dart';
import '../services/refresh_throttle.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/empty_state.dart';
import '../widgets/job_card.dart';
import '../widgets/page_header.dart';
import '../widgets/page_skeletons.dart';
import '../widgets/stale_banner.dart';
import '../widgets/task_toast.dart';
import 'add_job_screen.dart';
import 'form_fill_screen.dart';
import 'jd_resume_screen.dart';
import 'shortlist_screen.dart';

/// The Jobs tab's content (frontend rebuild Phase 1, prototype `ui.isJobs`)
/// — chrome comes from [MainTabScreen]/[AppShell]. Adds a bookmark toggle
/// (reuses Brick 7's `applications` 'saved' state — no new backend), a
/// source filter row, and a "Shortlist · N" pill. `RefreshIndicator` is
/// Flutter's pull-to-refresh — wrap a scrollable, give it an `onRefresh`
/// callback that returns a Future, and it shows the spinner until that
/// Future completes.
class JobsListBody extends StatefulWidget {
  const JobsListBody({super.key});

  @override
  State<JobsListBody> createState() => _JobsListBodyState();
}

class _JobsListBodyState extends State<JobsListBody> {
  final ApiClient _apiClient = ApiClient();
  final RefreshThrottle _throttle = RefreshThrottle();

  bool _isLoading = true;
  bool _isRefreshing = false;
  String? _errorMessage;
  DateTime? _staleSince; // Phase 5: non-null = painting cached data
  DateTime? _lastUpdated; // ADR-028: for the "updated Xm ago" indicator
  List<Job> _jobs = [];
  List<ApplicationItem> _applications = [];
  String? _sourceFilter;

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
    final painted = await _paintFromCache();
    _lastUpdated = await CacheService.instance.cachedAtFor(CacheService.keyJobs);

    if (!force && painted && await CacheService.instance.isFresh(CacheService.keyJobs)) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    if (!painted && mounted) setState(() => _isLoading = true);
    try {
      final results = await Future.wait([_apiClient.fetchJobs(limit: 50), _apiClient.fetchApplications()]);
      if (!mounted) return;
      setState(() {
        _jobs = results[0] as List<Job>;
        _applications = results[1] as List<ApplicationItem>;
        _staleSince = null;
        _isLoading = false;
        _lastUpdated = DateTime.now();
      });
      await CacheService.instance.write(CacheService.keyJobs, [for (final j in _jobs) j.raw]);
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
    // Pull-to-refresh keeps its own indicator; the toast confirms the
    // outcome even if the user has tabbed away by the time it finishes
    // (Phase 2 — refreshes can take up to a minute). ADR-028: debounced so a
    // rapid triple-pull fires the (rate-limited) server refresh once.
    if (!_throttle.shouldRun()) return;
    setState(() => _isRefreshing = true);
    try {
      final result = await _apiClient.refreshJobs();
      showTaskToast(
        success: true,
        message: 'Jobs refreshed — ${result['inserted'] ?? 0} new of ${result['fetched'] ?? 0} fetched',
      );
    } catch (e) {
      showTaskToast(success: false, message: 'Job refresh failed — $e', onRetry: _refresh);
    }
    if (mounted) setState(() => _isRefreshing = false);
    await _loadJobs(force: true);
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
    final filteredJobs = _sourceFilter == null ? _jobs : _jobs.where((j) => j.source == _sourceFilter).toList();

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
              icon: AppIconName.autoAwesome,
              tooltip: 'Customize resume for a JD',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const JdResumeScreen()),
              ),
            ),
            HeaderActionButton(
              icon: AppIconName.fileText,
              tooltip: 'Fill an application form',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const FormFillScreen()),
              ),
            ),
            HeaderActionButton(
              icon: AppIconName.plus,
              tooltip: 'Add a job manually',
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddJobScreen()));
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
      // Phase 4C: structure-matched skeleton — 5 job-card shapes.
      return ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: 5,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.space3),
        itemBuilder: (_, _) => const JobCardSkeleton(),
      );
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
    final sources = _jobs.map((j) => j.source).toSet().toList()..sort();

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
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textTertiary),
              ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ShortlistScreen(applications: _applications)),
              ),
              icon: const AppIcon(AppIconName.bookmark, size: 15, color: AppColors.brand600),
              label: Text('Shortlist · $shortlistCount'),
              style: TextButton.styleFrom(
                backgroundColor: AppColors.brandSoft,
                foregroundColor: AppColors.brand700,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                shape: const StadiumBorder(),
              ),
            ),
          ],
        ),
        if (sources.length > 1) ...[
          const SizedBox(height: AppSpacing.space3),
          SizedBox(
            height: 32,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _filterChip('All', _sourceFilter == null, () => setState(() => _sourceFilter = null)),
                for (final s in sources) ...[
                  const SizedBox(width: 7),
                  _filterChip(s, _sourceFilter == s, () => setState(() => _sourceFilter = s)),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.space3),
        Expanded(child: _jobList(filteredJobs)),
      ],
    );
  }

  Widget _filterChip(String label, bool selected, VoidCallback onTap) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: AppColors.brandSoft,
      labelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? AppColors.brand700 : AppColors.textSecondary),
      side: BorderSide(color: selected ? AppColors.brandSoftBorder : AppColors.border),
      shape: const StadiumBorder(),
    );
  }

  Widget _jobList(List<Job> jobs) {
    if (jobs.isEmpty) {
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
    );
  }
}
