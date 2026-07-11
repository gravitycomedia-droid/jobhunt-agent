/// Mirrors the server's `background_tasks` row (migration 009, ADR-011):
/// long-running endpoints return 202 + a task id, and the client polls
/// GET /tasks/{id} until [isFinished].
class BackgroundTask {
  final String id;
  final String taskType; // 'rerank' | 'pipeline'
  final String status; // 'pending' | 'running' | 'done' | 'failed'
  final Map<String, dynamic>? result;
  final String? error;

  const BackgroundTask({
    required this.id,
    required this.taskType,
    required this.status,
    this.result,
    this.error,
  });

  bool get isFinished => status == 'done' || status == 'failed';
  bool get isDone => status == 'done';

  factory BackgroundTask.fromJson(Map<String, dynamic> json) {
    return BackgroundTask(
      id: json['id'] as String,
      taskType: json['task_type'] as String,
      status: json['status'] as String,
      // `as Map?` then cast: result is null until the task finishes.
      result: (json['result'] as Map?)?.cast<String, dynamic>(),
      error: json['error'] as String?,
    );
  }
}
