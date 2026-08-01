import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import '../models/background_task.dart';
import '../models/chat_message.dart';
import 'api_client.dart';
import 'cache_service.dart';

/// Observable state for one career-chat conversation (§4.10).
///
/// [initialLoading] = the on-open history fetch is in flight (brand loader, not
/// an empty screen). [sending] = a turn is awaiting the assistant (the typing
/// indicator). [sendError] non-null = the last turn failed and is retryable; the
/// already-sent user bubble stays put. Empty [messages] with neither flag set is
/// the mascot-greeting state.
class ChatState {
  const ChatState({
    this.messages = const [],
    this.threadId,
    this.threads = const [],
    this.threadsUpdatedAt,
    this.initialLoading = false,
    this.refreshing = false,
    this.sending = false,
    this.sendError,
    this.greetingName = 'there',
  });

  final List<ChatMessage> messages;
  final String? threadId;

  /// Every conversation this profile has, newest-active first — the "Recent
  /// chats" list. The open one is [threadId].
  final List<ChatThread> threads;

  /// When [threads] was last read from the server (or from cache) — drives the
  /// "Updated 5m ago" line in the recent-chats sheet.
  final DateTime? threadsUpdatedAt;

  final bool initialLoading;

  /// A background/pull-to-refresh reload of the history is in flight while the
  /// current conversation stays painted.
  final bool refreshing;

  final bool sending;
  final String? sendError;
  final String greetingName;

  bool get isEmpty => messages.isEmpty;

  /// Recent chats *other than* the one on screen.
  List<ChatThread> get otherThreads => threads.where((t) => t.id != threadId).toList();

  ChatState copyWith({
    List<ChatMessage>? messages,
    String? threadId,
    bool clearThreadId = false,
    List<ChatThread>? threads,
    DateTime? threadsUpdatedAt,
    bool? initialLoading,
    bool? refreshing,
    bool? sending,
    String? sendError,
    bool clearError = false,
    String? greetingName,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        threadId: clearThreadId ? null : (threadId ?? this.threadId),
        threads: threads ?? this.threads,
        threadsUpdatedAt: threadsUpdatedAt ?? this.threadsUpdatedAt,
        initialLoading: initialLoading ?? this.initialLoading,
        refreshing: refreshing ?? this.refreshing,
        sending: sending ?? this.sending,
        sendError: clearError ? null : (sendError ?? this.sendError),
        greetingName: greetingName ?? this.greetingName,
      );
}

/// Phase 8: owns the grounded career-chat conversation. App-scoped (not
/// auto-disposed) so the thread survives leaving and re-entering the screen in
/// one session; [reset] wipes it on sign-out like the other notifiers.
///
/// Each turn is an ADR-011 async job: [send] POSTs the message, then polls the
/// background task until the assistant reply lands (server does all grounding +
/// anti-fabrication). This is a private poll loop, NOT [TaskCenter] — a chat
/// reply updates the conversation inline; it must never fire the global
/// "task complete" toast the shared tasks use.
final chatControllerProvider =
    NotifierProvider<ChatController, ChatState>(ChatController.new);

class ChatController extends Notifier<ChatState> {
  final ApiClient _api = ApiClient();

  // Bumped by reset/newChat so a reply from an abandoned conversation that
  // resolves after the user started fresh is dropped instead of appended.
  int _generation = 0;
  bool _loadedOnce = false;
  String? _lastSentText;

  /// True between tapping "new chat" and the first send: the greeting is the
  /// intended state, so a later refresh must NOT silently reopen the newest
  /// thread underneath the user.
  bool _startingNewChat = false;

  // Poll cadence mirrors TaskCenter: fast, then back off, then give up.
  static const _fastInterval = Duration(seconds: 5);
  static const _slowInterval = Duration(seconds: 10);
  static const _backoffAfter = Duration(minutes: 1);
  static const _giveUpAfter = Duration(minutes: 10);

  @override
  ChatState build() => const ChatState();

