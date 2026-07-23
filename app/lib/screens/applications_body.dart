import 'package:flutter/material.dart';

import '../models/application_item.dart';
import '../services/api_client.dart';
import '../services/cache_service.dart';
import '../services/refresh_throttle.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_loader.dart';
import '../widgets/application_card.dart';
import '../widgets/celebration_modal.dart';
import '../widgets/empty_state.dart';
import '../widgets/kanban_column.dart';
import '../widgets/page_header.dart';
import '../widgets/stale_banner.dart';
import '../widgets/task_toast.dart';
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

  /// Rebuilds an item at a new pipeline stage. Patches `raw` too (not just the
  /// `state` field) so the moved card round-trips correctly through the cache —
  /// [ApplicationItem.copyWith] leaves `raw` untouched, which would persist the
  /// OLD state on the next cache write.
  ApplicationItem _withState(ApplicationItem a, String state) {
    return ApplicationItem.fromJson({
      ...a.raw,
      'state': state,
      'state_changed_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// §4.9 Kanban drag: move [item] to [target] with an OPTIMISTIC update —
  /// the card jumps columns instantly, the PATCH runs underneath, and a
  /// failure reverts it (never leave the board lying about server state).
  /// Landing in `offer` fires the celebration once (its own heavy haptic).
  Future<void> _moveTo(ApplicationItem item, String target) async {
    if (item.state == target) return;
    final previous = item.state;
    setState(() {
      _items = _items.map((a) => a.id == item.id ? _withState(a, target) : a).toList();
    });
    try {
      await _apiClient.updateApplicationState(item.id, target);
      await CacheService.instance.write(CacheService.keyApplications, [for (final a in _items) a.raw]);
      if (target == 'offer' && mounted) {
        await showCelebration(context);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _items = _items.map((a) => a.id == item.id ? _withState(a, previous) : a).toList();
      });
      showTaskToast(success: false, message: 'Could not move to $target — $e');
    }
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
      // Phase 5 (§Phase 5 acceptance): no skeleton — a cold load with nothing
      // cached shows the brand loader; a warm load paints from cache instead.
      return const Center(child: AppLoader());
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
              _laneFor(state),
              const SizedBox(width: AppSpacing.space3),
            ],
          ],
        ),
      ),
    );
  }

  /// One pipeline lane wired as a drop target (§4.9). `onWillAcceptWithDetails`
  /// rejects a drop back onto the card's own column so a same-lane release is a
  /// no-op rather than a pointless PATCH.
  Widget _laneFor(String state) {
    final cards = _items.where((a) => a.state == state).toList();
    return DragTarget<ApplicationItem>(
      onWillAcceptWithDetails: (d) => d.data.state != state,
      onAcceptWithDetails: (d) => _moveTo(d.data, state),
      builder: (context, candidate, rejected) => KanbanColumn(
        stage: state,
        count: cards.length,
        highlighted: candidate.isNotEmpty,
        children: [for (final a in cards) _draggableCard(a)],
      ),
    );
  }

  /// A Kanban card that a long-press picks up for dragging while a plain tap
  /// still opens its detail sheet — the two gestures don't collide, so drag
  /// (move stages) and tap (edit notes/follow-ups) coexist.
  Widget _draggableCard(ApplicationItem a) {
    final card = ApplicationCard(
      title: a.job.title,
      company: a.job.company ?? 'Unknown company',
      salary: a.job.salaryLabel,
      onTap: () => _openDetail(a),
    );
    // Column inner width: 264 − 8px padding each side.
    const cardWidth = 248.0;
    return LongPressDraggable<ApplicationItem>(
      data: a,
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(
          opacity: 0.92,
          child: SizedBox(width: cardWidth, child: card),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: card),
      child: card,
    );
  }
}
