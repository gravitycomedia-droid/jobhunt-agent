import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import '../models/background_task.dart';
import '../models/chat_message.dart';
import 'api_client.dart';

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
    this.initialLoading = false,
    this.sending = false,
    this.sendError,
    this.greetingName = 'there',
  });

  final List<ChatMessage> messages;
  final String? threadId;
  final bool initialLoading;
  final bool sending;
  final String? sendError;
  final String greetingName;

  bool get isEmpty => messages.isEmpty;

  ChatState copyWith({
    List<ChatMessage>? messages,
    String? threadId,
    bool? initialLoading,
    bool? sending,
    String? sendError,
    bool clearError = false,
    String? greetingName,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        threadId: threadId ?? this.threadId,
        initialLoading: initialLoading ?? this.initialLoading,
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

  // Poll cadence mirrors TaskCenter: fast, then back off, then give up.
  static const _fastInterval = Duration(seconds: 5);
  static const _slowInterval = Duration(seconds: 10);
  static const _backoffAfter = Duration(minutes: 1);
  static const _giveUpAfter = Duration(minutes: 10);

  @override
  ChatState build() => const ChatState();

  /// On-open: resolve the greeting name and reload the most recent thread's
  /// history so a conversation survives an app restart (§4.10 acceptance).
  /// Best-effort — a failed history fetch just starts a fresh, usable chat.
  Future<void> load() async {
    if (_loadedOnce) return;
    _loadedOnce = true;
    final generation = _generation;
    state = state.copyWith(initialLoading: true, greetingName: _resolveName());
    try {
      final threads = await _api.listChatThreads();
      if (generation != _generation) return;
      if (threads.isEmpty) {
        state = state.copyWith(initialLoading: false);
        return;
      }
      final messages = await _api.fetchChatThread(threads.first.id);
      if (generation != _generation) return;
      state = state.copyWith(
        messages: messages,
        threadId: threads.first.id,
        initialLoading: false,
      );
    } catch (_) {
      // History unavailable (offline, not-yet-migrated backend) — the greeting
      // state is still fully usable; a send just starts a new thread.
      if (generation == _generation) state = state.copyWith(initialLoading: false);
    }
  }

  /// Sends [raw] as a new user turn: optimistically append the bubble, then
  /// dispatch + poll for the reply. No-op on empty input or while a turn is
  /// already in flight.
  Future<void> send(String raw) async {
    final text = raw.trim();
    if (text.isEmpty || state.sending) return;
    _lastSentText = text;
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

  /// New-chat button (§4.10 reset): abandon the current thread and return to the
  /// greeting. A pending reply's generation is now stale, so it's discarded.
  void newChat() {
    _generation++;
    _lastSentText = null;
    state = ChatState(greetingName: state.greetingName);
  }

  /// Sign-out hygiene — the next account must never see this conversation.
  void reset() {
    _generation++;
    _loadedOnce = false;
    _lastSentText = null;
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
