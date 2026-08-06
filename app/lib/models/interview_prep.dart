import 'tailored_resume.dart' show FlaggedAtom;

/// Career-ops integration Brick 4 (docs/21-career-ops-integration-plan.md
/// §1.2, DECISIONS.md ADR-058). One question from a generated pack — never
/// persisted server-side (see [InterviewPack]'s docstring); this is the
/// direct response shape of POST /interview-prep/{application_id}.
class InterviewQuestion {
  final String question;

  /// 'behavioral' | 'technical' | 'gap' | 'company_fit'.
  final String category;

  /// True when the model could NOT ground this question's premise
  /// directly in the JD text — career-ops's own `[inferred from JD]`
  /// tagging, surfaced as a badge rather than silently presented as fact.
  final bool inferred;

  final String situation;
  final String task;
  final String action;
  final String result;

  final bool guardrailPass;
  final List<FlaggedAtom> flaggedAtoms;

  InterviewQuestion({
    required this.question,
    required this.category,
    required this.inferred,
    required this.situation,
    required this.task,
    required this.action,
    required this.result,
    required this.guardrailPass,
    this.flaggedAtoms = const [],
  });

  factory InterviewQuestion.fromJson(Map<String, dynamic> json) {
    return InterviewQuestion(
      question: json['question'] as String? ?? '',
      category: json['category'] as String? ?? 'behavioral',
      inferred: json['inferred'] as bool? ?? false,
      situation: json['situation'] as String? ?? '',
      task: json['task'] as String? ?? '',
      action: json['action'] as String? ?? '',
      result: json['result'] as String? ?? '',
      guardrailPass: json['guardrail_pass'] as bool? ?? true,
      flaggedAtoms: (json['flagged_atoms'] as List?)
              ?.map((a) => FlaggedAtom.fromJson(a as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }
}

/// The whole POST /interview-prep/{application_id} response. Disposable —
/// regenerated fresh on each request, never cached server-side (migration
/// 034's docstring): a pack is cheap enough to just re-run, unlike a saved
/// [InterviewStory].
class InterviewPack {
  final String jobId;
  final List<InterviewQuestion> questions;

  InterviewPack({required this.jobId, required this.questions});

  factory InterviewPack.fromJson(Map<String, dynamic> json) {
    return InterviewPack(
      jobId: json['job_id'] as String? ?? '',
      questions: (json['questions'] as List? ?? const [])
          .map((q) => InterviewQuestion.fromJson(q as Map<String, dynamic>))
          .toList(),
    );
  }
}
