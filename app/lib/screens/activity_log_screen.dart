import 'package:flutter/material.dart';

import '../models/activity_item.dart';
import '../services/api_client.dart';
import '../services/cache_service.dart';
import '../services/refresh_throttle.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/activity_style.dart';
import '../widgets/app_icon.dart';
import '../widgets/empty_state.dart';
import '../widgets/app_loader.dart';
import '../widgets/page_header.dart';

/// Frontend rebuild Phase 3 (prototype `ui.isActivity`): "what the agent
/// did on your behalf" — every application stage change, drafted
/// follow-up, and resume tailoring event, newest first. Reached from
/// Home's "Recent activity" section ("View all") — see
/// server/services/activity.py for how the feed is built.
class ActivityLogScreen extends StatefulWidget {
  const ActivityLogScreen({super.key});

  @override
  State<ActivityLogScreen> createState() => _ActivityLogScreenState();
}

class _ActivityLogScreenState extends State<ActivityLogScreen> {
  final ApiClient _apiClient = ApiClient();
  final RefreshThrottle _throttle = RefreshThrottle();

  bool _isLoading = true;
  bool _isRefreshing = false;
  String? _errorMessage;
  List<ActivityItem> _activity = [];
  DateTime? _lastUpdated;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Phase 5 + ADR-028: paint the cached feed instantly, and on a PASSIVE load
  /// (opening the screen) skip the network while that cache is under
  /// [CacheService.freshFor]. [force] — pull-to-refresh, Retry — always
  /// refetches, debounced against a burst of pulls.
  Future<void> _load({bool force = false}) async {
    if (force && !_throttle.shouldRun()) return;
    setState(() => _errorMessage = null);

    var painted = _activity.isNotEmpty;
    if (!painted) {
      final entry = await CacheService.instance.read<List<ActivityItem>>(
        CacheService.keyActivity,
        (json) => (json as List).map((a) => ActivityItem.fromJson((a as Map).cast<String, dynamic>())).toList(),
      );
      if (entry != null && mounted) {
        painted = true;
        setState(() {
          _activity = entry.data;
          _lastUpdated = entry.cachedAt;
          _isLoading = false;
        });
      }
    }

    if (!force && painted && await CacheService.instance.isFresh(CacheService.keyActivity)) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    if (mounted) {
      setState(() {
        _isLoading = !painted;
        _isRefreshing = painted;
      });
    }
    try {
      final activity = await _apiClient.fetchActivity();
      if (!mounted) return;
      setState(() {
        _activity = activity;
        _lastUpdated = DateTime.now();
        _isLoading = false;
        _isRefreshing = false;
      });
      await CacheService.instance.write(CacheService.keyActivity, [for (final a in activity) a.raw]);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = painted ? null : e.toString();
        _isLoading = false;
        _isRefreshing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const PageHeader(title: 'Agent activity', showBack: true),
      body: RefreshIndicator(onRefresh: () => _load(force: true), child: _body()),
    );
  }

  Widget _body() {
    // Phase 10: skeletons retired — a cold load shows the brand AppLoader
    // (matches the tab pattern); warm reloads keep the current list painted.
    if (_isLoading) {
      return const Center(child: AppLoader());
    }

    if (_errorMessage != null) {
      return ListView(
        children: [
          EmptyState(
            icon: AppIconName.alertTriangle,
            title: 'Could not load activity',
            message: _errorMessage,
            actionLabel: 'Retry',
            onAction: () => _load(force: true),
          ),
        ],
      );
    }

    if (_activity.isEmpty) {
      return ListView(
        children: const [
          EmptyState(
            icon: AppIconName.bell,
            title: 'No activity yet',
            message: 'Once the agent matches, tailors, or drafts something on your behalf, it shows up here.',
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _updatedRow(),
        Expanded(child: _timeline()),
      ],
    );
  }

  /// "Updated 3m ago · pull to refresh" — ADR-028 asks the passive freshness
  /// window to be visible rather than looking like a screen that never updates.
  Widget _updatedRow() {
    final label = lastUpdatedLabel(_lastUpdated);
    if (label == null && !_isRefreshing) return const SizedBox.shrink();
    final style = AppTypography.caption.copyWith(color: context.c.inkFaint);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.screenPadX, AppSpacing.space3, AppSpacing.screenPadX, 0),
      child: _isRefreshing
          ? Row(
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.6, color: context.c.inkFaint),
                ),
                const SizedBox(width: 8),
                Text('Refreshing…', style: style),
              ],
            )
          : Text('$label · pull to refresh', style: style),
    );
  }

  Widget _timeline() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(AppSpacing.screenPadX, AppSpacing.space2, AppSpacing.screenPadX, AppSpacing.space6),
      itemCount: _activity.length,
      itemBuilder: (context, index) {
        final item = _activity[index];
        final isLast = index == _activity.length - 1;
        final glyph = activityGlyphFor(context, item);

        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: glyph.bg, shape: BoxShape.circle),
                    child: AppIcon(glyph.icon, size: 16, color: glyph.fg),
                  ),
                  if (!isLast) Expanded(child: Container(width: 2, color: context.c.border, margin: EdgeInsets.only(top: 4))),
                ],
              ),
              const SizedBox(width: AppSpacing.space3),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.space4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(item.title, style: AppTypography.body.copyWith(fontWeight: FontWeight.w600))),
                          Text(
                            _formatTimestamp(item.timestamp),
                            style: TextStyle(fontFamily: AppTypography.monoData.fontFamily, fontSize: 11, color: context.c.inkFaint),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(item.detail, style: AppTypography.bodySm.copyWith(color: context.c.inkSoft)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Relative-ish timestamp for the timeline — matches the prototype's
/// compact `a.timestamp` (mono, right-aligned). Falls back to a date once
/// something is more than a week old, since "23 days ago" is less
/// scannable than "Jun 18" at that distance.
String _formatTimestamp(DateTime timestamp) {
  final now = DateTime.now();
  final local = timestamp.toLocal();
  final diff = now.difference(local);

  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';

  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${months[local.month - 1]} ${local.day}';
}
