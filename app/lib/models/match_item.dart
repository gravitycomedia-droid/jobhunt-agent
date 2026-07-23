import 'job.dart';

/// One row from GET /matches — a [Job] plus both stages of the two-stage
/// RAG match (ADR-001): the stage-1 cosine similarity and the stage-2 LLM
/// verdict (Brick 5). Mirrors server/services/matching.get_ranked_matches's
/// response shape.
class MatchItem {
  final Job job;
  final double similarity;
  final int fitScore;
  final List<String> strengths;
  final List<String> gaps;
  final List<String> compensators;
  final String verdict;
  final String oneLineReason;

  /// §4.5: when this row was last (re)ranked — backs the "NEW" badge.
  final DateTime? rankedAt;

  /// Phase 5: the exact server JSON this was parsed from — written to the
  /// cache verbatim so cached rows round-trip through the same fromJson.
  final Map<String, dynamic> raw;

  MatchItem({
    required this.job,
    required this.similarity,
    required this.fitScore,
    required this.strengths,
    required this.gaps,
    required this.compensators,
    required this.verdict,
    required this.oneLineReason,
    this.rankedAt,
    this.raw = const {},
  });

  /// Ranked within the last day — a fresh result worth flagging.
  bool get isNew => rankedAt != null && DateTime.now().difference(rankedAt!) < const Duration(hours: 24);

  factory MatchItem.fromJson(Map<String, dynamic> json) {
    final ranked = json['ranked_at'];
    return MatchItem(
      raw: json,
      job: Job.fromJson(json),
      similarity: (json['similarity'] as num).toDouble(),
      fitScore: (json['fit_score'] as num).toInt(),
      strengths: (json['strengths'] as List).map((e) => e as String).toList(),
      gaps: (json['gaps'] as List).map((e) => e as String).toList(),
      compensators: (json['compensators'] as List).map((e) => e as String).toList(),
      verdict: json['verdict'] as String,
      oneLineReason: json['one_line_reason'] as String,
      rankedAt: ranked == null ? null : DateTime.tryParse(ranked as String),
    );
  }
}
