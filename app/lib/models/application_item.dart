import 'job.dart';

/// One row from GET /applications — a [Job] plus its Kanban pipeline
/// state (Brick 7). Mirrors the server's `{**application, "job": ...}`
/// response shape (see server/routers/applications.py).
class ApplicationItem {
  final String id;
  final String jobId;
  final Job job;
  final String state;
  final String? resumeVersionId;
  final String? notes;
  final DateTime stateChangedAt;
  final DateTime createdAt;

  /// Brick 8: set once the agent loop drafts a follow-up for a stale
  /// 'applied' application (7+ days, no response). Null until then.
  final String? followupSubject;
  final String? followupBody;

  /// Phase 4: the recruiter/hiring-manager address "Approve & send"
  /// delivers a drafted follow-up to, and when that send last succeeded.
  final String? contactEmail;
  final DateTime? followupSentAt;

  ApplicationItem({
    required this.id,
    required this.jobId,
    required this.job,
    required this.state,
    this.resumeVersionId,
    this.notes,
    required this.stateChangedAt,
    required this.createdAt,
    this.followupSubject,
    this.followupBody,
    this.contactEmail,
    this.followupSentAt,
  });

  factory ApplicationItem.fromJson(Map<String, dynamic> json) {
    return ApplicationItem(
      id: json['id'] as String,
      jobId: json['job_id'] as String,
      job: Job.fromJson(json['job'] as Map<String, dynamic>),
      state: json['state'] as String,
      resumeVersionId: json['resume_version_id'] as String?,
      notes: json['notes'] as String?,
      stateChangedAt: DateTime.parse(json['state_changed_at'] as String),
      createdAt: DateTime.parse(json['created_at'] as String),
      followupSubject: json['followup_subject'] as String?,
      followupBody: json['followup_body'] as String?,
      contactEmail: json['contact_email'] as String?,
      followupSentAt: json['followup_sent_at'] == null ? null : DateTime.parse(json['followup_sent_at'] as String),
    );
  }

  ApplicationItem copyWith({
    String? state,
    String? notes,
    String? followupSubject,
    String? followupBody,
    String? contactEmail,
    DateTime? followupSentAt,
  }) {
    return ApplicationItem(
      id: id,
      jobId: jobId,
      job: job,
      state: state ?? this.state,
      resumeVersionId: resumeVersionId,
      notes: notes ?? this.notes,
      stateChangedAt: stateChangedAt,
      createdAt: createdAt,
      followupSubject: followupSubject ?? this.followupSubject,
      followupBody: followupBody ?? this.followupBody,
      contactEmail: contactEmail ?? this.contactEmail,
      followupSentAt: followupSentAt ?? this.followupSentAt,
    );
  }
}

/// Kanban lane order — mirrors the `applications.state` check constraint
/// in migration 001.
const List<String> kApplicationStates = [
  'saved',
  'applied',
  'replied',
  'interview',
  'offer',
  'rejected',
];
