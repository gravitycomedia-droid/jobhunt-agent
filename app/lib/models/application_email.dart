import 'tailored_resume.dart' show FlaggedAtom;

/// Career-ops integration Brick 3 (docs/21-career-ops-integration-plan.md
/// §1.6, DECISIONS.md ADR-057). Mirrors one `application_emails` row.
/// `kind` is 'application' | 'referral' | 'cold' — distinct tones the
/// backend prompt (services/llm.py::APPLICATION_EMAIL_SYSTEM_PROMPT)
/// produces. Unlike [ApplicationItem]'s follow-up fields (which overwrite
/// in place), every draft is its own row — a candidate reasonably wants
/// more than one on file, redrafted for a different contact or kept as
/// history (migration 033's docstring).
class ApplicationEmailDraft {
  final String id;
  final String kind;
  final String subject;
  final String body;
  final bool guardrailPass;
  final List<FlaggedAtom> flaggedAtoms;
  final DateTime? sentAt;

  ApplicationEmailDraft({
    required this.id,
    required this.kind,
    required this.subject,
    required this.body,
    required this.guardrailPass,
    this.flaggedAtoms = const [],
    this.sentAt,
  });

  bool get isSent => sentAt != null;

  factory ApplicationEmailDraft.fromJson(Map<String, dynamic> json) {
    return ApplicationEmailDraft(
      id: json['id'] as String,
      kind: json['kind'] as String? ?? 'application',
      subject: json['subject'] as String? ?? '',
      body: json['body'] as String? ?? '',
      guardrailPass: json['guardrail_pass'] as bool? ?? true,
      flaggedAtoms: (json['flagged_atoms'] as List?)
              ?.map((a) => FlaggedAtom.fromJson(a as Map<String, dynamic>))
              .toList() ??
          const [],
      sentAt: json['sent_at'] == null ? null : DateTime.parse(json['sent_at'] as String),
    );
  }
}

/// The GET /application-emails/{application_id} payload: every drafted
/// variant for this application plus a deterministic (Golden Rule 2)
/// attachment checklist — whether a tailored résumé and/or approved cover
/// letter already exist for this job, so the review screen can tell the
/// user what to actually attach before they hit send.
class ApplicationEmailList {
  final List<ApplicationEmailDraft> drafts;
  final bool hasResume;
  final bool hasCoverLetter;

  ApplicationEmailList({required this.drafts, required this.hasResume, required this.hasCoverLetter});

  factory ApplicationEmailList.fromJson(Map<String, dynamic> json) {
    final attachments = json['attachments'] as Map<String, dynamic>? ?? const {};
    return ApplicationEmailList(
      drafts: (json['drafts'] as List? ?? const [])
          .map((d) => ApplicationEmailDraft.fromJson(d as Map<String, dynamic>))
          .toList(),
      hasResume: attachments['resume'] as bool? ?? false,
      hasCoverLetter: attachments['cover_letter'] as bool? ?? false,
    );
  }
}
