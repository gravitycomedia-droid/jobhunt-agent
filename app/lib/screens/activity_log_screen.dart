import 'package:flutter/material.dart';

import '../models/activity_item.dart';
import '../services/api_client.dart';
import '../theme/app_tokens.dart';
import '../widgets/activity_style.dart';
import '../widgets/app_icon.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_skeleton.dart';
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

  bool _isLoading = true;
  String? _errorMessage;
  List<ActivityItem> _activity = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final activity = await _apiClient.fetchActivity();
      setState(() {
        _activity = activity;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const PageHeader(title: 'Agent activity', showBack: true),
      body: RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    if (_isLoading) {
      return ListView.separated(
        padding: const EdgeInsets.all(AppSpacing.screenPadX),
        itemCount: 5,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.space3),
        itemBuilder: (_, _) => const LoadingSkeleton(variant: SkeletonVariant.block, height: 56),
      );
    }

    if (_errorMessage != null) {
      return ListView(
        children: [
          EmptyState(
            icon: AppIconName.alertTriangle,
            title: 'Could not load activity',
            message: _errorMessage,
            actionLabel: 'Retry',
            onAction: _load,
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

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(AppSpacing.screenPadX, AppSpacing.space2, AppSpacing.screenPadX, AppSpacing.space6),
      itemCount: _activity.length,
      itemBuilder: (context, index) {
        final item = _activity[index];
        final isLast = index == _activity.length - 1;
        final glyph = activityGlyphFor(item);

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
                  if (!isLast) Expanded(child: Container(width: 2, color: AppColors.border, margin: const EdgeInsets.only(top: 4))),
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
                            style: TextStyle(fontFamily: AppTypography.monoData.fontFamily, fontSize: 11, color: AppColors.textTertiary),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(item.detail, style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary)),
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
