/// Career-ops integration Brick 4 (ADR-058). Mirrors one `interview_stories`
/// row — the persistent story bank, distinct from a generated
/// [InterviewPack] (interview_prep.dart): a story is something the user
/// explicitly chose to keep, and it survives independent of the job/pack
/// it may have started from.
class InterviewStory {
  final String id;
  final String situation;
  final String task;
  final String action;
  final String result;

  /// Never LLM-generated — nothing in this app can know how a real
  /// interview actually went. Null until the user adds their own note.
  final String? reflection;
  final String? sourceJobId;
  final DateTime createdAt;

  InterviewStory({
    required this.id,
    required this.situation,
    required this.task,
    required this.action,
    required this.result,
    this.reflection,
    this.sourceJobId,
    required this.createdAt,
  });

  factory InterviewStory.fromJson(Map<String, dynamic> json) {
    return InterviewStory(
      id: json['id'] as String,
      situation: json['situation'] as String? ?? '',
      task: json['task'] as String? ?? '',
      action: json['action'] as String? ?? '',
      result: json['result'] as String? ?? '',
      reflection: json['reflection'] as String?,
      sourceJobId: json['source_job_id'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}
