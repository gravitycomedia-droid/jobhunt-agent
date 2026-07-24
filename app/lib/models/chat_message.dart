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
}

/// One conversation. `GET /chat/threads` returns these newest-active first;
/// the screen only needs the most recent thread's id to reload history on open.
class ChatThread {
  final String id;
  final String? title;

  const ChatThread({required this.id, this.title});

  factory ChatThread.fromJson(Map<String, dynamic> json) {
    return ChatThread(id: json['id'] as String, title: json['title'] as String?);
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