  /// On-open: resolve the greeting name, paint the last conversation straight
  /// from cache (no spinner, no refetch), then revalidate.
  ///
  /// ADR-028: a passive open inside [CacheService.freshFor] skips the network
  /// entirely — re-entering the chat re-shows what's already there rather than
  /// re-downloading it. [force] (pull-to-refresh) always refetches.
  Future<void> load({bool force = false}) async {
    if (_loadedOnce && !force) return;
    _loadedOnce = true;
    final generation = _generation;
    state = state.copyWith(greetingName: _resolveName());

    final painted = await _paintFromCache();
    if (generation != _generation) return;
    if (!force && painted && await CacheService.instance.isFresh(CacheService.keyChatThreads)) {
      return;
    }

    state = state.copyWith(initialLoading: !painted, refreshing: painted);
    try {
      final threads = await _api.listChatThreads();
      if (generation != _generation) return;
      if (threads.isEmpty) {
        state = state.copyWith(
          threads: const [],
          threadsUpdatedAt: DateTime.now(),
          initialLoading: false,
          refreshing: false,
        );
        await CacheService.instance.write(CacheService.keyChatThreads, const []);
        return;
      }
      if (_startingNewChat && state.threadId == null) {
        // The user asked for a blank chat — refresh the list, leave the
        // greeting alone.
        state = state.copyWith(
          threads: threads,
          threadsUpdatedAt: DateTime.now(),
          initialLoading: false,
          refreshing: false,
        );
        await CacheService.instance.write(CacheService.keyChatThreads, [for (final t in threads) t.raw]);
        return;
      }
      // Keep the conversation the user is actually looking at; only default to
      // the newest thread when none is open yet.
      final openId = state.threadId ?? threads.first.id;
      final messages = await _api.fetchChatThread(openId);
      if (generation != _generation) return;
      state = state.copyWith(
        messages: messages,
        threadId: openId,
        threads: threads,
        threadsUpdatedAt: DateTime.now(),
        initialLoading: false,
        refreshing: false,
      );
      await _cache(openId, threads, messages);
    } catch (_) {
      // History unavailable (offline, not-yet-migrated backend, 402 pro gate) —
      // whatever is painted stays, and a send still starts a new thread.
      if (generation == _generation) {
        state = state.copyWith(initialLoading: false, refreshing: false);
      }
    }
  }

  /// Pull-to-refresh on the recent-chats sheet.
  Future<void> refresh() => load(force: true);

  /// Switches the open conversation to [threadId] (from the recent-chats list).
  /// Cached messages paint first when it's the thread we last cached.
  Future<void> openThread(String threadId) async {
    if (threadId == state.threadId) return;
    _generation++; // abandon any in-flight reply from the previous thread
    final generation = _generation;
    _lastSentText = null;
    _startingNewChat = false;
    state = state.copyWith(
      threadId: threadId,
      messages: const [],
      initialLoading: true,
      sending: false,
      clearError: true,
    );
    try {
      final messages = await _api.fetchChatThread(threadId);
      if (generation != _generation) return;
      state = state.copyWith(messages: messages, initialLoading: false);
      await _cache(threadId, state.threads, messages);
    } catch (e) {
      if (generation != _generation) return;
      state = state.copyWith(initialLoading: false, sendError: _clean(e));
    }
  }

  /// Paints the cached thread list + last open conversation. Returns true if
  /// anything was painted.
  Future<bool> _paintFromCache() async {
    if (state.messages.isNotEmpty || state.threads.isNotEmpty) return true;
    final threadsEntry = await CacheService.instance.read<List<ChatThread>>(
      CacheService.keyChatThreads,
      (json) => (json as List)
          .map((t) => ChatThread.fromJson((t as Map).cast<String, dynamic>()))
          .toList(),
    );
    if (threadsEntry == null) return false;
    final messagesEntry = await CacheService.instance.read<_CachedConversation>(
      CacheService.keyChatMessages,
      (json) => _CachedConversation.fromJson((json as Map).cast<String, dynamic>()),
    );
    state = state.copyWith(
      threads: threadsEntry.data,
      threadsUpdatedAt: threadsEntry.cachedAt,
      messages: messagesEntry?.data.messages ?? const [],
      threadId: messagesEntry?.data.threadId,
    );
    return true;
  }

  Future<void> _cache(String threadId, List<ChatThread> threads, List<ChatMessage> messages) async {
    await CacheService.instance.write(CacheService.keyChatThreads, [for (final t in threads) t.raw]);
    await CacheService.instance.write(
      CacheService.keyChatMessages,
      {'thread_id': threadId, 'messages': [for (final m in messages) m.toJson()]},
    );
  }

  /// Sends [raw] as a new user turn: optimistically append the bubble, then
  /// dispatch + poll for the reply. No-op on empty input or while a turn is
  /// already in flight.
  Future<void> send(String raw) async {
    final text = raw.trim();
    if (text.isEmpty || state.sending) return;
    _lastSentText = text;
    _startingNewChat = false;
    state = state.copyWith(
      messages: [...state.messages, ChatMessage(role: 'user', content: text)],
      sending: true,
      clearError: true,
    );
    await _dispatch(text);
  }

  /// Re-runs the last failed turn without duplicating its (already-shown) user
  /// bubble — wired to the error banner's Retry.
  Future<void> retry() async {
    final text = _lastSentText;
    if (text == null || state.sending) return;
    state = state.copyWith(sending: true, clearError: true);
    await _dispatch(text);
  }

