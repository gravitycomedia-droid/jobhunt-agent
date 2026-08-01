// Career chat (frontend rebuild v2, Phase 8, §4.10). The grounded career
// assistant — `POST /chat` (202 + poll), backed by the `chat_threads` +
// `chat_messages` tables (migration 024). The server does all the grounding
// and anti-fabrication (server/services/chat.py); these are just the wire
// shapes the screen renders.

/// One turn in a conversation. Mirrors a `chat_messages` row — [role] is
/// 'user' or 'assistant', the only two the server ever writes.
class ChatMessage {
  final String? id; // null for a locally-appended user turn not yet round-tripped
  final String role;
  final String content;

  const ChatMessage({this.id, required this.role, required this.content});

  bool get isUser => role == 'user';

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String?,
      role: json['role'] as String,
      content: json['content'] as String,
    );
  }

  /// Only the three fields the screen renders — enough to re-hydrate a cached
  /// conversation, and deliberately not the whole server row.
  Map<String, dynamic> toJson() => {'id': id, 'role': role, 'content': content};
}

/// One conversation. `GET /chat/threads` returns these newest-active first —
/// the most recent is reloaded as the open conversation, and the rest are the
/// "Recent chats" list.
class ChatThread {
  final String id;
  final String? title;

  /// Last activity in the thread (`chat_threads.updated_at`). Null on an older
  /// server that doesn't send it — the UI just omits the timestamp then.
  final DateTime? updatedAt;

  /// Exact server JSON, kept verbatim so the list round-trips through
  /// [CacheService] and the sheet paints instantly on open.
  final Map<String, dynamic> raw;

  const ChatThread({required this.id, this.title, this.updatedAt, this.raw = const {}});

  /// What the recent-chats row shows. Threads are titled from the first message
  /// server-side, so this is the user's own words in almost every case.
  String get displayTitle {
    final t = title?.trim();
    return (t == null || t.isEmpty) ? 'Untitled chat' : t;
  }

  factory ChatThread.fromJson(Map<String, dynamic> json) {
    final updated = json['updated_at'] ?? json['created_at'];
    return ChatThread(
      raw: json,
      id: json['id'] as String,
      title: json['title'] as String?,
      updatedAt: updated is String ? DateTime.tryParse(updated)?.toLocal() : null,
    );
  }
}

/// The 202 body from `POST /chat`: the background task to poll ([taskId]) plus
/// the thread the turn landed in ([threadId] — server-created on a new chat, so
/// the client learns it here and passes it back to continue the conversation).
class ChatSendResult {
  final String taskId;
  final String threadId;

  const ChatSendResult({required this.taskId, required this.threadId});

  factory ChatSendResult.fromJson(Map<String, dynamic> json) {
    return ChatSendResult(
      taskId: json['id'] as String,
      threadId: json['thread_id'] as String,
    );
  }
}
