/// One factual atom the guardrail could not trace back to the real resume
/// (ADR-033 / R1). `kind` is 'number' | 'tech' | 'proper_noun'. Shown in the
/// diff so the user sees exactly which fact was invented, not just a red bullet.
class FlaggedAtom {
  final String text;
  final String kind;

  FlaggedAtom({required this.text, required this.kind});

  factory FlaggedAtom.fromJson(Map<String, dynamic> json) {
    return FlaggedAtom(
      text: json['text'] as String? ?? '',
      kind: json['kind'] as String? ?? '',
    );
  }
}

/// One bullet from a tailored resume — mirrors the `tailored_resumes.bullets`
/// jsonb shape server/services produces (ADR-004 guardrail + ADR-033 atoms +
/// ADR-034 section selection):
/// {original, tailored, keyword, guardrail_pass, flagged_atoms,
///  experience_index, relevance, selected, trim_reason, accepted}.
class TailoredBullet {
  final String original;
  final String tailored;
  final String keyword;
  final bool guardrailPass;

  /// R1 (ADR-033): the specific atoms that didn't trace. Empty when the bullet
  /// passed. Pre-R1 rows omit the key → empty list.
  final List<FlaggedAtom> flaggedAtoms;

  /// R2 (ADR-034): which experience this bullet belongs to (regrouping), how
  /// relevant it scored, whether it was SELECTED for the resume (true) or
  /// TRIMMED into the restore list (false), and — when trimmed — why.
  /// Pre-R2 rows omit these; `selected` then defaults true so old rows still
  /// render as ordinary diff rows.
  final int? experienceIndex;
  final double relevance;
  final bool selected;
  final String? trimReason;

  /// Frontend rebuild Phase 2: which text this bullet uses in the final
  /// resume — set at approve time (PATCH /tailor/{id}/approve). Null
  /// before approval, when there's no accept/reject decision yet.
  final bool? accepted;

  TailoredBullet({
    required this.original,
    required this.tailored,
    required this.keyword,
    required this.guardrailPass,
    this.flaggedAtoms = const [],
    this.experienceIndex,
    this.relevance = 0,
    this.selected = true,
    this.trimReason,
    this.accepted,
  });

  factory TailoredBullet.fromJson(Map<String, dynamic> json) {
    return TailoredBullet(
      original: json['original'] as String,
      tailored: json['tailored'] as String,
      keyword: json['keyword'] as String? ?? '',
      guardrailPass: json['guardrail_pass'] as bool,
      flaggedAtoms: (json['flagged_atoms'] as List?)
              ?.map((a) => FlaggedAtom.fromJson(a as Map<String, dynamic>))
              .toList() ??
          const [],
      experienceIndex: (json['experience_index'] as num?)?.toInt(),
      relevance: (json['relevance'] as num?)?.toDouble() ?? 0,
      selected: json['selected'] as bool? ?? true,
      trimReason: json['trim_reason'] as String?,
      accepted: json['accepted'] as bool?,
    );
  }
}

/// One advisory prose-lint finding (R3). Advice only — never blocks approval.
/// `bulletIndex` indexes the SELECTED bullets in order. `severity` is
/// 'warn' | 'info'.
class ProseFinding {
  final int bulletIndex;
  final String code;
  final String message;
  final String severity;

  ProseFinding({
    required this.bulletIndex,
    required this.code,
    required this.message,
    required this.severity,
  });

  factory ProseFinding.fromJson(Map<String, dynamic> json) {
    return ProseFinding(
      bulletIndex: (json['bullet_index'] as num?)?.toInt() ?? 0,
      code: json['code'] as String? ?? '',
      message: json['message'] as String? ?? '',
      severity: json['severity'] as String? ?? 'info',
    );
  }
}

/// ADR-019: the JD-analysis the tailoring step produces alongside the bullets —
/// mirrors `tailored_resumes.analysis` jsonb. Nullable end to end: rows tailored
/// before ADR-019 (bullet-only) have no analysis. R2/R3 added `summaryLine`'s
/// guardrail flag and the prose findings.
class JdAnalysis {
  final String roleType;
  final String cultureSignal;
  final String jdTitle;
  final String summaryLine;

  /// R2: whether the reframed summary passed the atom guardrail. When false the
  /// server already fell back to the stored headline — surfaced for honesty.
  final bool summaryGuardrailPass;

  /// R3: advisory prose findings for the selected bullets.
  final List<ProseFinding> proseFindings;

  JdAnalysis({
    required this.roleType,
    required this.cultureSignal,
    required this.jdTitle,
    required this.summaryLine,
    this.summaryGuardrailPass = true,
    this.proseFindings = const [],
  });

  factory JdAnalysis.fromJson(Map<String, dynamic> json) {
    return JdAnalysis(
      roleType: json['role_type'] as String? ?? '',
      cultureSignal: json['culture_signal'] as String? ?? '',
      jdTitle: json['jd_title'] as String? ?? '',
      summaryLine: json['summary_line'] as String? ?? '',
      summaryGuardrailPass: json['summary_guardrail_pass'] as bool? ?? true,
      proseFindings: (json['prose_findings'] as List?)
              ?.map((f) => ProseFinding.fromJson(f as Map<String, dynamic>))
              .toList() ??
          const [],
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

  /// R2: bullets the deterministic selection kept, in original array order.
  List<TailoredBullet> get selectedBullets => bullets.where((b) => b.selected).toList();

  /// R2: bullets the selection trimmed — the restore ("Trimmed") list.
  List<TailoredBullet> get trimmedBullets => bullets.where((b) => !b.selected).toList();

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