  Future<void> _dispatch(String text) async {
    final generation = _generation;
    try {
      final result = await _api.sendChatMessage(text, threadId: state.threadId);
      if (generation != _generation) return;
      // Adopt the thread id immediately so a retry after a poll failure
      // continues this conversation rather than forking a new one.
      state = state.copyWith(threadId: result.threadId);
      final reply = await _pollForReply(result.taskId, generation);
      if (generation != _generation) return;
      state = state.copyWith(messages: [...state.messages, reply], sending: false);
      // Keep the cached conversation in step with what's on screen, and pick up
      // a brand-new thread so it appears under "Recent chats" right away.
      await _cache(result.threadId, state.threads, state.messages);
      if (!state.threads.any((t) => t.id == result.threadId)) {
        unawaited(_refreshThreads());
      }
    } catch (e) {
      if (generation == _generation) {
        state = state.copyWith(sending: false, sendError: _clean(e));
      }
    }
  }

  /// Polls GET /tasks/{id} until the assistant turn is written, then parses it
  /// out of the finished task's `result.message`. Throws on a failed task or a
  /// 10-minute timeout; a single flaky poll just retries on the next tick.
  Future<ChatMessage> _pollForReply(String taskId, int generation) async {
    final startedAt = DateTime.now();
    while (true) {
      final elapsed = DateTime.now().difference(startedAt);
      if (elapsed > _giveUpAfter) {
        throw Exception('The agent is taking too long — please try again.');
      }
      await Future<void>.delayed(elapsed > _backoffAfter ? _slowInterval : _fastInterval);
      if (generation != _generation) throw _Abandoned();
      final BackgroundTask task;
      try {
        task = await _api.getTaskStatus(taskId);
      } catch (_) {
        continue; // one dropped poll on mobile network is not a failed task
      }
      if (task.status == 'done') {
        final message = (task.result?['message'] as Map?)?.cast<String, dynamic>();
        if (message == null) throw Exception('The agent returned an empty reply.');
        return ChatMessage.fromJson(message);
      }
      if (task.status == 'failed') {
        throw Exception(task.error ?? 'The agent could not answer that.');
      }
    }
  }

  /// Re-reads just the thread list (after a send created a new one). Quiet by
  /// design — a failure only means "Recent chats" lags by one entry until the
  /// next open.
  Future<void> _refreshThreads() async {
    try {
      final threads = await _api.listChatThreads();
      state = state.copyWith(threads: threads, threadsUpdatedAt: DateTime.now());
      await CacheService.instance.write(CacheService.keyChatThreads, [for (final t in threads) t.raw]);
    } catch (_) {}
  }

  /// New-chat button (§4.10 reset): abandon the current thread and return to the
  /// greeting. A pending reply's generation is now stale, so it's discarded.
  /// The thread LIST survives — the previous conversation is still reachable
  /// under "Recent chats".
  void newChat() {
    _generation++;
    _lastSentText = null;
    _startingNewChat = true;
    state = ChatState(
      greetingName: state.greetingName,
      threads: state.threads,
      threadsUpdatedAt: state.threadsUpdatedAt,
    );
  }

  /// Sign-out hygiene — the next account must never see this conversation.
  void reset() {
    _generation++;
    _loadedOnce = false;
    _lastSentText = null;
    _startingNewChat = false;
    state = const ChatState();
  }

  String _resolveName() {
    final email = Supabase.instance.client.auth.currentUser?.email;
    if (email == null || !email.contains('@')) return 'there';
    final handle = email.split('@').first;
    return handle.isEmpty ? 'there' : handle;
  }

  /// Strips Dart's "Exception: " prefix so the banner shows the server's plain
  /// message (e.g. the 429 friendly text, or the 402 pro-gate detail).
  String _clean(Object e) => e.toString().replaceFirst('Exception: ', '');
}

/// Thrown to unwind the poll loop when the conversation was reset mid-flight;
/// swallowed by the generation guard in [_dispatch], never surfaced.
class _Abandoned implements Exception {}

/// The one conversation kept on disk (which thread, and its turns) so reopening
/// the chat paints instantly instead of spinning on a network round-trip.
class _CachedConversation {
  const _CachedConversation({required this.threadId, required this.messages});

  final String threadId;
  final List<ChatMessage> messages;

  factory _CachedConversation.fromJson(Map<String, dynamic> json) => _CachedConversation(
        threadId: json['thread_id'] as String,
        messages: ((json['messages'] as List?) ?? const [])
            .map((m) => ChatMessage.fromJson((m as Map).cast<String, dynamic>()))
            .toList(),
      );
}
