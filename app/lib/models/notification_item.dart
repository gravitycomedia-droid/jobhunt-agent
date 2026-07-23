/// GET /notifications (frontend rebuild v2, Phase 4 backend, §4.13). The
/// persistent in-app record behind the Brick-8 FCM push — a push is
/// ephemeral, these rows give the bell its history and unread count.
///
/// Phase 5 uses only [NotificationFeed.unreadCount] (Home's bell badge);
/// the full feed screen is Phase 9. Mirrors the `notifications` table
/// (migration 023) and the router's `{items, unread_count}` envelope.
class NotificationItem {
  final String id;
  final String kind;
  final String title;
  final String body;
  final String? actionType;
  final String? actionRef;
  final DateTime createdAt;
  final DateTime? readAt;
  final Map<String, dynamic> raw;

  NotificationItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    this.actionType,
    this.actionRef,
    required this.createdAt,
    this.readAt,
    this.raw = const {},
  });

  bool get isUnread => readAt == null;

  factory NotificationItem.fromJson(Map<String, dynamic> json) {
    return NotificationItem(
      raw: json,
      id: json['id'] as String,
      kind: json['kind'] as String,
      title: json['title'] as String,
      body: json['body'] as String,
      actionType: json['action_type'] as String?,
      actionRef: json['action_ref'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      readAt: json['read_at'] == null ? null : DateTime.parse(json['read_at'] as String),
    );
  }
}

class NotificationFeed {
  final List<NotificationItem> items;
  final int unreadCount;

  const NotificationFeed({this.items = const [], this.unreadCount = 0});

  factory NotificationFeed.fromJson(Map<String, dynamic> json) {
    return NotificationFeed(
      items: ((json['items'] as List?) ?? const [])
          .map((n) => NotificationItem.fromJson((n as Map).cast<String, dynamic>()))
          .toList(),
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
    );
  }
}
