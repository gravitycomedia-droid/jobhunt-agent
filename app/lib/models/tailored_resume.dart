/// One bullet from a tailored resume — mirrors the `tailored_resumes.bullets`
/// jsonb shape server/services/guardrail.py produces:
/// {original, tailored, keyword, guardrail_pass, accepted}.
class TailoredBullet {
  final String original;
  final String tailored;
  final String keyword;
  final bool guardrailPass;

  /// Frontend rebuild Phase 2: which text this bullet uses in the final
  /// resume — set at approve time (PATCH /tailor/{id}/approve). Null
  /// before approval, when there's no accept/reject decision yet.
  final bool? accepted;

  TailoredBullet({
    required this.original,
    required this.tailored,
    required this.keyword,
    required this.guardrailPass,
    this.accepted,
  });

  factory TailoredBullet.fromJson(Map<String, dynamic> json) {
    return TailoredBullet(
      original: json['original'] as String,
      tailored: json['tailored'] as String,
      keyword: json['keyword'] as String,
      guardrailPass: json['guardrail_pass'] as bool,
      accepted: json['accepted'] as bool?,
    );
  }
}

/// ADR-019: the JD-analysis the tailoring step now produces alongside the
/// bullets — mirrors `tailored_resumes.analysis` jsonb. Nullable end to end:
/// rows tailored before ADR-019 (bullet-only) have no analysis. `roleType`
/// and `jdTitle` are shown as context; the layout/accent/skill-order fields
/// it also carries are consumed server-side by the PDF, not here.
class JdAnalysis {
  final String roleType;
  final String cultureSignal;
  final String jdTitle;
  final String summaryLine;

  JdAnalysis({
    required this.roleType,
    required this.cultureSignal,
    required this.jdTitle,
    required this.summaryLine,
  });

  factory JdAnalysis.fromJson(Map<String, dynamic> json) {
    return JdAnalysis(
      roleType: json['role_type'] as String? ?? '',
      cultureSignal: json['culture_signal'] as String? ?? '',
      jdTitle: json['jd_title'] as String? ?? '',
      summaryLine: json['summary_line'] as String? ?? '',
    );
  }
}

/// Mirrors a `tailored_resumes` row (Brick 6) — the output of POST
/// /tailor/{job_id}, before and after human approval (ADR-004's guardrail
/// gate + the "no auto-submitting" golden rule both apply here).
class TailoredResume {
  final String id;
  final String jobId;
  final List<TailoredBullet> bullets;
  final int guardrailFlags;
  final bool approved;

  /// ADR-019: JD analysis + the gap disclosure. `gaps` are JD hard
  /// requirements the candidate can't back up — surfaced here so the user
  /// sees them, never written onto the resume itself. Both null for
  /// pre-ADR-019 rows.
  final JdAnalysis? analysis;
  final List<String> gaps;

  TailoredResume({
    required this.id,
    required this.jobId,
    required this.bullets,
    required this.guardrailFlags,
    required this.approved,
    this.analysis,
    this.gaps = const [],
  });

  factory TailoredResume.fromJson(Map<String, dynamic> json) {
    return TailoredResume(
      id: json['id'] as String,
      jobId: json['job_id'] as String,
      bullets: (json['bullets'] as List).map((b) => TailoredBullet.fromJson(b as Map<String, dynamic>)).toList(),
      guardrailFlags: (json['guardrail_flags'] as num).toInt(),
      approved: json['approved'] as bool,
      analysis: json['analysis'] == null ? null : JdAnalysis.fromJson(json['analysis'] as Map<String, dynamic>),
      gaps: (json['gaps'] as List?)?.map((g) => g as String).toList() ?? const [],
    );
  }
}
