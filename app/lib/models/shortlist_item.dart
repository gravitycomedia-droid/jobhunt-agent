import 'job.dart';

/// One row from GET /matches/shortlist — a [Job] plus the stage-1 cosine
/// similarity score (0.0–1.0) between it and the stored profile. Mirrors
/// the server's `{**job, "similarity": ...}` response shape (see
/// server/routers/matches.py and ADR-001).
class ShortlistItem {
  final Job job;
  final double similarity;

  ShortlistItem({required this.job, required this.similarity});

  factory ShortlistItem.fromJson(Map<String, dynamic> json) {
    return ShortlistItem(
      job: Job.fromJson(json),
      similarity: (json['similarity'] as num).toDouble(),
    );
  }

  /// Similarity as a 0–100 int for [SimilarityBar]/[ScoreRing].
  int get similarityPercent => (similarity * 100).round().clamp(0, 100);
}
