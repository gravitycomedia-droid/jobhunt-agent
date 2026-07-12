import 'package:flutter/material.dart';

import '../models/application_item.dart';
import '../services/api_client.dart';
import '../services/cache_service.dart';
import '../services/refresh_throttle.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/application_card.dart';
import '../widgets/empty_state.dart';
import '../widgets/kanban_column.dart';
import '../widgets/page_header.dart';
import '../widgets/page_skeletons.dart';
import '../widgets/stale_banner.dart';
import 'app_detail_screen.dart';

/// The Track tab's content (chrome comes from [MainTabScreen] /
/// [AppShell]). Brick 7: the application pipeline as a
/// horizontally-scrolling Kanban board — one [KanbanColumn] per
/// [kApplicationStates] stage. Frontend rebuild Phase 2: tapping a card
/// now opens [AppDetailScreen] (notes + on-demand follow-ups) instead of
/// the old stage-picker bottom sheet — moving stages still happens there,
/// just alongside the new fields that didn't fit in a sheet.
class ApplicationsBody extends StatefulWidget {
  const ApplicationsBody({super.key});

  @override
  State<ApplicationsBody> createState() => _ApplicationsBodyState();
}

class _ApplicationsBodyState extends State<ApplicationsBody> {
  final ApiClient _apiClient = ApiClient();
  final RefreshThrottle _throttle = RefreshThrottle();

  bool _isLoading = true;
  String? _errorMessage;
  DateTime? _staleSince; // Phase 5: non-null = painting cached data
  DateTime? _lastUpdated; // ADR-028: for the "updated Xm ago" indicator
  List<ApplicationItem> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<bool> _paintFromCache() async {
    if (_items.isNotEmpty) return true;
    final entry = await CacheService.instance.read<List<ApplicationItem>>(
      CacheService.keyApplications,
      (json) => (json as List).map((a) => ApplicationItem.fromJson((a as Map).cast<String, dynamic>())).toList(),
    );
    if (entry == null || !mounted) return false;
    setState(() {
      _items = entry.data;
      _staleSince = entry.cachedAt;
      _isLoading = false;
    });
    return true;
  }

  /// [force] distinguishes an EXPLICIT refresh (pull-to-refresh, header
  /// button) from a PASSIVE one (initState). ADR-028: passive loads serve the
  /// cache and skip the network when it's under 5 minutes old; an explicit
  /// refresh always hits the network but is debounced against rapid re-pulls.
  Future<void> _load({bool force = false}) async {
    if (force && !_throttle.shouldRun()) return;
    setState(() => _errorMessage = null);
    final painted = await _paintFromCache();
    _lastUpdated = await CacheService.instance.cachedAtFor(CacheService.keyApplications);

    if (!force && painted && await CacheService.instance.isFresh(CacheService.keyApplications)) {
      // Fresh cache already on screen — nothing to fetch.
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    if (!painted && mounted) setState(() => _isLoading = true);
    try {
      final items = await _apiClient.fetchApplications();
      if (!mounted) return;
      setState(() {
        _items = items;
        _staleSince = null;
        _isLoading = false;
        _lastUpdated = DateTime.now();
      });
      await CacheService.instance.write(CacheService.keyApplications, [for (final a in items) a.raw]);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = painted ? null : e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _openDetail(ApplicationItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AppDetailScreen(
          application: item,
          onChanged: (updated) => setState(() {
            _items = _items.map((a) => a.id == updated.id ? updated : a).toList();
          }),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageHeader(
          embedded: true,
          title: 'Track',
          subtitle: _isLoading ? null : '${_items.length} application${_items.length == 1 ? '' : 's'} in the pipeline',
          actions: [
            HeaderActionButton(
              icon: AppIconName.refresh,
              tooltip: 'Reload board',
              onPressed: () => _load(force: true),
            ),
          ],
        ),
        if (_staleSince != null) ...[
          StaleBanner(cachedAt: _staleSince!, onRetry: () => _load(force: true)),
          const SizedBox(height: AppSpacing.space3),
        ] else if (!_isLoading && lastUpdatedLabel(_lastUpdated) != null) ...[
          // ADR-028: make the 5-minute passive window visible.
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.space2),
            child: Text(
              lastUpdatedLabel(_lastUpdated)!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textTertiary),
            ),
          ),
        ],
        Expanded(child: _buildContent()),
      ],
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      // Phase 4C: Kanban shape — column headers + card blocks per column.
      return KanbanSkeleton(columns: kApplicationStates.length);
    }

    if (_errorMessage != null) {
      return Center(
        child: EmptyState(
          icon: AppIconName.alertTriangle,
          title: 'Could not load applications',
          message: _errorMessage,
          actionLabel: 'Retry',
          onAction: () => _load(force: true),
        ),
      );
    }

    if (_items.isEmpty) {
      return Center(
        child: EmptyState(
          icon: AppIconName.columns,
          title: 'Nothing tracked yet',
          message: 'Save a job from Matches to start moving it through the pipeline.',
          actionLabel: 'Retry',
          onAction: () => _load(force: true),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: SingleChildScrollView(
        padding: EdgeInsets.zero,
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final state in kApplicationStates) ...[
              KanbanColumn(
                stage: state,
                count: _items.where((a) => a.state == state).length,
                children: _items
                    .where((a) => a.state == state)
                    .map(
                      (a) => ApplicationCard(
                        title: a.job.title,
                        company: a.job.company ?? 'Unknown company',
                        salary: a.job.salaryLabel,
                        onTap: () => _openDetail(a),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(width: AppSpacing.space3),
            ],
          ],
        ),
      ),
    );
  }
}
