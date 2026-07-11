import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../models/application_item.dart';
import '../models/job.dart';
import '../services/api_client.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/empty_state.dart';
import '../widgets/job_card.dart';
import '../widgets/loading_skeleton.dart';
import '../widgets/page_header.dart';
import '../widgets/task_toast.dart';
import 'add_job_screen.dart';
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

  bool _isLoading = true;
  bool _isRefreshing = false;
  String? _errorMessage;
  List<Job> _jobs = [];
  List<ApplicationItem> _applications = [];
  String? _sourceFilter;

  @override
  void initState() {
    super.initState();
    _loadJobs();
  }

  Future<void> _loadJobs() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final results = await Future.wait([_apiClient.fetchJobs(limit: 50), _apiClient.fetchApplications()]);
      setState(() {
        _jobs = results[0] as List<Job>;
        _applications = results[1] as List<ApplicationItem>;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _refresh() async {
    // Pull-to-refresh keeps its own indicator; the toast confirms the
    // outcome even if the user has tabbed away by the time it finishes
    // (Phase 2 — refreshes can take up to a minute).
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
    await _loadJobs();
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
      await _loadJobs();
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
              icon: AppIconName.plus,
              tooltip: 'Add a job manually',
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddJobScreen()));
                if (mounted) unawaited(_loadJobs());
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
          title: 'Could not load jobs',
          message: _errorMessage,
          actionLabel: 'Retry',
          onAction: _loadJobs,
        ),
      );
    }

    final shortlistCount = _applications.where((a) => a.state == 'saved').length;
    final sources = _jobs.map((j) => j.source).toSet().toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
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
      salary: job.salaryLabel,
      postedAt: job.postedAtLabel,
      bookmarked: _isTracked(job.id),
      onBookmark: () => _toggleBookmark(job),
    );
  }
}
