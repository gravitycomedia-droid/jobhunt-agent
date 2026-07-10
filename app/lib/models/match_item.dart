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

  MatchItem({
    required this.job,
    required this.similarity,
    required this.fitScore,
    required this.strengths,
    required this.gaps,
    required this.compensators,
    required this.verdict,
    required this.oneLineReason,
  });

  factory MatchItem.fromJson(Map<String, dynamic> json) {
    return MatchItem(
      job: Job.fromJson(json),
      similarity: (json['similarity'] as num).toDouble(),
      fitScore: (json['fit_score'] as num).toInt(),
      strengths: (json['strengths'] as List).map((e) => e as String).toList(),
      gaps: (json['gaps'] as List).map((e) => e as String).toList(),
      compensators: (json['compensators'] as List).map((e) => e as String).toList(),
      verdict: json['verdict'] as String,
      oneLineReason: json['one_line_reason'] as String,
    );
  }
}
