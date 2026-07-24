import 'package:flutter/material.dart';

import '../models/notification_item.dart';
import '../services/api_client.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_loader.dart';
import '../widgets/empty_state.dart';
import '../widgets/page_header.dart';

/// §4.13 — the in-app notification feed. The persistent record behind the
/// Brick-8 FCM push (a push is ephemeral; these rows give the bell its history
/// and unread count). Reached from Home's bell and Profile's "Notifications"
/// row.
///
/// Reads GET /notifications; marks read via PATCH /notifications/{id}/read and
/// POST /notifications/read-all. Read state lives server-side (`read_at`), so
/// it persists across restarts for free — this screen keeps a local copy only
/// to reflect a tap instantly (optimistic, reverted on failure).
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final ApiClient _apiClient = ApiClient();

  bool _isLoading = true;
  String? _errorMessage;
  List<NotificationItem> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _errorMessage = null);
    if (_items.isEmpty && mounted) setState(() => _isLoading = true);
    try {
      final feed = await _apiClient.fetchNotifications(limit: 50);
      if (!mounted) return;
      setState(() {
        _items = feed.items;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  bool get _hasUnread => _items.any((n) => n.isUnread);

  /// Optimistically mark one row read, then persist. On failure, revert the row
  /// so the dot doesn't silently lie about server state.
  Future<void> _markRead(NotificationItem item) async {
    if (!item.isUnread) return;
    final index = _items.indexWhere((n) => n.id == item.id);
    if (index < 0) return;
    final original = _items[index];
    setState(() => _items[index] = _copyRead(original, DateTime.now()));
    try {
      await _apiClient.markNotificationRead(item.id);
    } catch (_) {
      if (mounted) setState(() => _items[index] = original);
    }
  }

  Future<void> _markAllRead() async {
    if (!_hasUnread) return;
    final snapshot = List<NotificationItem>.from(_items);
    final now = DateTime.now();
    setState(() => _items = [for (final n in _items) n.isUnread ? _copyRead(n, now) : n]);
    try {
      await _apiClient.markAllNotificationsRead();
    } catch (_) {
      if (mounted) setState(() => _items = snapshot);
    }
  }

  /// The model has no copyWith — this rebuilds a read copy from `raw` so the
  /// unread dot flips without a round-trip.
  NotificationItem _copyRead(NotificationItem n, DateTime readAt) {
    return NotificationItem(
      id: n.id,
      kind: n.kind,
      title: n.title,
      body: n.body,
      actionType: n.actionType,
      actionRef: n.actionRef,
      createdAt: n.createdAt,
      readAt: readAt,
      raw: n.raw,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PageHeader(
        title: 'Notifications',
        showBack: true,
        actions: [
          if (_hasUnread)
            TextButton(
              onPressed: _markAllRead,
              child: Text(
                'Mark all read',
                style: AppTypography.caption.copyWith(color: AppColors.brand600, fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
      body: RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    if (_isLoading && _items.isEmpty) {
      return const Center(child: AppLoader());
    }
    if (_errorMessage != null && _items.isEmpty) {
      return ListView(
        children: [
          EmptyState(
            icon: AppIconName.alertTriangle,
            title: 'Could not load notifications',
            message: _errorMessage,
            actionLabel: 'Retry',
            onAction: _load,
          ),
        ],
      );
    }
    if (_items.isEmpty) {
      return ListView(
        children: const [
          EmptyState(
            icon: AppIconName.bell,
            title: 'No notifications yet',
            message: 'When the agent finds matches, drafts a follow-up, or moves an application, you\'ll hear about it here.',
          ),
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadX, vertical: AppSpacing.space3),
      itemCount: _items.length,
      separatorBuilder: (_, _) => const Divider(height: 1, color: AppColors.border),
      itemBuilder: (_, i) => _row(_items[i]),
    );
  }

  Widget _row(NotificationItem n) {
    final unread = n.isUnread;
    return InkWell(
      onTap: unread ? () => _markRead(n) : null,
      child: Opacity(
        opacity: unread ? 1 : 0.72,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.space3 + 1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _iconBox(n.kind),
              const SizedBox(width: AppSpacing.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(n.title, style: AppTypography.body.copyWith(fontSize: 14, fontWeight: FontWeight.w600, height: 1.35)),
                    const SizedBox(height: 2),
                    Text(n.body, style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary, height: 1.4)),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.space3),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _relativeTime(n.createdAt),
                    style: AppTypography.label.copyWith(
                      fontFamily: AppTypography.monoData.fontFamily,
                      color: AppColors.textTertiary,
                    ),
                  ),
                  if (unread) ...[
                    const SizedBox(height: 6),
                    Container(width: 8, height: 8, decoration: const BoxDecoration(color: AppColors.brand600, shape: BoxShape.circle)),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconBox(String kind) {
    final (icon, color) = _kindStyle(kind);
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: AppColors.brandSoft, borderRadius: AppRadius.mdRadius),
      child: AppIcon(icon, size: 18, color: color),
    );
  }

  /// `kind` is free-text server-side (migration 023 has no CHECK, so new kinds
  /// ship without a migration) — map the ones we know, default gracefully.
  (AppIconName, Color) _kindStyle(String kind) => switch (kind) {
        'agent_run' => (AppIconName.bot, AppColors.brand600),
        'match' => (AppIconName.target, AppColors.brand600),
        'application' => (AppIconName.briefcase, AppColors.infoText),
        'followup' => (AppIconName.send, AppColors.warningText),
        'chat' => (AppIconName.messageCircle, AppColors.brand600),
        _ => (AppIconName.bell, AppColors.brand600),
      };
}

/// "now" / "5m" / "3h" / "2d" / a date past a week. Compact, mono-friendly.
String _relativeTime(DateTime when) {
  final diff = DateTime.now().difference(when);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${when.day} ${months[when.month - 1]}';
}
