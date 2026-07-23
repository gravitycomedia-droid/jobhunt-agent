import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/background_task.dart';
import '../widgets/task_toast.dart';
import 'api_client.dart';

/// Which long-running server task a [TrackedTask] represents. One active
/// task per kind at a time (or per kind+[TrackedTask.id] — see [TaskCenter]'s
/// class doc) — starting a rerank while one is already running just keeps
/// following the existing one.
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

  /// Distinguishes multiple concurrent tasks of the same [kind] — e.g.
  /// tailoring job A and job B at once. Null for kinds that only ever run
  /// one at a time globally (rerank, pipeline).
  final String? id;

  const TrackedTask(this.kind, this.status, {this.result, this.error, this.id});

  bool get isActive => status == TrackedTaskStatus.queued || status == TrackedTaskStatus.running;
}

String _taskKey(TaskKind kind, String? id) => id == null ? kind.name : '${kind.name}:$id';

/// Phase 2c (was a plain singleton): the Riverpod [Notifier] that owns the
/// polling loops for 202-style background tasks (rerank, agent pipeline,
/// tailor) so they survive tab switches and pushed/popped screens.
///
/// State is one immutable map keyed by kind+id (see [_taskKey]) so e.g.
/// tailoring job A doesn't collide with job B; rerank/pipeline pass no id and
/// keep their one-global-task-per-kind behaviour. Read a specific task
/// reactively with [trackedTaskProvider]; drive it via
/// `ref.read(taskCenterProvider.notifier)`.
final taskCenterProvider =
    NotifierProvider<TaskCenter, Map<String, TrackedTask?>>(TaskCenter.new);

/// Reactive read of one task's current snapshot (null = nothing started).
final trackedTaskProvider =
    Provider.family<TrackedTask?, ({TaskKind kind, String? id})>((ref, arg) {
  return ref.watch(taskCenterProvider)[_taskKey(arg.kind, arg.id)];
});

class TaskCenter extends Notifier<Map<String, TrackedTask?>> {
  final ApiClient _api = ApiClient();

  final Map<String, Timer> _timers = {};

  // Remembered per kind+id so a failure toast's Retry can re-run the exact
  // same start call without the originating screen still being around.
  final Map<String, Future<String> Function()> _starters = {};

  // Poll every 5s, back off to 10s after 1 minute, give up at 10 minutes
  // (master-prompt Phase 1A contract).
  static const _fastInterval = Duration(seconds: 5);
  static const _slowInterval = Duration(seconds: 10);
  static const _backoffAfter = Duration(minutes: 1);
  static const _giveUpAfter = Duration(minutes: 10);

  @override
  Map<String, TrackedTask?> build() => const {};

  /// Current snapshot for one task kind (optionally scoped to [id]).
  TrackedTask? taskFor(TaskKind kind, {String? id}) => state[_taskKey(kind, id)];

  bool isActive(TaskKind kind, {String? id}) => taskFor(kind, id: id)?.isActive ?? false;

  /// Kicks off a background task: [starter] is the ApiClient call that
  /// returns the server's task id (e.g. `() => api.rerankShortlist()`).
  /// No-op if a task of this kind (and [id], if given) is already active.
  Future<void> start(TaskKind kind, Future<String> Function() starter, {String? id}) async {
    if (isActive(kind, id: id)) return;
    _starters[_taskKey(kind, id)] = starter;
    _publish(TrackedTask(kind, TrackedTaskStatus.queued, id: id));
    final String taskId;
    try {
      taskId = await starter();
    } catch (e) {
      _publish(TrackedTask(kind, TrackedTaskStatus.failed, error: e.toString(), id: id));
      return;
    }
    _publish(TrackedTask(kind, TrackedTaskStatus.running, id: id));
    _poll(kind, taskId, id: id, startedAt: DateTime.now());
  }

  /// Re-runs the last start call for this kind+id — wired to failure toasts'
  /// Retry action.
  void retry(TaskKind kind, {String? id}) {
    final starter = _starters[_taskKey(kind, id)];
    if (starter != null) start(kind, starter, id: id);
  }

  void _publish(TrackedTask task) {
    state = {...state, _taskKey(task.kind, task.id): task};
    // Phase 2 completion feedback: fire the global toast from here so it
    // lands wherever the user is now, not just on the tab that started it.
    if (task.status == TrackedTaskStatus.done) {
      showTaskToast(success: true, message: _doneMessage(task));
    } else if (task.status == TrackedTaskStatus.failed) {
      showTaskToast(
        success: false,
        message: '${_label(task.kind)} failed — ${task.error ?? 'unknown error'}',
        onRetry: () => retry(task.kind, id: task.id),
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

  void _poll(TaskKind kind, String taskId, {String? id, required DateTime startedAt}) {
    final key = _taskKey(kind, id);
    _timers[key]?.cancel();
    final elapsed = DateTime.now().difference(startedAt);

    if (elapsed > _giveUpAfter) {
      _publish(TrackedTask(kind, TrackedTaskStatus.failed,
          error: 'Timed out after 10 minutes — the server may still finish; pull to refresh later.', id: id));
      return;
    }

    final interval = elapsed > _backoffAfter ? _slowInterval : _fastInterval;
    _timers[key] = Timer(interval, () async {
      BackgroundTask task;
      try {
        task = await _api.getTaskStatus(taskId);
      } catch (_) {
        // One failed poll (flaky mobile network) is not a failed task —
        // just try again on the next tick.
        _poll(kind, taskId, id: id, startedAt: startedAt);
        return;
      }
      if (task.status == 'done') {
        _publish(TrackedTask(kind, TrackedTaskStatus.done, result: task.result, id: id));
      } else if (task.status == 'failed') {
        _publish(TrackedTask(kind, TrackedTaskStatus.failed, error: task.error ?? 'Task failed', id: id));
      } else {
        _poll(kind, taskId, id: id, startedAt: startedAt);
      }
    });
  }

  /// Dismisses a finished (done/failed) task's state — used by banners'
  /// dismiss buttons. No-op while a task is still active.
  void clearIfFinished(TaskKind kind, {String? id}) {
    if (isActive(kind, id: id)) return;
    final next = {...state}..remove(_taskKey(kind, id));
    state = next;
  }

  /// Sign-out hygiene: stop polling and clear state so the next account
  /// never sees the previous user's task progress.
  void reset() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    state = const {};
  }
}
