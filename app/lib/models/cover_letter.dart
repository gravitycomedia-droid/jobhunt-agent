import 'tailored_resume.dart' show FlaggedAtom;

/// Career-ops integration Brick 2 (docs/21-career-ops-integration-plan.md
/// §1.1, DECISIONS.md ADR-056). One paragraph from a cover letter — mirrors
/// the `cover_letters.paragraphs` jsonb shape server-side:
/// {role, text, guardrail_pass, flagged_atoms, accepted}. `role` is
/// 'opening' | 'body' | 'closing', same three-part structure
/// COVER_LETTER_SYSTEM_PROMPT always produces.
class CoverLetterParagraph {
  final String role;
  final String text;
  final bool guardrailPass;
  final List<FlaggedAtom> flaggedAtoms;

  /// Set at approve time (PATCH /cover-letters/{id}/approve) — same
  /// null-before-approval shape as TailoredBullet.accepted.
  final bool? accepted;

  CoverLetterParagraph({
    required this.role,
    required this.text,
    required this.guardrailPass,
    this.flaggedAtoms = const [],
    this.accepted,
  });

  factory CoverLetterParagraph.fromJson(Map<String, dynamic> json) {
    return CoverLetterParagraph(
      role: json['role'] as String? ?? 'body',
      text: json['text'] as String? ?? '',
      guardrailPass: json['guardrail_pass'] as bool? ?? true,
      flaggedAtoms: (json['flagged_atoms'] as List?)
              ?.map((a) => FlaggedAtom.fromJson(a as Map<String, dynamic>))
              .toList() ??
          const [],
      accepted: json['accepted'] as bool?,
    );
  }
}

/// Mirrors a `cover_letters` row — the output of POST
/// /cover-letters/{job_id}, before and after human approval.
class CoverLetter {
  final String id;
  final String jobId;
  final List<CoverLetterParagraph> paragraphs;
  final int guardrailFlags;
  final bool approved;

  CoverLetter({
    required this.id,
    required this.jobId,
    required this.paragraphs,
    required this.guardrailFlags,
    required this.approved,
  });

  factory CoverLetter.fromJson(Map<String, dynamic> json) {
    return CoverLetter(
      id: json['id'] as String,
      jobId: json['job_id'] as String,
      paragraphs: (json['paragraphs'] as List)
          .map((p) => CoverLetterParagraph.fromJson(p as Map<String, dynamic>))
          .toList(),
      guardrailFlags: (json['guardrail_flags'] as num).toInt(),
      approved: json['approved'] as bool,
    );
  }
}
