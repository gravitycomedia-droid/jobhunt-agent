/// Plan 21: one teaser row from GET /matches' `locked` array — a job that
/// cleared stage-1 similarity but sits past the profile's quota, so stage 2
/// (the LLM) never ran on it.
///
/// This class is deliberately tiny, and that's the point: there is no
/// fitScore/verdict/reasoning field to populate because the server never
/// computed any. The blur in the UI is honest — it isn't hiding data the client
/// already holds, it's standing in for an analysis that doesn't exist yet.
class LockedMatchItem {
  final String id;
  final String title;
  final String company;

  /// Stage-1 cosine similarity as a whole percent. Free to compute (it's the
  /// pgvector query's own output), so the teaser can show something truthful.
  final int similarityPct;

  const LockedMatchItem({
    required this.id,
    required this.title,
    required this.company,
    required this.similarityPct,
  });

  factory LockedMatchItem.fromJson(Map<String, dynamic> json) => LockedMatchItem(
        id: json['id'] as String,
        // A scraped posting can legitimately be missing a company name; the
        // unlocked MatchCard has the same fallback.
        title: (json['title'] as String?) ?? 'Untitled role',
        company: (json['company'] as String?) ?? 'Unknown company',
        similarityPct: (json['similarity_pct'] as num?)?.toInt() ?? 0,
      );
}
