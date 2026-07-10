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

/// Mirrors a `tailored_resumes` row (Brick 6) — the output of POST
/// /tailor/{job_id}, before and after human approval (ADR-004's guardrail
/// gate + the "no auto-submitting" golden rule both apply here).
class TailoredResume {
  final String id;
  final String jobId;
  final List<TailoredBullet> bullets;
  final int guardrailFlags;
  final bool approved;

  TailoredResume({
    required this.id,
    required this.jobId,
    required this.bullets,
    required this.guardrailFlags,
    required this.approved,
  });

  factory TailoredResume.fromJson(Map<String, dynamic> json) {
    return TailoredResume(
      id: json['id'] as String,
      jobId: json['job_id'] as String,
      bullets: (json['bullets'] as List).map((b) => TailoredBullet.fromJson(b as Map<String, dynamic>)).toList(),
      guardrailFlags: (json['guardrail_flags'] as num).toInt(),
      approved: json['approved'] as bool,
    );
  }
}
