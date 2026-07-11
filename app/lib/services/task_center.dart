import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/background_task.dart';
import '../widgets/task_toast.dart';
import 'api_client.dart';

/// Which long-running server task a [TrackedTask] represents. One active
/// task per kind at a time — starting a rerank while one is already
/// running just keeps following the existing one.
enum TaskKind { rerank, pipeline, tailor }

/// Client-side lifecycle of one background task. `queued` covers the gap
/// between tapping the button and the server answering 202 with a task id.
enum TrackedTaskStatus { queued, running, done, failed }

/// A snapshot of one background task's progress, published through
/// [TaskCenter.notifierFor]. Immutable — every poll tick publishes a new
/// instance rather than mutating, so ValueNotifier's == check fires.
class TrackedTask {
  final TaskKind kind;
  final TrackedTaskStatus status;
  final Map<String, dynamic>? result;
  final String? error;

  const TrackedTask(this.kind, this.status, {this.result, this.error});

  bool get isActive => status == TrackedTaskStatus.queued || status == TrackedTaskStatus.running;
}

/// ADR-011 client half: owns the polling loops for 202-style background
/// tasks (rerank, agent pipeline) so they survive tab switches — a poller
/// held inside one tab's State would keep running in the IndexedStack, but
/// its completion callback couldn't reach the rest of the app, and a
/// pushed-then-popped screen would lose it entirely.
///
/// Plain singleton + ValueNotifier (no new packages, per project rules):
/// screens subscribe with ValueListenableBuilder / addListener and stay
/// dumb about scheduling. This is the FlutterFlow "App State" idea, but
/// hand-rolled and scoped to task progress only.
class TaskCenter {
  TaskCenter._();
  static final TaskCenter instance = TaskCenter._();

  final ApiClient _api = ApiClient();

  final Map<TaskKind, ValueNotifier<TrackedTask?>> _notifiers = {
    for (final kind in TaskKind.values) kind: ValueNotifier<TrackedTask?>(null),
  };
  final Map<TaskKind, Timer> _timers = {};

  // Remembered per kind so a failure toast's Retry can re-run the exact
  // same start call without the originating screen still being around.
  final Map<TaskKind, Future<String> Function()> _starters = {};

  // Poll every 5s, back off to 10s after 1 minute, give up at 10 minutes
  // (master-prompt Phase 1A contract).
  static const _fastInterval = Duration(seconds: 5);
  static const _slowInterval = Duration(seconds: 10);
  static const _backoffAfter = Duration(minutes: 1);
  static const _giveUpAfter = Duration(minutes: 10);

  /// Subscribe point for one task kind. Null value = nothing started yet
  /// this session.
  ValueNotifier<TrackedTask?> notifierFor(TaskKind kind) => _notifiers[kind]!;

  bool isActive(TaskKind kind) => _notifiers[kind]!.value?.isActive ?? false;

  /// Kicks off a background task: [starter] is the ApiClient call that
  /// returns the server's task id (e.g. `() => api.rerankShortlist()`).
  /// No-op if a task of this kind is already active.
  Future<void> start(TaskKind kind, Future<String> Function() starter) async {
    if (isActive(kind)) return;
    _starters[kind] = starter;
    _publish(TrackedTask(kind, TrackedTaskStatus.queued));
    final String taskId;
    try {
      taskId = await starter();
    } catch (e) {
      _publish(TrackedTask(kind, TrackedTaskStatus.failed, error: e.toString()));
      return;
    }
    _publish(TrackedTask(kind, TrackedTaskStatus.running));
    _poll(kind, taskId, startedAt: DateTime.now());
  }

  /// Re-runs the last start call for this kind — wired to failure toasts'
  /// Retry action.
  void retry(TaskKind kind) {
    final starter = _starters[kind];
    if (starter != null) start(kind, starter);
  }

  void _publish(TrackedTask task) {
    _notifiers[task.kind]!.value = task;
    // Phase 2 completion feedback: fire the global toast from here so it
    // lands wherever the user is now, not just on the tab that started it.
    if (task.status == TrackedTaskStatus.done) {
      showTaskToast(success: true, message: _doneMessage(task));
    } else if (task.status == TrackedTaskStatus.failed) {
      showTaskToast(
        success: false,
        message: '${_label(task.kind)} failed — ${task.error ?? 'unknown error'}',
        onRetry: () => retry(task.kind),
      );
    }
  }

  String _label(TaskKind kind) => switch (kind) {
        TaskKind.rerank => 'Re-rank',
        TaskKind.pipeline => 'Agent run',
        TaskKind.tailor => 'Resume tailoring',
      };

  String _doneMessage(TrackedTask task) {
    final r = task.result ?? const {};
    return switch (task.kind) {
      // Counts come straight from the server's task result (Golden Rule 2:
      // arithmetic in code, and here not even ours — just display).
      TaskKind.rerank => 'Re-rank complete — ${r['reranked'] ?? 0} new, ${r['skipped'] ?? 0} skipped',
      TaskKind.pipeline =>
        'Agent run complete — ${r['jobs_inserted'] ?? 0} jobs added, ${r['matches_reranked'] ?? 0} scored, ${r['followups_drafted'] ?? 0} follow-up(s)',
      TaskKind.tailor => 'Resume tailored — review the diff',
    };
  }

  void _poll(TaskKind kind, String taskId, {required DateTime startedAt}) {
    _timers[kind]?.cancel();
    final elapsed = DateTime.now().difference(startedAt);

    if (elapsed > _giveUpAfter) {
      _publish(TrackedTask(kind, TrackedTaskStatus.failed,
          error: 'Timed out after 10 minutes — the server may still finish; pull to refresh later.'));
      return;
    }

    final interval = elapsed > _backoffAfter ? _slowInterval : _fastInterval;
    _timers[kind] = Timer(interval, () async {
      BackgroundTask task;
      try {
        task = await _api.getTaskStatus(taskId);
      } catch (_) {
        // One failed poll (flaky mobile network) is not a failed task —
        // just try again on the next tick.
        _poll(kind, taskId, startedAt: startedAt);
        return;
      }
      if (task.status == 'done') {
        _publish(TrackedTask(kind, TrackedTaskStatus.done, result: task.result));
      } else if (task.status == 'failed') {
        _publish(TrackedTask(kind, TrackedTaskStatus.failed, error: task.error ?? 'Task failed'));
      } else {
        _poll(kind, taskId, startedAt: startedAt);
      }
    });
  }

  /// Dismisses a finished (done/failed) task's state — used by banners'
  /// dismiss buttons. No-op while a task is still active.
  void clearIfFinished(TaskKind kind) {
    if (!isActive(kind)) _notifiers[kind]!.value = null;
  }

  /// Sign-out hygiene: stop polling and clear state so the next account
  /// never sees the previous user's task progress.
  void reset() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    for (final n in _notifiers.values) {
      n.value = null;
    }
  }
}
